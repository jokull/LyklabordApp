#!/usr/bin/env python3
"""Generate typo -> intended word pairs (with sentence context) for the
autocorrect eval datasets, from the sentence corpora built by
fetch-eval-corpora.py.

Splits sentences into two DISJOINT pools (dev / heldout) BEFORE generating
any pairs, then generates pairs independently from each pool. This is the
mechanism that keeps heldout truly held out: no sentence contributes pairs to
both files, so a system can't have seen a heldout sentence's other words/
context during dev-set tuning.

Error taxonomy (see data/eval/README.md for the full write-up + rationale):
  substitution   - replace a letter with an adjacent key (Icelandic QWERTY
                   layout: qwertyuiopð / asdfghjklæö / zxcvbnmþ, hardcoded
                   3-row adjacency incl. up/down/diagonal neighbors)
  insertion      - insert an adjacent-key letter next to an existing one
  deletion       - drop one letter
  transposition  - swap two adjacent letters
  gemination     - double a letter, or collapse an existing doubled letter
  space_miss     - two adjacent (single-space-separated) words merged, with
                   the space either dropped entirely or replaced by a
                   space-row neighbor letter (c/v/b/n/m) — see PLAN.md's
                   "Space-miss correction" section
  accent_drop    - IS only: á é í ó ú ý ö -> ascii base (a e i o u y o),
                   boosted weight (real recurring dogfood/data issue, see
                   data/README.md's "accent-dominance filter" note)
  contraction_damage - EN only: drop an apostrophe (contractions AND
                   possessives, e.g. "don't"->"dont", "Iceland's"->"Icelands")

Mixture weights: the task brief's baseline ratio for the four classic
single-edit error types (substitution 40 : insertion 25 : deletion 25 :
transposition 10 — consistent with the standard single-error spelling-error
taxonomy surveyed in Kukich 1992 and traceable to Damerau 1964's original
edit-distance error classes) is rescaled to 70% of total probability mass,
leaving 30% for the extra categories this project cares about specifically:
gemination (6%), space_miss (8%), and a language-specific booster category
(16%: accent_drop for Icelandic, contraction_damage for English). We looked
for the Aalto ITE paper's own error-type breakdown to calibrate against
(https://zenodo.org/doi/10.5281/zenodo.12528162) but its public preprint
does not publish a substitution/insertion/deletion/transposition split (it
reports ITE usage/accuracy, not a character-error taxonomy) — see the
"Acquisition gaps" note in data/eval/README.md. Falling back to the
brief's literature-value baseline as instructed.

Sampling is **quota-driven**: each (language, split) target is divided into
exact per-category quotas from the weight table (largest-remainder
rounding), and each category then fills its quota from eligible slots in a
category-specific deterministic shuffle of the pool's sentences. This makes
realized counts match the nominal weights exactly instead of drifting with
corpus eligibility rates (naive per-slot weighted sampling was tried first
and produced e.g. 1 contraction_damage pair out of 1500 — encyclopedic
English has few contractions, so rare-category mass must be sought, not
hoped for). If a pool genuinely can't fill a category's quota (not the case
with the shipped corpora), the shortfall is printed as a WARNING and the
file simply contains fewer pairs of that category — quotas are never
silently backfilled from other categories.

Per-word/per-pair category eligibility is checked before generation (e.g. a
word with two identical adjacent letters can't transpose into something
different; accent_drop only fires on words that actually contain an
accented letter; contraction_damage needs an apostrophe). At most
3 pairs are drawn per sentence (across all categories) and no token slot is
used twice, so contexts stay diverse.

Determinism: the entire run (sentence shuffle+split, slot selection,
category choice, error parameters) is driven by a single --seed fed into
stdlib `random.Random`. Same --seed + same input sentence files => byte-
identical output files. Each record also carries a "seed" field (the run
seed) for provenance.

Usage:
    python3 scripts/generate-eval-pairs.py \\
        --sentences-dir data/eval --out-dir data/eval --seed 20260715 \\
        --dev-target 3000 --heldout-target 3000

Sanity checks enforced during generation (see also spot-print report at the
end of a run):
  - typo != intended for every emitted record
  - intended (word, or "word1 word2" for space_miss) is an exact substring of
    the sentence at the recorded span (real corpus text, not synthesized)
  - context is a list of real preceding word tokens from the same sentence

Stdlib only.
"""
import argparse
import json
import random
import re
from collections import Counter, defaultdict
from pathlib import Path

# --- Icelandic QWERTY layout adjacency -------------------------------------

IS_ROWS = ["qwertyuiopð", "asdfghjklæö", "zxcvbnmþ"]
EN_ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

SPACE_ROW_LETTERS = "cvbnm"  # bottom-row letters adjacent to the spacebar


def build_adjacency(rows: list[str]) -> dict[str, list[str]]:
    """3-row physical-QWERTY-stagger adjacency: same-row left/right neighbor,
    plus up to two diagonal/vertical neighbors in the row above/below,
    approximating the standard half-key stagger (each lower row sits shifted
    right by ~half a key relative to the row above it)."""
    adj: dict[str, set[str]] = {}
    for r, row in enumerate(rows):
        for c, ch in enumerate(row):
            neighbors: set[str] = set()
            if c > 0:
                neighbors.add(row[c - 1])
            if c < len(row) - 1:
                neighbors.add(row[c + 1])
            if r > 0:
                above = rows[r - 1]
                for cc in (c, c + 1):
                    if 0 <= cc < len(above):
                        neighbors.add(above[cc])
            if r < len(rows) - 1:
                below = rows[r + 1]
                for cc in (c - 1, c):
                    if 0 <= cc < len(below):
                        neighbors.add(below[cc])
            adj[ch] = neighbors
    return {k: sorted(v) for k, v in adj.items()}


IS_ADJACENCY = build_adjacency(IS_ROWS)
EN_ADJACENCY = build_adjacency(EN_ROWS)

# á é í ó ú ý ö -> ascii base. Matches scripts/build-lexicon.py's own
# accent-dominance-filter mapping for consistency across the repo. þ/ð/æ are
# independent letters with no ascii fallback and are intentionally excluded.
ACCENT_MAP = {"á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ý": "y", "ö": "o"}

LETTERS = "A-Za-zÁÉÍÓÚÝÐÞÆÖáéíóúýðþæö"
WORD_RE = re.compile(rf"[{LETTERS}]+(?:['’][{LETTERS}]+)*")

# --- Category weights -------------------------------------------------------
# See module docstring for rationale. Values are relative (random.choices
# normalizes), chosen to sum to 100 for a readable percentage table.
WEIGHTS_IS = {
    "substitution": 28,
    "insertion": 18,
    "deletion": 17,
    "transposition": 7,
    "gemination": 6,
    "space_miss": 8,
    "accent_drop": 16,
}
WEIGHTS_EN = {
    "substitution": 28,
    "insertion": 18,
    "deletion": 17,
    "transposition": 7,
    "gemination": 6,
    "space_miss": 8,
    "contraction_damage": 16,
}

MAX_CONTEXT_WORDS = 8
MIN_WORD_LEN_FOR_EDIT = 3  # single-word slots must be at least this long
MAX_SLOTS_PER_SENTENCE = 3


# --- Error generators (each returns a mutated word or None if inapplicable) -

def gen_substitution(word: str, rng: random.Random, adjacency: dict) -> str | None:
    idx = rng.randrange(len(word))
    ch = word[idx]
    candidates = adjacency.get(ch.lower(), [])
    if not candidates:
        return None
    repl = rng.choice(candidates)
    if ch.isupper():
        repl = repl.upper()
    return word[:idx] + repl + word[idx + 1 :]


def gen_deletion(word: str, rng: random.Random) -> str | None:
    if len(word) < 2:
        return None
    idx = rng.randrange(len(word))
    return word[:idx] + word[idx + 1 :]


def gen_insertion(word: str, rng: random.Random, adjacency: dict) -> str | None:
    idx = rng.randrange(len(word) + 1)
    anchor_idx = min(idx, len(word) - 1)
    anchor = word[anchor_idx].lower()
    candidates = adjacency.get(anchor, [])
    if not candidates:
        return None
    ins = rng.choice(candidates)
    return word[:idx] + ins + word[idx:]


def gen_transposition(word: str, rng: random.Random) -> str | None:
    if len(word) < 2:
        return None
    idx = rng.randrange(len(word) - 1)
    if word[idx].lower() == word[idx + 1].lower():
        return None  # would be a no-op
    chars = list(word)
    chars[idx], chars[idx + 1] = chars[idx + 1], chars[idx]
    return "".join(chars)


def gen_gemination(word: str, rng: random.Random) -> str | None:
    doubles = [i for i in range(len(word) - 1) if word[i].lower() == word[i + 1].lower()]
    if doubles and rng.random() < 0.6:
        i = rng.choice(doubles)
        return word[:i] + word[i + 1 :]  # de-double
    if len(word) < 1:
        return None
    idx = rng.randrange(len(word))
    return word[: idx + 1] + word[idx] + word[idx + 1 :]  # double


def gen_accent_drop(word: str) -> str | None:
    out = []
    changed = False
    for ch in word:
        base = ACCENT_MAP.get(ch.lower())
        if base:
            out.append(base.upper() if ch.isupper() else base)
            changed = True
        else:
            out.append(ch)
    return "".join(out) if changed else None


def gen_contraction_damage(word: str) -> str | None:
    if "'" not in word and "’" not in word:
        return None
    return word.replace("'", "").replace("’", "")


def gen_space_miss(word_a: str, word_b: str, rng: random.Random) -> str:
    if rng.random() < 0.5:
        return word_a + word_b
    letter = rng.choice(SPACE_ROW_LETTERS)
    return word_a + letter + word_b


ELIGIBILITY = {
    "substitution": lambda w: len(w) >= 1,
    "insertion": lambda w: len(w) >= 1,
    "deletion": lambda w: len(w) >= 2,
    "transposition": lambda w: len(w) >= 2,
    "gemination": lambda w: len(w) >= 1,
    "accent_drop": lambda w: any(c.lower() in ACCENT_MAP for c in w),
    "contraction_damage": lambda w: "'" in w or "’" in w,
}


def apply_category(category: str, word: str, rng: random.Random, adjacency: dict) -> str | None:
    if category == "substitution":
        return gen_substitution(word, rng, adjacency)
    if category == "insertion":
        return gen_insertion(word, rng, adjacency)
    if category == "deletion":
        return gen_deletion(word, rng)
    if category == "transposition":
        return gen_transposition(word, rng)
    if category == "gemination":
        return gen_gemination(word, rng)
    if category == "accent_drop":
        return gen_accent_drop(word)
    if category == "contraction_damage":
        return gen_contraction_damage(word)
    raise ValueError(f"unknown category {category!r}")


# --- Sentence tokenization ---------------------------------------------------

class Token:
    __slots__ = ("text", "start", "end")

    def __init__(self, text: str, start: int, end: int):
        self.text = text
        self.start = start
        self.end = end


def tokenize(sentence: str) -> list[Token]:
    return [Token(m.group(0), m.start(), m.end()) for m in WORD_RE.finditer(sentence)]


def context_for(tokens: list[Token], idx: int) -> list[str]:
    start = max(0, idx - MAX_CONTEXT_WORDS)
    return [t.text for t in tokens[start:idx]]


def quotas_from_weights(weights: dict[str, int], target: int) -> dict[str, int]:
    """Exact integer quotas via largest-remainder rounding; sums to target."""
    total_w = sum(weights.values())
    raw = {c: target * w / total_w for c, w in weights.items()}
    quotas = {c: int(raw[c]) for c in weights}
    remainder = target - sum(quotas.values())
    by_frac = sorted(weights, key=lambda c: raw[c] - quotas[c], reverse=True)
    for c in by_frac[:remainder]:
        quotas[c] += 1
    return quotas


# Fill order: hardest-to-satisfy categories first, so scarce eligible slots
# aren't consumed by categories that could have used any word.
FILL_ORDER = [
    "contraction_damage",
    "accent_drop",
    "space_miss",
    "transposition",
    "gemination",
    "deletion",
    "insertion",
    "substitution",
]


class SentenceState:
    __slots__ = ("sentence", "tokens", "used_slots", "pair_count")

    def __init__(self, sentence: str):
        self.sentence = sentence
        self.tokens = tokenize(sentence)
        self.used_slots: set[int] = set()
        self.pair_count = 0


def eligible_slot_indices(state: SentenceState, category: str) -> list:
    """Word-slot indices (or pair-slot start indices for space_miss) that are
    eligible for `category` and don't collide with already-used slots."""
    tokens = state.tokens
    if category == "space_miss":
        out = []
        for i in range(len(tokens) - 1):
            a, b = tokens[i], tokens[i + 1]
            if i in state.used_slots or (i + 1) in state.used_slots:
                continue
            if len(a.text) >= 2 and len(b.text) >= 2 and state.sentence[a.end : b.start] == " ":
                out.append(i)
        return out
    check = ELIGIBILITY[category]
    return [
        i
        for i, tok in enumerate(tokens)
        if i not in state.used_slots and len(tok.text) >= MIN_WORD_LEN_FOR_EDIT and check(tok.text)
    ]


def make_record(
    state: SentenceState, category: str, slot: int, lang: str, rng: random.Random, adjacency: dict, run_seed: int
) -> dict | None:
    tokens = state.tokens
    if category == "space_miss":
        tok_a, tok_b = tokens[slot], tokens[slot + 1]
        intended = state.sentence[tok_a.start : tok_b.end]
        assert intended == f"{tok_a.text} {tok_b.text}"
        typo = gen_space_miss(tok_a.text, tok_b.text, rng)
        if typo == intended:
            return None
        context = context_for(tokens, slot)
    else:
        word = tokens[slot].text
        intended = state.sentence[tokens[slot].start : tokens[slot].end]
        assert intended == word
        typo = None
        for _attempt in range(5):
            candidate = apply_category(category, word, rng, adjacency)
            if candidate and candidate != word:
                typo = candidate
                break
        if typo is None:
            return None
        context = context_for(tokens, slot)
    return {
        "typo": typo,
        "intended": intended,
        "context": context,
        "lang": lang,
        "category": category,
        "seed": run_seed,
    }


def load_sentences(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def split_pools(sentences: list[str], seed: int) -> tuple[list[str], list[str]]:
    shuffled = list(sentences)
    random.Random(seed).shuffle(shuffled)
    mid = len(shuffled) // 2
    return shuffled[:mid], shuffled[mid:]


def generate_for_pool(
    pool: list[str], lang: str, weights: dict, adjacency: dict, target: int, seed: int, run_seed: int
) -> list[dict]:
    rng = random.Random(seed)
    quotas = quotas_from_weights(weights, target)
    states = [SentenceState(s) for s in pool]
    out: list[dict] = []

    for category in FILL_ORDER:
        if category not in quotas:
            continue
        quota = quotas[category]
        order = list(range(len(states)))
        rng.shuffle(order)  # category-specific traversal spreads sentence usage
        filled = 0
        for si in order:
            if filled >= quota:
                break
            state = states[si]
            if state.pair_count >= MAX_SLOTS_PER_SENTENCE:
                continue
            slots = eligible_slot_indices(state, category)
            if not slots:
                continue
            slot = rng.choice(slots)
            record = make_record(state, category, slot, lang, rng, adjacency, run_seed)
            if record is None:
                continue
            out.append(record)
            state.used_slots.add(slot)
            if category == "space_miss":
                state.used_slots.add(slot + 1)
            state.pair_count += 1
            filled += 1
        if filled < quota:
            print(
                f"WARNING: [{lang}] category {category!r} filled {filled}/{quota} "
                f"(pool exhausted; shipping fewer pairs of this category)"
            )
    return out


def print_report(dev: list[dict], heldout: list[dict]) -> None:
    def counts(records):
        by_lang_cat = Counter((r["lang"], r["category"]) for r in records)
        by_lang = Counter(r["lang"] for r in records)
        return by_lang_cat, by_lang

    print("\n### Pair counts\n")
    for name, records in (("dev", dev), ("heldout", heldout)):
        by_lang_cat, by_lang = counts(records)
        print(f"**{name}.jsonl** — {len(records)} pairs total ({dict(by_lang)})")
        for lang in sorted(by_lang):
            print(f"  {lang}:")
            for (l, cat), n in sorted(by_lang_cat.items()):
                if l == lang:
                    print(f"    {cat}: {n}")
    print()

    print("### Spot-print samples (up to 20 per category, combined dev+heldout)\n")
    by_cat: dict[str, list[dict]] = defaultdict(list)
    for r in dev + heldout:
        by_cat[r["category"]].append(r)
    for cat in sorted(by_cat):
        samples = by_cat[cat][:20]
        print(f"-- {cat} ({len(by_cat[cat])} total, showing {len(samples)}) --")
        for r in samples:
            ctx = " ".join(r["context"])
            print(f"  [{r['lang']}] {r['typo']!r} <- {r['intended']!r}  ctx: ...{ctx}")
        print()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sentences-dir", default="data/eval")
    ap.add_argument("--out-dir", default="data/eval")
    ap.add_argument("--seed", type=int, default=20260715)
    ap.add_argument("--dev-target", type=int, default=3000, help="total pairs across both languages")
    ap.add_argument("--heldout-target", type=int, default=3000, help="total pairs across both languages")
    ap.add_argument("--quiet", action="store_true", help="skip the spot-print report")
    args = ap.parse_args()

    sentences_dir = Path(args.sentences_dir)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    is_sentences = load_sentences(sentences_dir / "sentences.is.txt")
    en_sentences = load_sentences(sentences_dir / "sentences.en.txt")

    is_dev_pool, is_heldout_pool = split_pools(is_sentences, args.seed)
    en_dev_pool, en_heldout_pool = split_pools(en_sentences, args.seed + 1)

    per_lang_dev_target = args.dev_target // 2
    per_lang_heldout_target = args.heldout_target // 2

    dev_is = generate_for_pool(
        is_dev_pool, "is", WEIGHTS_IS, IS_ADJACENCY, per_lang_dev_target, args.seed + 100, args.seed
    )
    dev_en = generate_for_pool(
        en_dev_pool, "en", WEIGHTS_EN, EN_ADJACENCY, per_lang_dev_target, args.seed + 101, args.seed
    )
    heldout_is = generate_for_pool(
        is_heldout_pool, "is", WEIGHTS_IS, IS_ADJACENCY, per_lang_heldout_target, args.seed + 200, args.seed
    )
    heldout_en = generate_for_pool(
        en_heldout_pool, "en", WEIGHTS_EN, EN_ADJACENCY, per_lang_heldout_target, args.seed + 201, args.seed
    )

    dev = dev_is + dev_en
    heldout = heldout_is + heldout_en

    # Sanity checks (belt-and-suspenders; generation already enforces these).
    for r in dev + heldout:
        assert r["typo"] != r["intended"], r

    dev_path = out_dir / "dev.jsonl"
    heldout_path = out_dir / "heldout.jsonl"
    with dev_path.open("w", encoding="utf-8") as f:
        for r in dev:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    with heldout_path.open("w", encoding="utf-8") as f:
        for r in heldout:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    print(f"Wrote {len(dev)} pairs -> {dev_path}")
    print(f"Wrote {len(heldout)} pairs -> {heldout_path}")
    if len(dev_is) < per_lang_dev_target:
        print(f"WARNING: dev/is only produced {len(dev_is)}/{per_lang_dev_target} (sentence pool exhausted)")
    if len(dev_en) < per_lang_dev_target:
        print(f"WARNING: dev/en only produced {len(dev_en)}/{per_lang_dev_target} (sentence pool exhausted)")
    if len(heldout_is) < per_lang_heldout_target:
        print(f"WARNING: heldout/is only produced {len(heldout_is)}/{per_lang_heldout_target} (sentence pool exhausted)")
    if len(heldout_en) < per_lang_heldout_target:
        print(f"WARNING: heldout/en only produced {len(heldout_en)}/{per_lang_heldout_target} (sentence pool exhausted)")

    if not args.quiet:
        print_report(dev, heldout)


if __name__ == "__main__":
    main()
