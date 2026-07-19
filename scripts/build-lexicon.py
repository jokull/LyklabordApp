#!/usr/bin/env python3
"""Build a `.lex` frequency binary — see Packages/Lexicon/FORMAT.md for the
byte layout this writes and Packages/Lexicon/Sources/Lexicon/FrequencyLexicon.swift
for the reader.

Usage:
    python3 scripts/build-lexicon.py \\
        --unigrams data/en/en-80k.txt \\
        --bigrams data/en/frequency_bigramdictionary_en_243_342.txt \\
        --out data/en/en.lex \\
        --contraction-backfill --contraction-repair

    python3 scripts/build-lexicon.py \\
        --unigrams data/is/unigrams.json.gz \\
        --bigrams data/is/bigrams.json.gz \\
        --out data/is/is.lex \\
        --bin-lookup /path/to/lemma-is/data-dist/lookup.tsv.gz \\
        --bin-lemmas /path/to/lemma-is/data-dist/lemmas.txt.gz

--bin-lookup/--bin-lemmas (Icelandic only) enable two ranking-noise prunes —
see load_bin_forms(), prune_non_bin_unigrams(), accent_dominance_filter()
docstrings below and "## .lex artifacts" in data/README.md for the full
rationale and before/after counts:
  1. drop unigrams that aren't BÍN surface forms, except the --bin-topk most
     frequent non-BÍN words and any at/above --bin-high-freq (foreign names,
     orgs, loanwords survive; typos/junk like "hester" don't)
  2. drop an unaccented word when an accented variant has >= --accent-ratio
     times its frequency (e.g. "islenskar" vs "íslenskar")

Input formats (auto-detected by gzip magic bytes):
  --unigrams: either
    - text, one entry per line: "word<space>count" (e.g. data/en/en-80k.txt)
    - gzipped JSON object {word: count, ...} (e.g. data/is/unigrams.json.gz)
  --bigrams: either
    - text, one entry per line: "word1 word2<space>count"
      (e.g. data/en/frequency_bigramdictionary_en_243_342.txt)
    - gzipped JSON. Two shapes are accepted:
        - a list of [word1, word2, count] triples
          (this is the actual shape of data/is/bigrams.json.gz)
        - an object {"word1 word2": count, ...} or {word1: {word2: count}}
          (accepted defensively; not required by the shipped data)

Normalization: lowercase + NFC, curly apostrophe (U+2019) folded to straight
ASCII apostrophe ('), keep only tokens matching
^[a-zþðæöáéíóúý]+('[a-zþðæöáéíóúý]+)*$ (ASCII letters + Icelandic-specific
letters, with internal apostrophes allowed for contractions/possessives like
"don't"/"o'clock" — a leading, trailing, or doubled apostrophe still fails
the match). Everything else (digits, punctuation, multi-token phrases) is
dropped. Bigrams where either word fails that filter, or where either word
isn't in the (filtered) unigram set, are dropped entirely — bigrams never
grow the unigram vocabulary. Duplicate keys (after normalization) have their
counts summed before scaling.

Contraction backfill: a curated list of common English contractions
(CONTRACTION_EXPANSIONS below) is checked after loading unigrams. Any that
are already present in the source are left untouched (as of the 2026-07-15
en-80k.txt, all of them are — SymSpell's list already includes "don't",
"i'm", "can't", etc.; the historical bug was the WORD_RE filter above
silently deleting them after loading, not a gap in the source itself). Any
curated contraction still missing after that is assigned a derived
frequency: freq(contraction) = bigram_freq(uncontracted phrase) // 2, using
the *raw* (pre-filter) bigram source's "word1 word2" count for the
contraction's expansion (e.g. freq("don't") ≈ bigram_freq("do", "not") // 2).
This is a same-corpus proxy (Google Ngram unigram and bigram counts are
comparable orders of magnitude — see FORMAT.md scaling notes) used only as a
fallback so the table degrades gracefully if a future source drops a
contraction; it does not fire against the current shipped data. Contractions
with no matching bigram entry are left absent rather than guessed at.

Contraction repair (v3, --contraction-repair, English only): backfill only
covers a contraction going *missing*; it does not fix one that is *present
but undercounted*, which is the actual bug found by the harness (2026-07-16
task #10) — en-80k.txt's own unigram counts for contractions run 10-40x
below independently-plausible values (e.g. raw "don't"=188,045 vs "font"
=2,568,450), because Google Ngram-derived unigram extraction evidently
undercounts apostrophe-tokens relative to their real usage (and, for
contractions whose bare skeleton is *also* a real dictionary word, e.g.
"cant"/"wont"/"lets", some of the contraction's mass was likely miscounted
into that bare word instead). See repair_contraction_frequencies() below for
the full method: it derives an independent frequency estimate for each
contraction from the bigram source's *own internal* conditional
probabilities (avoiding the false assumption above that unigram and bigram
counts share a scale — they don't, see the function docstring), raises the
contraction's frequency to at least that estimate, and — only when the
estimate alone already exceeds the bare skeleton's observed count, i.e. only
when the skeleton's own frequency isn't independently explainable — folds
down the skeleton's frequency (with a floor) to reflect that most of it was
probably misattributed contraction mass.

Frequencies are scaled to fit u32 when source counts exceed it (English
counts do; Icelandic counts don't). See FORMAT.md "Scaling to u32" for the
exact algorithm — it's also implemented below in scale_to_u32().

Stdlib only.
"""
import argparse
import gzip
import json
import math
import re
import struct
import unicodedata

MAGIC = 0x4C58_4331  # "LXC1"
VERSION = 1
U32_MAX = 0xFFFFFFFF

WORD_RE = re.compile(r"^[a-zþðæöáéíóúý]+('[a-zþðæöáéíóúý]+)*$")

# Curly/typographic apostrophe -> straight ASCII apostrophe, applied before
# NFC so both source spellings of a contraction collapse to one token.
_CURLY_APOSTROPHE = '’'

# Common English contractions we want present with sensible frequencies even
# if a future source list drops them. word -> two-word uncontracted phrase
# used to derive a fallback frequency from the bigram source. See the module
# docstring ("Contraction backfill") for the method.
#
# v4 (2026-07-16, corpus-dev contraction_damage diagnosis): extended beyond
# the original 22 with the rest of the common English contraction inventory
# (haven't/they'd/you'll/he's/who's/would've...). The original entries'
# repaired frequencies are UNCHANGED by the extension (each row's estimate
# is computed independently); the new rows both repair undercounted present
# contractions (haven't was 5,357 raw — below "font") and insert absent ones
# (hasn't, weren't, would've) at bigram-derived estimates. Skeleton-fold
# safety was checked per row before extending — see
# CONTRACTION_SKELETON_FOLD_EXEMPT below for the two real-word collisions.
CONTRACTION_EXPANSIONS = {
    "don't": ("do", "not"),
    "i'm": ("i", "am"),
    "it's": ("it", "is"),
    "can't": ("can", "not"),
    "won't": ("will", "not"),
    "isn't": ("is", "not"),
    "you're": ("you", "are"),
    "we're": ("we", "are"),
    "they're": ("they", "are"),
    "i've": ("i", "have"),
    "i'll": ("i", "will"),
    "didn't": ("did", "not"),
    "doesn't": ("does", "not"),
    "wasn't": ("was", "not"),
    "aren't": ("are", "not"),
    "couldn't": ("could", "not"),
    "wouldn't": ("would", "not"),
    "shouldn't": ("should", "not"),
    "that's": ("that", "is"),
    "there's": ("there", "is"),
    "what's": ("what", "is"),
    "let's": ("let", "us"),
    # --- v4 extension ---
    "haven't": ("have", "not"),
    "hasn't": ("has", "not"),
    "hadn't": ("had", "not"),
    "weren't": ("were", "not"),
    "they'd": ("they", "would"),
    "they'll": ("they", "will"),
    "they've": ("they", "have"),
    "we've": ("we", "have"),
    "we'd": ("we", "would"),
    "we'll": ("we", "will"),
    "you'll": ("you", "will"),
    "you've": ("you", "have"),
    "you'd": ("you", "would"),
    "he's": ("he", "is"),
    "she's": ("she", "is"),
    "he'd": ("he", "would"),
    "he'll": ("he", "will"),
    "she'd": ("she", "would"),
    "she'll": ("she", "will"),
    "i'd": ("i", "would"),
    "who's": ("who", "is"),
    "here's": ("here", "is"),
    "where's": ("where", "is"),
    "how's": ("how", "is"),
    "mustn't": ("must", "not"),
    "needn't": ("need", "not"),
    "would've": ("would", "have"),
    "could've": ("could", "have"),
    "should've": ("should", "have"),
    "must've": ("must", "have"),
}

# Skeletons repair_contraction_frequencies() must never fold down, even when
# the phrase estimate exceeds the observed skeleton count: these are common
# INDEPENDENT English words ("we wed in June", "a garden shed"), not mostly-
# contraction leakage — the self-consistent gate's two known false positives
# (measured: "wed" 1,014,344 vs a "we'd" estimate of ~17M; "shed" 6,240,911
# vs a "she'd" estimate of ~15M). Folding them to 10% would hand the
# engine's restoration-dominance gate (10x) a green light to auto-restore a
# deliberately typed "shed" into "she'd" — the exact valid-word violation
# the conservatism rules exist to prevent. The gate's other real-word
# collisions need no exemption: "well"/"hell"/"shell"/"id"/"its"/"were"/
# "ill" all have observed counts ABOVE their contraction's estimate, so the
# fold never fires for them (verified in the v4 dry-run table).
CONTRACTION_SKELETON_FOLD_EXEMPT = {"wed", "shed"}


def is_gzip(path):
    with open(path, 'rb') as f:
        return f.read(2) == b'\x1f\x8b'


def normalize_word(w):
    """Lowercase + NFC; return None if it doesn't survive the letter filter."""
    w = w.replace(_CURLY_APOSTROPHE, "'")
    w = unicodedata.normalize('NFC', w.lower())
    if not WORD_RE.match(w):
        return None
    return w


def backfill_contractions(unigram_counts, raw_bigrams):
    """Ensure CONTRACTION_EXPANSIONS keys exist in unigram_counts. Returns the
    list of (word, derived_freq) actually added, for logging."""
    bigram_phrase_freq = {}
    for w1, w2, count in raw_bigrams:
        nw1 = normalize_word(w1)
        nw2 = normalize_word(w2)
        if nw1 is None or nw2 is None:
            continue
        key = (nw1, nw2)
        bigram_phrase_freq[key] = bigram_phrase_freq.get(key, 0) + count

    added = []
    for contraction, phrase in CONTRACTION_EXPANSIONS.items():
        if contraction in unigram_counts:
            continue
        freq = bigram_phrase_freq.get(phrase)
        if freq is None:
            continue
        derived = max(1, freq // 2)
        unigram_counts[contraction] = derived
        added.append((contraction, derived))
    return added


def repair_contraction_frequencies(unigram_counts, raw_bigrams, skeleton_floor_fraction=0.1):
    """Correct undercounted English contraction frequencies (task #10,
    2026-07-16): en-80k.txt's own unigram counts for contractions are
    10-40x below independently-plausible values (raw "don't"=188,045 vs
    "font"=2,568,450 — nobody types "font" more than 13x as often as
    "don't"). This makes the beam decoder's lane-relaxation apostrophe fold
    (PLAN.md "EN apostrophe folding dont->don't... ~ε") offer-only instead
    of auto-applying: the folded target's frequency is too low to win, and
    for contractions whose bare skeleton is *also* a real word (can't/cant,
    won't/wont), the skeleton's frequency is backwards-dominant over the
    contraction, which is exactly the wrong direction for the collision
    dominance gate PLAN.md describes for the accent-folding mirror case.

    Method — independent frequency estimate via the bigram file's own
    internal conditional probabilities:

    A tempting shortcut is "use bigram_freq(do, not) as a proxy for
    freq(don't)" (this is literally what --contraction-backfill already
    does as a *missing-entry* fallback). But en-80k.txt (unigrams) and
    frequency_bigramdictionary_en_243_342.txt (bigrams) are NOT the same
    corpus scale — verified empirically here: the single most reliable
    unigram ("the"=26,548,583,149) is smaller than the single most reliable
    bigram ("of the"=177,045,273,024), which is logically impossible within
    one consistent corpus (a bigram can never occur more often than either
    of its own words) and proves the two SymSpell-derived files come from
    differently-scaled extractions. Worse, the size of that mismatch is not
    a fixed ratio: measured per-pair ("of the" vs "the": 6.7x; "in the" vs
    "in": 12.3x; "do not" vs "do": 37.4x), it varies enough that no single
    global divisor gives trustworthy absolute numbers (previously tried and
    rejected during this fix: it put contractions above "the" itself).

    What *is* reliable across the two files is a conditional PROBABILITY,
    not an absolute count: P(w2 | w1) = bigram_freq(w1, w2) / (total bigram
    mass starting with w1) is a same-corpus ratio (computed entirely inside
    the bigram file), and this fraction is assumed to transfer reasonably
    well onto the unigram file's trusted count for w1 (word-pair grammar
    doesn't shift much between corpus vintages, even if absolute corpus
    size does). So each contraction's expansion phrase (w1, w2) gets two
    independent projections back onto the unigram file's scale:

        est_via_w1 = unigram_freq(w1) * bigram_freq(w1,w2) / fanout(w1, *)
        est_via_w2 = unigram_freq(w2) * bigram_freq(*,w2) / fanout(*, w2)

    and the estimate used is min(est_via_w1, est_via_w2) — the more
    conservative of the two directions, so a skewed fan-out on either side
    can only push the estimate down, never up. Sanity-checked against known
    frequencies in en-80k.txt: this method puts "don't" (~290M) in the same
    tier as "should"/"would"/"could" (407M/736M/443M) and "can't" (~143M)
    above "house" (158M) but below "will" (742M) — plausible for words this
    common in casual (mobile-typed) English, unlike the raw source's
    "don't"=188,045 (below "font").

    Skeleton reassignment: a contraction's bare skeleton (apostrophe
    stripped, e.g. "cant") is only ever adjusted, never for contractions
    whose skeleton is absent from the source (nothing to reassign). When
    present, the skeleton is reduced ONLY IF the independent phrase estimate
    above already exceeds the skeleton's observed frequency — i.e. only
    when the evidence says the "true" contraction volume alone is bigger
    than what's currently sitting in the skeleton bucket, meaning the
    skeleton's own count doesn't need an "it's also a genuine independent
    word" explanation to account for it. This is a self-consistent gate,
    not a hardcoded per-word judgment call: it naturally leaves real,
    independently-dominant collision words alone (measured: "its" stays
    untouched — 684,717,118 vs an "it's" estimate of ~397M, i.e. estimate <
    skeleton; same for "were"/we're and "ill"/i'll) while correcting the
    cases where the skeleton is mostly contraction leakage (measured:
    "cant" 996,416 vs "can't" estimate ~143M, "wont" 1,862,783 vs "won't"
    estimate ~63M, "lets" 3,004,900 vs "let's" estimate ~10M, "whats"
    67,648 vs "what's" estimate ~55M — all get folded down). When folding
    down, `skeleton_floor_fraction` (default 0.1, --contraction-skeleton-
    floor) keeps at least that fraction of the observed skeleton count
    rather than zeroing it — per PLAN.md's "keep a floor so genuinely-typed
    'dont' still ranks", some of the skeleton spelling is presumably still
    deliberately typed even where evidence says most of it is a corpus
    artifact.

    Never applied to CONTRACTION_EXPANSIONS' English word pairs against a
    non-English bigram source, same rationale as --contraction-backfill.

    Returns a list of report rows (one per curated contraction, in
    CONTRACTION_EXPANSIONS order):
        (contraction, old_c_freq, new_c_freq,
         skeleton, old_s_freq, new_s_freq, phrase_estimate)
    for the diagnosis table printed by the caller.
    """
    fanout_w1 = {}
    fanout_w2 = {}
    phrase_freq = {}
    for w1, w2, count in raw_bigrams:
        nw1 = normalize_word(w1)
        nw2 = normalize_word(w2)
        if nw1 is None or nw2 is None:
            continue
        fanout_w1[nw1] = fanout_w1.get(nw1, 0) + count
        fanout_w2[nw2] = fanout_w2.get(nw2, 0) + count
        phrase_freq[(nw1, nw2)] = phrase_freq.get((nw1, nw2), 0) + count

    rows = []
    for contraction, (w1, w2) in CONTRACTION_EXPANSIONS.items():
        skeleton = contraction.replace("'", "")
        old_c = unigram_counts.get(contraction, 0)
        old_s = unigram_counts.get(skeleton, 0)

        phrase = phrase_freq.get((w1, w2), 0)
        fw1 = fanout_w1.get(w1, 0)
        fw2 = fanout_w2.get(w2, 0)
        est_via_w1 = (unigram_counts[w1] * phrase / fw1) if fw1 and w1 in unigram_counts else 0.0
        est_via_w2 = (unigram_counts[w2] * phrase / fw2) if fw2 and w2 in unigram_counts else 0.0
        if est_via_w1 and est_via_w2:
            phrase_estimate = min(est_via_w1, est_via_w2)
        else:
            phrase_estimate = est_via_w1 or est_via_w2

        new_c = max(old_c, round(phrase_estimate))
        if new_c > 0:
            unigram_counts[contraction] = new_c

        new_s = old_s
        if (
            old_s > 0
            and phrase_estimate > old_s
            and skeleton not in CONTRACTION_SKELETON_FOLD_EXEMPT
        ):
            new_s = max(1, math.ceil(old_s * skeleton_floor_fraction))
            unigram_counts[skeleton] = new_s

        rows.append((contraction, old_c, new_c, skeleton, old_s, new_s, round(phrase_estimate)))
    return rows


def print_contraction_report(rows):
    """Print the before/after diagnosis table for repair_contraction_frequencies()."""
    header = (
        f'{"contraction":<10} {"cur_freq":>12} {"new_freq":>12}  '
        f'{"skeleton":<10} {"skel_before":>12} {"skel_after":>12}  {"phrase_est":>12}'
    )
    print(header)
    print('-' * len(header))
    for contraction, old_c, new_c, skeleton, old_s, new_s, phrase_estimate in rows:
        print(
            f'{contraction:<10} {old_c:>12} {new_c:>12}  '
            f'{skeleton:<10} {old_s:>12} {new_s:>12}  {phrase_estimate:>12}'
        )


def load_unigrams(path):
    counts = {}
    if is_gzip(path):
        with gzip.open(path, 'rt', encoding='utf-8') as f:
            raw = json.load(f)
        if not isinstance(raw, dict):
            raise ValueError(f'unexpected unigram JSON shape in {path}: {type(raw).__name__}')
        items = raw.items()
    else:
        def _iter_text():
            with open(path, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.rstrip('\n')
                    if not line:
                        continue
                    parts = line.rsplit(' ', 1)
                    if len(parts) != 2:
                        continue
                    yield parts[0], parts[1]
        items = _iter_text()

    for word, count in items:
        nw = normalize_word(word)
        if nw is None:
            continue
        counts[nw] = counts.get(nw, 0) + int(count)
    return counts


def load_bigrams(path):
    """Returns a list of (word1, word2, count) triples, pre-filter — the
    caller normalizes and intersects with the unigram set."""
    triples = []
    if is_gzip(path):
        with gzip.open(path, 'rt', encoding='utf-8') as f:
            raw = json.load(f)
        if isinstance(raw, list):
            # Actual shape of data/is/bigrams.json.gz: [[w1, w2, count], ...]
            for entry in raw:
                if len(entry) != 3:
                    continue
                w1, w2, count = entry
                triples.append((w1, w2, int(count)))
        elif isinstance(raw, dict):
            for k, v in raw.items():
                if isinstance(v, dict):
                    for w2, count in v.items():
                        triples.append((k, w2, int(count)))
                else:
                    parts = k.split(' ', 1)
                    if len(parts) == 2:
                        triples.append((parts[0], parts[1], int(v)))
        else:
            raise ValueError(f'unexpected bigram JSON shape in {path}: {type(raw).__name__}')
    else:
        with open(path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.rstrip('\n')
                if not line:
                    continue
                parts = line.rsplit(' ', 1)
                if len(parts) != 2:
                    continue
                words_part, count_s = parts
                word_bits = words_part.split(' ')
                if len(word_bits) != 2:
                    continue
                triples.append((word_bits[0], word_bits[1], int(count_s)))
    return triples


def load_bin_forms(lookup_path, lemmas_path):
    """Load the set of valid BÍN surface forms from lemma-is's dist data.

    IMPORTANT: `lookup.tsv.gz` alone is NOT the full BÍN form set — per
    lemma-is's `scripts/build-data.py` (see the "Skip if word is its own
    only lemma" comment there), it deliberately *omits* any word that is its
    own lemma with no other lemma/POS ambiguity, since a lemma-lookup index
    has nothing useful to say about a word that already equals its own
    lemma. That skip rule excludes basic base-form vocabulary wholesale —
    pronouns ("hann", "ég"), nominative-singular nouns ("hestur"), adverbs
    ("einnig"), proper nouns ("reykjavík"), etc. Using `lookup.tsv.gz` alone
    would flag roughly a third of all common Icelandic words as "non-BÍN"
    noise. The fix: union `lookup.tsv.gz`'s keys (inflected/ambiguous forms)
    with `lemmas.txt.gz` (one lemma per line — the base forms) to get the
    complete surface-form set.

    `lookup.tsv.gz` format: `word\\tidx1:pos1,idx2:pos2,...` (first column is
    the surface form; only that column is used here).
    `lemmas.txt.gz` format: one lemma per line.

    Returns a set of lowercased, NFC-normalized forms.
    """
    forms = set()
    with gzip.open(lookup_path, 'rt', encoding='utf-8') as f:
        for line in f:
            tab = line.find('\t')
            word = line[:tab] if tab >= 0 else line.rstrip('\n')
            if word:
                forms.add(unicodedata.normalize('NFC', word.lower()))
    with gzip.open(lemmas_path, 'rt', encoding='utf-8') as f:
        for line in f:
            lemma = line.rstrip('\n')
            if lemma:
                forms.add(unicodedata.normalize('NFC', lemma.lower()))
    return forms


def prune_non_bin_unigrams(unigram_counts, bin_forms, topk, high_freq_threshold):
    """Drop is.lex unigrams that are not BÍN surface forms, with two escape
    hatches so legitimate non-BÍN vocabulary (foreign proper nouns, sports
    teams, orgs/abbreviations, English loanwords Icelanders type constantly
    in a news-derived corpus) survives:

      1. the `topk` most frequent non-BÍN words are always kept
      2. any non-BÍN word at or above `high_freq_threshold` is always kept,
         even if (1) is later tuned down and would otherwise exclude it

    is.lex is RANKING-only (validity comes from BÍN via bin-morph.bin in the
    engine — see PLAN.md), so this can prune aggressively: a dropped word
    just stops being ranked/suggested, it doesn't become "invalid".

    Returns (dropped: list[(word, freq)], kept_non_bin: int) for reporting.
    """
    non_bin = [(w, c) for w, c in unigram_counts.items() if w not in bin_forms]
    non_bin.sort(key=lambda kv: -kv[1])
    keep_topk = {w for w, _ in non_bin[:topk]}

    dropped = []
    kept_non_bin = 0
    for w, c in non_bin:
        if w in keep_topk or c >= high_freq_threshold:
            kept_non_bin += 1
            continue
        dropped.append((w, c))
    for w, _ in dropped:
        del unigram_counts[w]
    return dropped, kept_non_bin


_ACCENT_FOLD_STRIP_CATEGORY = 'Mn'  # Unicode "Mark, nonspacing"


def strip_icelandic_accents(w):
    """Fold NFD-decomposable accented letters (á,é,í,ó,ú,ý,ö — each is a base
    letter + combining diacritic under NFD) down to their ASCII base letter,
    e.g. 'ö' -> 'o'. þ, ð, æ are NOT decomposable (they're independent
    letters, not base+diacritic) and pass through unchanged — there's no
    single-character ASCII substitute a keyboard-without-Icelandic-support
    would produce for them the way `a` substitutes for `á`."""
    decomposed = unicodedata.normalize('NFD', w)
    return ''.join(c for c in decomposed if unicodedata.category(c) != _ACCENT_FOLD_STRIP_CATEGORY)


def accent_dominance_filter(unigram_counts, ratio):
    """Drop an unaccented word `w` when an accented variant exists (i.e.
    `strip_icelandic_accents(variant) == w` for some other word `variant` in
    the table) whose frequency is >= `ratio` times `w`'s. This targets the
    specific noise pattern of accents dropped by non-Icelandic input methods
    (íslenska -> islenska): the correctly-accented spelling dominating by a
    wide margin is strong evidence the unaccented spelling is typo noise
    rather than a distinct, legitimately-unaccented word.

    Returns the list of (dropped_word, dropped_freq, dominant_accented_freq)
    for reporting.
    """
    folded_to_accented = {}
    for w in unigram_counts:
        folded = strip_icelandic_accents(w)
        if folded != w:
            folded_to_accented.setdefault(folded, []).append(w)

    dropped = []
    for folded, accented_variants in folded_to_accented.items():
        if folded not in unigram_counts:
            continue
        unaccented_freq = unigram_counts[folded]
        dominant_freq = max(unigram_counts[v] for v in accented_variants)
        if dominant_freq >= ratio * unaccented_freq:
            dropped.append((folded, unaccented_freq, dominant_freq))

    for folded, _, _ in dropped:
        del unigram_counts[folded]
    return dropped


# Icelandic date-vocabulary frequency floors (2026-07-19 dogfood: "17. juni"
# autocorrected to "muni" instead of restoring "júní"). The unigram source
# (lemma-is `unigrams.json.gz`, extracted from icegrams) was counted AFTER
# Greynir's tokenizer merged date expressions ("17. júní 2024", "í júní")
# into composite DATE tokens — and month names occur almost exclusively
# inside such expressions, so their surviving counts are noise-level or
# zero (observed: janúar/febrúar/mars/apríl/júlí/nóvember absent, júní=353,
# maí=135, september=48, desember=20; ágúst=28,015 only because the personal
# name Ágúst lowercases into it). Weekday nominatives take collateral damage
# from merged "mánudagurinn 17. júní"-style spans (observed ~400-1,000),
# while their accusatives survive on bare "á mánudaginn" (mánudaginn=20,639).
#
# Floors, not replacements: max(observed, floor), applied only on the
# Icelandic (--bin-lookup) path. Calibration: the source corpus is ~1B
# tokens (í=25.4M ≈ 25k/M matches its known rate), and month names run
# ~300-800 per million in Icelandic news/web text, so a flat 400,000
# lands mid-range — comparable to gær=499,503 and safely above competing
# rewrite candidates like muni=172,582, which is what lets the near-free
# diacritic restoration win the margin. Weekday nominatives are floored
# just above their surviving accusative sibling's observed count.
ICELANDIC_MONTH_FREQ_FLOOR = 400_000
ICELANDIC_WEEKDAY_FREQ_FLOOR = 25_000
ICELANDIC_DATE_VOCAB_FLOORS = {
    **{month: ICELANDIC_MONTH_FREQ_FLOOR for month in (
        'janúar', 'febrúar', 'mars', 'apríl', 'maí', 'júní',
        'júlí', 'ágúst', 'september', 'október', 'nóvember', 'desember',
    )},
    **{day: ICELANDIC_WEEKDAY_FREQ_FLOOR for day in (
        'mánudagur', 'þriðjudagur', 'miðvikudagur', 'fimmtudagur',
        'föstudagur', 'laugardagur', 'sunnudagur',
    )},
}


def repair_icelandic_date_vocabulary(unigram_counts):
    """Raise date-vocabulary unigrams to ICELANDIC_DATE_VOCAB_FLOORS (see the
    constant's comment for the icegrams DATE-token root cause). Runs before
    the BÍN prunes so the accent-dominance filter sees the repaired
    frequencies (e.g. a repaired "júní" correctly dominates any residual
    unaccented "juni" noise). Returns (word, observed, floored) rows for
    reporting; observed is 0 for words absent from the source.
    """
    rows = []
    for word, floor in sorted(ICELANDIC_DATE_VOCAB_FLOORS.items()):
        observed = unigram_counts.get(word, 0)
        if observed < floor:
            unigram_counts[word] = floor
            rows.append((word, observed, floor))
    return rows


def scale_to_u32(counts_by_key):
    """counts_by_key: dict key -> int count (arbitrary size).
    Returns (dict key -> scaled UInt32-safe count, divisor used)."""
    if not counts_by_key:
        return {}, 1
    max_count = max(counts_by_key.values())
    if max_count <= U32_MAX:
        divisor = 1
    else:
        divisor = -(-max_count // U32_MAX)  # ceil division
    scaled = {k: max(1, v // divisor) for k, v in counts_by_key.items()}
    return scaled, divisor


def build(
    unigrams_path, bigrams_path, out_path,
    bin_lookup_path=None, bin_lemmas_path=None,
    bin_topk=10_000, bin_high_freq=2_000, accent_ratio=10,
    contraction_backfill=False,
    contraction_repair=False, contraction_skeleton_floor=0.1,
):
    unigram_counts = load_unigrams(unigrams_path)
    if not unigram_counts:
        raise ValueError('no valid unigrams survived normalization/filtering')
    unigram_count_before_pruning = len(unigram_counts)

    raw_bigrams = load_bigrams(bigrams_path)

    # English-only, see repair_contraction_frequencies() docstring: fixes
    # contractions that are *present* but undercounted (task #10,
    # 2026-07-16), and inserts absent curated contractions at the
    # conditional-probability estimate. MUST run BEFORE the backfill: the
    # backfill's raw `bigram_freq(phrase) // 2` proxy is on the bigram
    # file's own (larger) corpus scale — fine as a nothing-better fallback,
    # but if it inserted a missing contraction first, the repair's
    # max(old, estimate) would keep the bogusly huge value (v4 lesson:
    # "would've" landed at 1.48B — above "have" itself — when the backfill
    # ran first).
    if contraction_repair:
        repair_rows = repair_contraction_frequencies(
            unigram_counts, raw_bigrams, skeleton_floor_fraction=contraction_skeleton_floor,
        )
        print('\ncontraction frequency repair (--contraction-repair):')
        print_contraction_report(repair_rows)
        print()

    # English-only: CONTRACTION_EXPANSIONS keys/phrases are English words, so
    # running this against the Icelandic bigram source would occasionally
    # match a stray English bigram in the web corpus (e.g. a quoted "do not")
    # and inject noise like "don't" into is.lex. Opt-in via --contraction-backfill.
    # With --contraction-repair also on, this is pure belt-and-braces: repair
    # already inserted every curated contraction whose expansion phrase the
    # bigram source attests, so the backfill only fires for entries the
    # repair could not estimate at all.
    if contraction_backfill:
        backfilled = backfill_contractions(unigram_counts, raw_bigrams)
        if backfilled:
            print(
                'backfilled contractions missing from unigram source: '
                + ', '.join(f'{w}={f}' for w, f in backfilled)
            )

    if bin_lookup_path and bin_lemmas_path:
        date_repairs = repair_icelandic_date_vocabulary(unigram_counts)
        if date_repairs:
            print(
                'date-vocabulary frequency repair (icegrams DATE-token undercount): '
                + ', '.join(f'{w} {old}->{new}' for w, old, new in date_repairs)
            )

        bin_forms = load_bin_forms(bin_lookup_path, bin_lemmas_path)
        dropped_non_bin, kept_non_bin = prune_non_bin_unigrams(
            unigram_counts, bin_forms, topk=bin_topk, high_freq_threshold=bin_high_freq,
        )
        print(
            f'BÍN-membership prune: {unigram_count_before_pruning} -> {len(unigram_counts)} unigrams '
            f'({len(dropped_non_bin)} dropped as non-BÍN noise, {kept_non_bin} non-BÍN words kept '
            f'via top-{bin_topk}/freq>={bin_high_freq} escape hatch)'
        )

        before_accent = len(unigram_counts)
        dropped_accents = accent_dominance_filter(unigram_counts, ratio=accent_ratio)
        print(
            f'Accent-dominance prune (ratio>={accent_ratio}x): {before_accent} -> '
            f'{len(unigram_counts)} unigrams ({len(dropped_accents)} unaccented-noise words dropped)'
        )
        if dropped_accents:
            sample = sorted(dropped_accents, key=lambda t: -t[2])[:10]
            print(
                '  sample drops (unaccented, its freq, dominant accented freq): '
                + ', '.join(f'{w}({f}, dominated by {af})' for w, f, af in sample)
            )

    bigram_counts = {}
    dropped_bigrams = 0
    for w1, w2, count in raw_bigrams:
        nw1 = normalize_word(w1)
        nw2 = normalize_word(w2)
        if nw1 is None or nw2 is None or nw1 not in unigram_counts or nw2 not in unigram_counts:
            dropped_bigrams += 1
            continue
        key = (nw1, nw2)
        bigram_counts[key] = bigram_counts.get(key, 0) + count

    scaled_unigrams, uni_divisor = scale_to_u32(unigram_counts)
    scaled_bigrams, bi_divisor = scale_to_u32(bigram_counts)

    sorted_words = sorted(scaled_unigrams.keys(), key=lambda w: w.encode('utf-8'))
    word_id = {w: i for i, w in enumerate(sorted_words)}

    pool = bytearray()
    word_offsets = []
    word_lengths = []
    for w in sorted_words:
        b = w.encode('utf-8')
        if len(b) > 255:
            raise ValueError(f'word too long ({len(b)} bytes): {w!r}')
        word_offsets.append(len(pool))
        word_lengths.append(len(b))
        pool.extend(b)
    while len(pool) % 4 != 0:
        pool.append(0)

    word_freqs = [scaled_unigrams[w] for w in sorted_words]

    sorted_bigram_keys = sorted(
        bigram_counts.keys(), key=lambda p: (word_id[p[0]], word_id[p[1]])
    )
    bigram_first_ids = [word_id[p[0]] for p in sorted_bigram_keys]
    bigram_second_ids = [word_id[p[1]] for p in sorted_bigram_keys]
    bigram_freqs = [scaled_bigrams[p] for p in sorted_bigram_keys]

    total_unigram_tokens = sum(word_freqs)
    unigram_count = len(sorted_words)
    bigram_count = len(sorted_bigram_keys)

    with open(out_path, 'wb') as f:
        header = struct.pack(
            '<IIIIIQI',
            MAGIC, VERSION, unigram_count, bigram_count, len(pool),
            total_unigram_tokens, 0,
        )
        assert len(header) == 32
        f.write(header)
        f.write(bytes(pool))
        for off in word_offsets:
            f.write(struct.pack('<I', off))
        for length in word_lengths:
            f.write(struct.pack('<B', length))
        pad = (-unigram_count) % 4
        f.write(b'\x00' * pad)
        for freq in word_freqs:
            f.write(struct.pack('<I', freq))
        for wid in bigram_first_ids:
            f.write(struct.pack('<I', wid))
        for wid in bigram_second_ids:
            f.write(struct.pack('<I', wid))
        for freq in bigram_freqs:
            f.write(struct.pack('<I', freq))

    print(
        f'{out_path}: {unigram_count} unigrams (scale divisor={uni_divisor}), '
        f'{bigram_count} bigrams (scale divisor={bi_divisor}, dropped={dropped_bigrams}), '
        f'totalUnigramTokens={total_unigram_tokens}'
    )


def main():
    parser = argparse.ArgumentParser(description='Build a .lex frequency binary.')
    parser.add_argument('--unigrams', required=True, help='word-frequency source file')
    parser.add_argument('--bigrams', required=True, help='bigram-frequency source file')
    parser.add_argument('--out', required=True, help='output .lex path')
    parser.add_argument(
        '--bin-lookup', default=None,
        help='lemma-is lookup.tsv.gz (inflected surface forms); combined with '
             '--bin-lemmas to prune non-BÍN unigram noise. Icelandic build only.')
    parser.add_argument(
        '--bin-lemmas', default=None,
        help='lemma-is lemmas.txt.gz (base lemma forms). Required alongside '
             '--bin-lookup — lookup.tsv.gz alone omits base/lemma forms, see '
             'load_bin_forms() docstring.')
    parser.add_argument(
        '--bin-topk', type=int, default=10_000,
        help='always keep this many of the most frequent non-BÍN unigrams (default 10000)')
    parser.add_argument(
        '--bin-high-freq', type=int, default=2_000,
        help='always keep non-BÍN unigrams at/above this frequency, regardless of --bin-topk (default 2000)')
    parser.add_argument(
        '--accent-ratio', type=int, default=10,
        help='drop an unaccented word if an accented variant has >= this many times its '
             'frequency; only runs when --bin-lookup/--bin-lemmas are given (default 10)')
    parser.add_argument(
        '--contraction-backfill', action='store_true',
        help='enable the CONTRACTION_EXPANSIONS fallback (English only — see '
             'backfill_contractions() docstring; do not pass for the Icelandic build)')
    parser.add_argument(
        '--contraction-repair', action='store_true',
        help='correct undercounted CONTRACTION_EXPANSIONS frequencies using bigram-derived '
             'conditional-probability estimates, folding down colliding bare skeletons where '
             'warranted (English only — see repair_contraction_frequencies() docstring; do '
             'not pass for the Icelandic build)')
    parser.add_argument(
        '--contraction-skeleton-floor', type=float, default=0.1,
        help='when repair_contraction_frequencies() folds down a bare skeleton (e.g. "cant"), '
             'keep at least this fraction of its observed frequency rather than zeroing it '
             '(default 0.1); only takes effect with --contraction-repair')
    args = parser.parse_args()
    build(
        args.unigrams, args.bigrams, args.out,
        bin_lookup_path=args.bin_lookup, bin_lemmas_path=args.bin_lemmas,
        bin_topk=args.bin_topk, bin_high_freq=args.bin_high_freq, accent_ratio=args.accent_ratio,
        contraction_backfill=args.contraction_backfill,
        contraction_repair=args.contraction_repair,
        contraction_skeleton_floor=args.contraction_skeleton_floor,
    )


if __name__ == '__main__':
    main()
