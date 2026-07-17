#!/usr/bin/env python3
"""
analyze.py — merge a DEV-MODE typing session's app + keyboard timelines and
classify autocorrect-quality events into eval-ready candidates.

Stdlib only. Run:

    python3 analyze.py [SESSIONS_DIR]     # default: ./sessions

For every `<id>-app.jsonl` (+ optional `<id>-kb.jsonl`) pair it writes, next
to the inputs:

    <id>-report.md         human-readable: counts, event list w/ context,
                           per-key tap-offset stats
    <id>-candidates.jsonl  one {typo,intended,context,lang,class} per line,
                           shaped like data/eval/dev.jsonl so events drop
                           straight into the eval corpus / scenarios.

Event classes
-------------
AUTOCORRECT_UNDONE  keyboard auto-applied a correction, user backspaced to
                    restore the word they originally typed (a false autocorrect).
MISS_OFFERED        user backspace-retyped to a word that WAS in the bar at
                    typing time — the correction was available but not applied
                    (gating too conservative).
MISS_ABSENT         user backspace-retyped to a word the bar never offered
                    (a ranking / candidate-generation miss).
INFLECTION_MISS     a MISS whose intended word shares a lemma-ish stem with a
                    bar offer differing only in an inflectional ending — routes
                    to the inflection backlog, not the corrector.
TAP_USED            user tapped a suggestion in the bar.
CLEAN               a word committed with no correction, retype, or tap.

The app timeline (full pad text snapshots with timestamps) is authoritative;
the kb log supplies what the engine offered/applied and the touch samples.

v2 additions
------------
* Episode alignment is now word-level (difflib over peak-vs-end word lists)
  with plausibility-based pairing, so an erase-then-retype that replaces one
  word with a LONGER stretch pairs only the aligned word (e.g. "foðu"→"góðu",
  not "foðu"→"af") and leaves the extra words as insertions.
* INFLECTION_MISS retags split-case MISSes (shared prefix >= 60% of length,
  differing only in a short inflectional suffix).
* A SILENT_MISS pass scans the FINAL committed text for uncorrected typos:
  tokens not attested in either lexicon (authoritatively via the type-repl
  `:word` command, falling back to the frequency corpora) that have a
  high-frequency neighbour within 1-2 cheap keyboard/accent edits. Tokens
  with no confident neighbour are UNRESOLVABLE (keyboard mash). These are a
  human-in-the-loop signal reported in the markdown, not eval candidates.
"""

import difflib
import gzip
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Optional

import greynir_enrich
import taxonomy


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------

@dataclass
class AppRecord:
    t: float
    sid: str
    kind: str   # start | snapshot | stop
    text: str


@dataclass
class KBRecord:
    t: float
    sid: str
    window: str
    field: str
    bar: list          # [{text, ac, vb, rs, conf}]
    applied: dict       # {kind: none|autocorrect|tap, text}
    taps: list          # [{c, dx, dy}]
    backspaces: int


def _read_jsonl(path: str) -> list:
    out = []
    if not os.path.exists(path):
        return out
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def load_session(app_path: str, kb_path: str):
    app = [
        AppRecord(t=r.get("t", 0.0), sid=r.get("sid", ""),
                  kind=r.get("kind", "snapshot"), text=r.get("text", ""))
        for r in _read_jsonl(app_path)
    ]
    kb = [
        KBRecord(
            t=r.get("t", 0.0), sid=r.get("sid", ""),
            window=r.get("window", ""), field=r.get("field", "standard"),
            bar=r.get("bar", []), applied=r.get("applied", {"kind": "none"}),
            taps=r.get("taps", []), backspaces=r.get("backspaces", 0))
        for r in _read_jsonl(kb_path)
    ]
    app.sort(key=lambda r: r.t)
    kb.sort(key=lambda r: r.t)
    return app, kb


# --------------------------------------------------------------------------
# Text helpers
# --------------------------------------------------------------------------

def common_prefix_len(a: str, b: str) -> int:
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


def first_word(s: str) -> str:
    """First whitespace-delimited word of `s` (leading space tolerated)."""
    return s.strip().split(" ", 1)[0].split("\n", 1)[0] if s.strip() else ""


def words(s: str) -> list:
    return [w for w in s.replace("\n", " ").split(" ") if w]


IS_LETTERS = set("áéíóúýðþæöÁÉÍÓÚÝÐÞÆÖ")


def guess_lang(word: str) -> str:
    return "is" if any(ch in IS_LETTERS for ch in word) else "en"


def edit_distance(a: str, b: str) -> int:
    """Plain Levenshtein distance (row-DP)."""
    if a == b:
        return 0
    n, m = len(a), len(b)
    if n == 0 or m == 0:
        return max(n, m)
    prev = list(range(m + 1))
    for i in range(1, n + 1):
        cur = [i] + [0] * m
        for j in range(1, m + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            cur[j] = min(cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
        prev = cur
    return prev[m]


def plausible_edit(e: str, r: str) -> bool:
    """Is `r` a plausible correction target for `e` — a shared stem or a cheap
    whole-word edit? Used to align an erased word against a longer retyped
    stretch (so "foðu" pairs with "góðu", never the inserted "af")."""
    el, rl = e.lower(), r.lower()
    if el == rl:
        return False
    cp = common_prefix_len(el, rl)
    ed = edit_distance(el, rl)
    mn = min(len(el), len(rl))
    mx = max(len(el), len(rl))
    return cp >= 0.5 * mn or ed <= max(2, mx // 3)


def word_start_offset(text: str, word_idx: int) -> int:
    """Character offset in `text` where the `word_idx`-th whitespace word (per
    `words()`) begins. Newlines are treated as spaces (1:1, so offsets in the
    original string stay valid)."""
    norm = text.replace("\n", " ")
    i, n, count = 0, len(norm), 0
    while i < n:
        while i < n and norm[i] == " ":
            i += 1
        if i >= n:
            break
        start = i
        while i < n and norm[i] != " ":
            i += 1
        if count == word_idx:
            return start
        count += 1
    return len(norm)


# --------------------------------------------------------------------------
# Episode detection (erase-then-retype on the app timeline)
# --------------------------------------------------------------------------

@dataclass
class Episode:
    t: float        # time of the peak (before backspacing began)
    end_t: float    # time the retyped text settled
    peak: str       # text right before backspacing began
    trough: str     # shortest text during the episode
    end: str        # text after retyping settled


def find_episodes(states: list) -> list:
    """`states` is the ordered list of AppRecord. An episode is a maximal
    run where the text length first strictly decreases (backspacing) then
    non-decreases (retyping), ending when growth settles."""
    episodes = []
    texts = [s.text for s in states]
    i = 1
    n = len(texts)
    while i < n:
        if len(texts[i]) < len(texts[i - 1]):
            peak = texts[i - 1]
            peak_t = states[i - 1].t
            # descend to the trough (through consecutive non-increases)
            j = i
            while j + 1 < n and len(texts[j + 1]) <= len(texts[j]):
                j += 1
            trough = texts[j]
            # ascend through retyping (consecutive non-decreases)
            k = j
            while k + 1 < n and len(texts[k + 1]) >= len(texts[k]):
                k += 1
            end = texts[k]
            if end != peak and trough != peak:
                episodes.append(
                    Episode(t=peak_t, end_t=states[k].t, peak=peak, trough=trough, end=end))
            i = k + 1
        else:
            i += 1
    return episodes


# --------------------------------------------------------------------------
# Classification
# --------------------------------------------------------------------------

@dataclass
class Event:
    cls: str
    t: float
    typo: str
    intended: str
    context: list = field(default_factory=list)
    offered_bar: list = field(default_factory=list)
    note: str = ""     # e.g. the inflected bar offer for an INFLECTION_MISS

    def to_candidate(self) -> dict:
        cand = {
            "typo": self.typo,
            "intended": self.intended,
            "context": self.context,
            "lang": guess_lang(self.intended or self.typo),
            "class": self.cls,
        }
        if self.note:
            cand["note"] = self.note
        return cand


def _autocorrect_for(kb: list, word: str, before_t: float, after_t: float) -> bool:
    """Was `word` auto-applied by the keyboard between after_t and before_t?"""
    for r in kb:
        if after_t <= r.t <= before_t and r.applied.get("kind") == "autocorrect":
            if r.applied.get("text") == word:
                return True
    return False


def _committed_part(window: str) -> str:
    """The window minus its trailing partial word (keeps the trailing space)."""
    return window[: len(window) - len(last_word(window))]


def _pass_is_typing(r: KBRecord, typo: str, prefix: str) -> bool:
    """Whether kb pass `r` happened while the user was typing the word `typo`
    at the position whose committed text is `prefix` (`ep.peak[:ws]`). Its
    window tail must be a prefix of typo AND its committed part must be a suffix
    of `prefix` — the latter pins the word POSITION so a same-prefix earlier
    word (e.g. "k…" of "kaffi") isn't mistaken for a later one (e.g. "kvld").
    Suffix comparison is used (not word counts) so it survives the kb log's
    40-char window truncation."""
    tail = last_word(r.window).lower()
    if not tail:
        return False
    typo_l = typo.lower()
    if not (typo_l.startswith(tail) or tail.startswith(typo_l)):
        return False
    wc = _committed_part(r.window)
    if prefix == "":
        return wc.strip() == ""
    return wc.strip() != "" and prefix.endswith(wc)


def _bar_offered(kb: list, typo: str, intended: str, before_t: float, prefix: str) -> bool:
    """Did any bar shown while typing `typo` contain `intended`?"""
    for r in kb:
        if r.t > before_t:
            continue
        if _pass_is_typing(r, typo, prefix):
            for b in r.bar:
                if b.get("text") == intended:
                    return True
    return False


def last_word(window: str) -> str:
    ws = words(window)
    return ws[-1] if ws else ""


def reconstruct_pairs(peak: str, end: str) -> list:
    """Word-level erase-then-retype reconstruction.

    Diff the peak's word list against the end's word list. Only `replace`
    blocks are corrections (an erased span → a retyped span); pure `insert`
    blocks are continued typing and pure `delete` blocks are stray removals,
    neither of which is a typo/intended pair.

    Within a replace block we align the erased words to the retyped words:
    a 1↔1 block pairs unconditionally (preserves the simple single-word case);
    otherwise each erased word greedily takes its best PLAUSIBLE retyped match
    (shared stem or cheap edit) and any leftover retyped words are treated as
    insertions. This is what turns the session-2 "foðu"→"af" mispairing (the
    user erased "foðu" and retyped the longer "af góðu") into "foðu"→"góðu"
    with "af" dropped as an insertion.

    Returns a list of (peak_word_index, typo, intended).
    """
    pw = words(peak)
    ew = words(end)
    pairs = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, pw, ew).get_opcodes():
        if tag != "replace":
            continue
        erased = [(k, pw[k]) for k in range(i1, i2)]
        retyped = list(ew[j1:j2])
        used = [False] * len(retyped)
        if len(erased) == 1 and len(retyped) == 1:
            (pk, e), r = erased[0], retyped[0]
            if e != r:
                pairs.append((pk, e, r))
            continue
        for pk, e in erased:
            best, best_score = -1, None
            for ri, r in enumerate(retyped):
                if used[ri] or r == e or not plausible_edit(e, r):
                    continue
                score = (
                    common_prefix_len(e.lower(), r.lower()),
                    -edit_distance(e.lower(), r.lower()),
                )
                if best_score is None or score > best_score:
                    best_score, best = score, ri
            if best >= 0:
                used[best] = True
                pairs.append((pk, e, retyped[best]))
    return pairs


# A shared stem must be at least this long (absolute) to read as the same
# lemma — this keeps short-word typos echoed in the bar (e.g. "mew" vs "með",
# shared "me") from masquerading as inflections.
_INFLECTION_MIN_STEM = 4


def _inflection_offer(typo: str, intended: str, offered_bar: list) -> Optional[str]:
    """If the bar offered a DICTIONARY word that is the same lemma-ish stem as
    `intended` but a different inflection — a long shared prefix (>= 60% of the
    longer length AND at least `_INFLECTION_MIN_STEM` chars) with both tails a
    short inflectional ending — return that offer. Such a MISS belongs in the
    inflection backlog, not the corrector.

    The `typo` (and its bar-echoed prefixes) is excluded: the bar surfaces the
    raw typed string, which is not a real inflection of the intended word."""
    il, tl = intended.lower(), typo.lower()
    for o in offered_bar:
        ol = o.lower()
        if not o or ol == il or ol == tl:
            continue
        cp = common_prefix_len(il, ol)
        if cp < _INFLECTION_MIN_STEM or cp == len(il) or cp == len(ol):
            continue
        if cp < 0.6 * max(len(il), len(ol)):
            continue
        # The differing tails must be short inflectional suffix clusters.
        if 1 <= (len(il) - cp) <= 5 and 1 <= (len(ol) - cp) <= 5:
            return o
    return None


def classify(app: list, kb: list) -> list:
    """Return the ordered list of Events for a session."""
    events: list = []

    # Only text-bearing states (start has empty text but is a valid anchor).
    states = [r for r in app if r.kind in ("start", "snapshot", "stop")]
    episodes = find_episodes(states)

    prev_t = states[0].t if states else 0.0
    for ep in episodes:
        peak_words = words(ep.peak)
        for pk, typo, intended in reconstruct_pairs(ep.peak, ep.end):
            # Committed text before this word: the peak up to the word's start.
            prefix = ep.peak[: word_start_offset(ep.peak, pk)]
            context = peak_words[max(0, pk - 4):pk]

            if _autocorrect_for(kb, typo, before_t=ep.end_t, after_t=prev_t):
                # Wrong correction is `typo`; restored original is `intended`.
                events.append(Event("AUTOCORRECT_UNDONE", ep.t, typo, intended, context))
                continue
            offered = _bar_offered(kb, typo, intended, before_t=ep.t, prefix=prefix)
            cls = "MISS_OFFERED" if offered else "MISS_ABSENT"
            bar_texts = _bar_texts_while_typing(kb, typo, ep.t, prefix)
            note = ""
            infl = _inflection_offer(typo, intended, bar_texts)
            if infl is not None:
                cls = "INFLECTION_MISS"
                note = infl
            events.append(Event(cls, ep.t, typo, intended, context, bar_texts, note))
        prev_t = ep.t

    # Suggestion taps (from the kb log directly).
    for idx, r in enumerate(kb):
        if r.applied.get("kind") == "tap":
            tapped = r.applied.get("text", "")
            typed = last_word(r.window)
            # This pass's window is post-insertion (already ends with the
            # tapped word). Recover what the user had actually typed from the
            # most recent earlier pass whose tail is a partial of `tapped`.
            if typed == tapped:
                for pr in reversed(kb[:idx]):
                    frag = last_word(pr.window)
                    if frag and frag != tapped and tapped.lower().startswith(frag.lower()):
                        typed = frag
                        break
            events.append(Event("TAP_USED", r.t, typed, tapped,
                                 context=words(r.window)[-5:-1]))

    events.sort(key=lambda e: e.t)
    return events


def _bar_texts_while_typing(kb: list, typo: str, before_t: float, prefix: str) -> list:
    seen = []
    for r in kb:
        if r.t > before_t:
            continue
        if _pass_is_typing(r, typo, prefix):
            for b in r.bar:
                txt = b.get("text", "")
                if txt and txt not in seen:
                    seen.append(txt)
    return seen


def committed_word_count(app: list) -> int:
    final = ""
    for r in app:
        if r.kind in ("snapshot", "stop") and r.text:
            final = r.text
    return len(words(final))


def tap_offset_stats(kb: list) -> dict:
    acc: dict = {}
    for r in kb:
        for tap in r.taps:
            c = tap.get("c", "")
            dx = tap.get("dx", 0.0)
            dy = tap.get("dy", 0.0)
            s = acc.setdefault(c, {"n": 0, "sx": 0.0, "sy": 0.0})
            s["n"] += 1
            s["sx"] += dx
            s["sy"] += dy
    out = {}
    for c, s in acc.items():
        n = s["n"]
        out[c] = {"count": n, "mean_dx": s["sx"] / n, "mean_dy": s["sy"] / n}
    return out


# --------------------------------------------------------------------------
# SILENT_MISS pass — scan the final committed text for uncorrected typos
# --------------------------------------------------------------------------

# Icelandic iOS layout rows + iOS row stagger, mirrored from
# Packages/TypeEngine/Sources/TypeEngine/SpatialModel.swift so the adjacency
# model matches the engine the corrector actually runs on.
_ROWS = ["qwertyuiopð", "asdfghjklæö", "zxcvbnmþ"]
_ROW_OFFSETS = [0.0, 0.5, 0.75]
_KEY_POS = {
    ch: (col + _ROW_OFFSETS[r], float(r))
    for r, row in enumerate(_ROWS)
    for col, ch in enumerate(row)
}
# Accent twins share a base key (long-press) and the engine's orthographic
# confusion pairs (SpatialModel.confusionPairs + accentBase); "cheap" swaps.
_TWIN_PAIRS = [
    ("a", "á"), ("e", "é"), ("i", "í"), ("o", "ó"), ("u", "ú"), ("y", "ý"),
    ("d", "ð"), ("o", "ö"), ("ð", "þ"), ("t", "þ"), ("a", "æ"),
]
_TWINS: dict = {}
for _a, _b in _TWIN_PAIRS:
    _TWINS.setdefault(_a, set()).add(_b)
    _TWINS.setdefault(_b, set()).add(_a)
_ALPHABET = set("abcdefghijklmnopqrstuvwxyzðþæöáéíóúý")

# A neighbour must be at least this common (unigram count) to be offered as a
# correction — this is what separates a real high-frequency target from corpus
# noise, and keeps keyboard-mash tokens UNRESOLVABLE. Lowered from 20000: a
# common inflected verb form like "las" (~7.7k) is a legitimate correction
# target — is.lex's fine-grained per-wordform counting means even everyday
# words can sit well under what a lemma-level count would suggest.
SILENT_NEIGHBOUR_MIN = 5000

# Below this calibrated is.lex z-score (TypeEngine's `calibratedUnigramScore`,
# same z the engine itself computes — see `attest_tokens`), an is.lex
# attestation is treated as possible corpus noise rather than a real word,
# UNLESS BÍN morphology validates it (rare-but-real words and noise both
# cluster right around this boundary; z alone cannot tell them apart, see
# `attest_tokens`'s docstring). Calibrated empirically against this repo's
# session corpus: catches "lss" (z=-1.03, not BÍN-known — the actual bug)
# while every rare-but-real word in the corpus at a similar or lower z
# ("gil" -1.03, "snefil" -1.22, "þiðna" -1.53, "hárblásara" -2.35, ...) is
# BÍN-known and stays exempt.
JUNK_Z_FLOOR = -1.0


def _adjacent_keys(ch: str) -> set:
    """Layout keys within ~one key pitch of `ch` (horizontal + near-diagonal)."""
    if ch not in _KEY_POS:
        return set()
    x, y = _KEY_POS[ch]
    out = set()
    for other, (ox, oy) in _KEY_POS.items():
        if other == ch:
            continue
        if ((x - ox) ** 2 + (y - oy) ** 2) ** 0.5 <= 1.25:
            out.add(other)
    return out


def _cheap_subs(ch: str) -> set:
    return _adjacent_keys(ch) | _TWINS.get(ch, set())


def _cheap_edits1(w: str) -> set:
    """One cheap edit: adjacency/accent substitution, deletion, adjacent
    transposition, or a single insertion."""
    out = set()
    for i in range(len(w)):
        for s in _cheap_subs(w[i]):
            out.add(w[:i] + s + w[i + 1:])
        out.add(w[:i] + w[i + 1:])
        if i + 1 < len(w):
            out.add(w[:i] + w[i + 1] + w[i] + w[i + 2:])
    for i in range(len(w) + 1):
        for c in _ALPHABET:
            out.add(w[:i] + c + w[i:])
    out.discard(w)
    return out


def load_lexicons(repo_root: str) -> dict:
    """Load the Icelandic unigram frequency map and the English 80k list.
    Returns {'is': {word: count}, 'en': {word: count}} (empty on failure)."""
    lex = {"is": {}, "en": {}}
    is_path = os.path.join(repo_root, "data", "is", "unigrams.json.gz")
    en_path = os.path.join(repo_root, "data", "en", "en-80k.txt")
    try:
        with gzip.open(is_path, "rt", encoding="utf-8") as fh:
            lex["is"] = json.load(fh)
    except Exception:
        pass
    try:
        with open(en_path, "r", encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        lex["en"][parts[0].lower()] = int(parts[1])
                    except ValueError:
                        continue
    except Exception:
        pass
    return lex


def _find_type_repl(repo_root: str) -> Optional[str]:
    for cfg in ("release", "debug"):
        p = os.path.join(repo_root, "Packages", "TypeEngine", ".build", cfg, "type-repl")
        if os.path.exists(p):
            return p
    return None


def _is_junk_tier(is_present: bool, is_z: float, bin_known: bool) -> bool:
    """True when an is.lex attestation is likely corpus noise rather than a
    real word (see `attest_tokens`'s docstring for why both signals are
    needed). Pulled out as a pure function so it's unit-testable without
    shelling out to `type-repl`."""
    return is_present and is_z < JUNK_Z_FLOOR and not bin_known


def attest_tokens(tokens: list, repo_root: str) -> tuple:
    """Query the engine's curated lexicons for each token via `type-repl :word`.

    Returns (attest, source) where attest maps token → {'is': bool, 'en': bool,
    'is_junk_tier': bool, 'is_present': bool, 'bin': bool} (present in that
    lexicon, plus whether the IS attestation is corpus noise rather than a
    real word — see below) and source is 'type-repl' or 'corpus' (fallback).
    The type-repl path is authoritative — it excludes corpus noise the engine
    curated out (e.g. "fra"/"fa" are corpus tokens but NOT is.lex words).

    `is_present` is the RAW is.lex membership (before junk-tier filtering) —
    the taxonomy's compound-oov detector needs "absent from is.lex entirely",
    which is a different question from "is a real word" (`is`/`bin` below).
    `bin` is raw BÍN morphological validity — the taxonomy's
    valid-word-overlap / proper-noun-oov detectors need this directly since
    BÍN catches real words is.lex's frequency table doesn't have a good count
    for (e.g. "syndur", BÍN-known but is.lex-absent).

    `is_junk_tier`: is.lex is a raw unigram frequency table, not a curated
    dictionary — it keeps web-noise tokens (OCR errors, leetspeak, stray
    keymashes that happened to occur in the crawl) right alongside real
    words, so `f != "-"` alone is NOT "this is a real word". Two independent
    engine signals narrow it down:
      - `z` (calibratedUnigramScore): a real word's frequency, however rare,
        sits far more often above JUNK_Z_FLOOR than noise's does — but the
        two distributions overlap heavily right at that boundary, so z alone
        both under- and over-flags (rare-but-real words like "gil" or
        "snefil" score the SAME z as noise like "lss").
      - BÍN morphological validity: BÍN is a curated Icelandic wordform
        database, so `binKnown` reliably clears every rare-but-real word
        that z alone can't distinguish from noise. It does not clear foreign
        proper nouns (BÍN has no surnames), but those fall back to
        UNRESOLVABLE (no cheap-edit high-frequency neighbour), not a
        misleading correction.
    A token is junk-tier only when BOTH signals agree it might not be real:
    below the z floor AND not BÍN-known."""
    binary = _find_type_repl(repo_root)
    uniq = list(dict.fromkeys(tokens))
    if binary:
        try:
            script = "".join(f":word {t}\n" for t in uniq) + ":quit\n"
            out = subprocess.run(
                [binary], input=script, capture_output=True, text=True, timeout=120
            ).stdout
            is_f = re.findall(r"is\.lex\s+f=(\S+)\s+z=(\S+)", out)
            en_f = re.findall(r"en\.lex\s+f=(\S+)\s+z=(\S+)", out)
            bin_known = re.findall(r"BÍN\s+(known|-)", out)
            if len(is_f) == len(uniq) and len(en_f) == len(uniq) and len(bin_known) == len(uniq):
                attest = {}
                for i, t in enumerate(uniq):
                    is_present = is_f[i][0] != "-"
                    is_z = float(is_f[i][1])
                    known = bin_known[i] == "known"
                    junk_tier = _is_junk_tier(is_present, is_z, known)
                    attest[t] = {
                        "is": is_present and not junk_tier,
                        "en": en_f[i][0] != "-",
                        "is_junk_tier": junk_tier,
                        "is_present": is_present,
                        "bin": known,
                    }
                return attest, "type-repl"
        except Exception:
            pass
    # Fallback: plain membership in the frequency corpora (less precise — the
    # corpora keep low-frequency noise the curated lexicon dropped, and there
    # is no z/BÍN signal here to separate real rare words from that noise;
    # BÍN validity is unknowable without the binary, so `bin` stays False).
    lex = load_lexicons(repo_root)
    attest = {
        t: {"is": t.lower() in lex["is"], "en": t.lower() in lex["en"],
            "is_junk_tier": False, "is_present": t.lower() in lex["is"], "bin": False}
        for t in uniq
    }
    return attest, "corpus"


@dataclass
class SilentMiss:
    token: str
    cls: str            # SILENT_MISS | UNRESOLVABLE
    candidates: list    # [(word, freq, penalty)] ranked; penalty 0/1/2
    context: list = field(default_factory=list)


def _silent_candidates(token: str, common: dict) -> list:
    """Ranked correction candidates for an unattested `token`, drawn from the
    `common` {word: freq} map (words above SILENT_NEIGHBOUR_MIN). Penalty:
    0 = one cheap edit, 1 = two cheap edits, 2 = within plain edit-distance 2
    (a non-adjacent substitution — weaker, e.g. the v→ð in sivan→síðan)."""
    low = token.lower()
    e1 = _cheap_edits1(low)
    e2 = set()
    for x in e1:
        e2 |= _cheap_edits1(x)
    penalty: dict = {}
    for n in e1:
        if n in common:
            penalty[n] = min(penalty.get(n, 9), 0)
    for n in e2:
        if n in common:
            penalty[n] = min(penalty.get(n, 9), 1)
    for w in common:
        if abs(len(w) - len(low)) <= 2 and w != low and edit_distance(low, w) <= 2:
            penalty[w] = min(penalty.get(w, 9), 2)
    ranked = sorted(
        ((w, common[w], p) for w, p in penalty.items() if len(w) >= 2),
        key=lambda t: (t[2], -t[1]),
    )
    return ranked[:5]


def _final_text(app: list) -> str:
    final = ""
    for r in app:
        if r.kind in ("snapshot", "stop") and r.text:
            final = r.text
    return final


def _clean_token(tok: str) -> str:
    return tok.strip(".,!?;:…“”\"'()[]")


def silent_miss_scan(app: list, repo_root: str) -> tuple:
    """Scan the final committed text for uncorrected typos. Returns
    (findings, attest_source)."""
    final = _final_text(app)
    raw = words(final)
    tokens = []
    for tok in raw:
        core = _clean_token(tok)
        if (
            len(core) < 2
            or tok.startswith("#")
            or tok.startswith("@")
            or "http" in tok.lower()
            or any(c.isdigit() for c in core)
            or not any(c.isalpha() for c in core)
        ):
            continue
        tokens.append(core)

    if not tokens:
        return [], "none"

    attest, source = attest_tokens(tokens, repo_root)
    lex = load_lexicons(repo_root)
    is_freq = lex["is"]
    common = {w: f for w, f in is_freq.items() if f >= SILENT_NEIGHBOUR_MIN}
    # Session language: Icelandic if any Icelandic-attested / accented token.
    session_is = any(
        attest.get(t, {}).get("is") or guess_lang(t) == "is" for t in tokens
    )

    findings = []
    positions = {}
    for i, t in enumerate(tokens):
        positions.setdefault(t, i)
    for tok in dict.fromkeys(tokens):
        a = attest.get(tok, {"is": False, "en": False})
        # Attested (a real word) → not a typo. In an Icelandic session an
        # English-only attestation does NOT exempt the token (English words in
        # Icelandic text are rare; recall over precision here).
        attested = a["is"] or (a["en"] and not session_is)
        if attested:
            continue
        cands = _silent_candidates(tok, common)
        idx = positions.get(tok, 0)
        ctx = tokens[max(0, idx - 3):idx]
        cls = "SILENT_MISS" if cands else "UNRESOLVABLE"
        findings.append(SilentMiss(tok, cls, cands, ctx))
    return findings, source


# --------------------------------------------------------------------------
# Taxonomy tagging (v3) — attach a [class · status] to every finding
# --------------------------------------------------------------------------
#
# See taxonomy.py for the class list, precedence, and the pure classifier.
# This section gathers the REAL context each detector needs (BÍN/is.lex
# attestation via type-repl, bar contents, confirmed-intents overrides) and
# feeds it into `taxonomy.classify_finding`.

def _bar_seen_for_silent(kb: list, token: str) -> list:
    """Approximate bar cross-reference for a SILENT_MISS/UNRESOLVABLE token:
    every bar text seen in a kb pass whose window tail is a prefix/superstring
    match of `token` (position-agnostic, unlike `_bar_texts_while_typing` —
    a SilentMiss token is deduped session-wide so this stays cheap and rarely
    double-counts). This is what lets e.g. "gret" pick up the "gert" the live
    bar actually offered (at a losing rank) during the final-text scan, which
    only sees the committed text, not the bar history."""
    seen = []
    tl = token.lower()
    for r in kb:
        tail = last_word(r.window).lower()
        if not tail:
            continue
        if tl.startswith(tail) or tail.startswith(tl):
            for b in r.bar:
                txt = b.get("text", "")
                if txt and txt not in seen:
                    seen.append(txt)
    return seen


def detect_stale_applies(kb: list) -> list:
    """Wave-28 regression watch: an applied autocorrect whose text equals the
    PREVIOUSLY committed word (a no-op re-apply) while the bar concurrently
    held a different `ac` candidate, or an explicit `stale-skip` applied kind.
    Returns a list of {'applied', 'prev', 't'} — empty on healthy sessions."""
    findings = []
    prev_committed = None
    for r in kb:
        applied = r.applied or {}
        kind = applied.get("kind", "none")
        if kind == "stale-skip":
            findings.append({"applied": applied.get("text", ""), "prev": prev_committed, "t": r.t})
        elif kind == "autocorrect":
            text = applied.get("text", "")
            other_ac = [b.get("text") for b in r.bar
                       if b.get("ac") and b.get("text") != text]
            if prev_committed is not None and text == prev_committed and other_ac:
                findings.append({"applied": text, "prev": prev_committed, "t": r.t})
        # A kb pass right after a word commits has its window end in a
        # trailing space (verified against real kb.jsonl `applied.kind ==
        # "autocorrect"` passes) — that's when the tail word is "committed",
        # as opposed to a mid-type pass where it's still a partial word.
        if r.window.endswith(" "):
            cw = last_word(r.window)
            if cw:
                prev_committed = cw
    return findings


def silent_intended(m: "SilentMiss", confirmed_intents: dict) -> str:
    """The best-guess "intended" word for a SilentMiss finding: a
    confirmed-intents.jsonl correction if one exists (it always wins — the
    user themselves confirmed it), else the top-ranked `_silent_candidates`
    guess, else "" (truly no guess, e.g. an UNRESOLVABLE mash with no
    confirmed intent either). Shared by `tag_findings` (classification) and
    every renderer that displays a SilentMiss's guessed correction, so the
    two never drift apart."""
    override = (confirmed_intents or {}).get(m.token.lower())
    if override and override.get("intended"):
        return override["intended"]
    return m.candidates[0][0] if m.candidates else ""


def taxonomy_tokens_for_session(events: list, silent: list,
                                confirmed_intents: dict = None) -> list:
    """Every raw token whose attestation the taxonomy tagger needs for one
    session: every event's typo/intended, every silent finding's token plus
    its best-guess intended (confirmed-intents override or top candidate —
    see `silent_intended`, so an override target like "eitthvað" gets
    attested even when it never appears in `_silent_candidates`' own list)."""
    toks = set()
    for e in events:
        if e.typo:
            toks.add(e.typo)
        if e.intended:
            toks.add(e.intended)
    for m in silent:
        toks.add(m.token)
        intended = silent_intended(m, confirmed_intents)
        if intended:
            toks.add(intended)
    return [t for t in toks if t]


def tag_findings(events: list, kb: list, silent: list, repo_root: str,
                 confirmed_intents: dict = None) -> tuple:
    """Attach a (class_id, status) taxonomy tag to every Event and SilentMiss
    finding. Returns (event_tags, silent_tags, attest_source) where
    event_tags/silent_tags map `id(finding)` -> (class_id, status)."""
    if confirmed_intents is None:
        confirmed_intents = taxonomy.load_confirmed_intents()

    primary = taxonomy_tokens_for_session(events, silent, confirmed_intents)
    # Speculatively probe compound substrings for every len>=8 word up front
    # (one batched type-repl call total, filtered by is-presence afterward)
    # rather than round-tripping type-repl twice per session.
    probe_targets = set()
    for w in primary:
        if len(w) >= 8:
            probe_targets |= set(taxonomy.compound_probe_substrings(w))
    all_tokens = list(dict.fromkeys(primary + list(probe_targets)))
    if all_tokens:
        attest, source = attest_tokens(all_tokens, repo_root)
    else:
        attest, source = {}, "none"

    def valid(word: str) -> bool:
        if not word:
            return False
        a = attest.get(word, {})
        return bool(a.get("is")) or bool(a.get("bin"))

    def is_present(word: str) -> bool:
        return bool(attest.get(word, {}).get("is_present")) if word else False

    def compound_hit(word: str) -> str:
        if not word or len(word) < 8 or is_present(word):
            return ""
        for seg in taxonomy.compound_probe_substrings(word):
            a = attest.get(seg, {})
            if a.get("is") or a.get("bin"):
                return seg
        return ""

    def ctx_for(typo: str, intended: str, event_cls: str, bar_seen) -> "taxonomy.FindingContext":
        typo_l = typo.lower() if typo else typo
        ed = edit_distance(typo.lower(), intended.lower()) if typo and intended else 0
        return taxonomy.FindingContext(
            typo=typo, intended=intended, event_cls=event_cls,
            bar_seen=tuple(bar_seen or ()),
            typo_valid=valid(typo), intended_valid=valid(intended),
            intended_is_lex_present=is_present(intended),
            compound_hit=compound_hit(intended),
            edit_distance=ed,
            confirmed=confirmed_intents.get(typo_l) if typo_l else None,
        )

    event_tags = {}
    for e in events:
        ctx = ctx_for(e.typo, e.intended, e.cls, e.offered_bar)
        event_tags[id(e)] = taxonomy.classify_finding(ctx)

    silent_tags = {}
    for m in silent:
        intended = silent_intended(m, confirmed_intents)
        bar_seen = _bar_seen_for_silent(kb, m.token)
        ctx = ctx_for(m.token, intended, m.cls, bar_seen)
        silent_tags[id(m)] = taxonomy.classify_finding(ctx)

    return event_tags, silent_tags, source


# --------------------------------------------------------------------------
# Greynir grammar-parse enrichment (v4, OPTIONAL — see greynir_enrich.py)
# --------------------------------------------------------------------------
#
# Every call below degrades to an empty/no-op result with a one-line note if
# the dedicated venv (tools/session-analyzer/.venv) or `reynir` is
# unavailable — this section NEVER raises and NEVER changes engine behavior;
# it only annotates findings the base pipeline already produced. All parses
# a session needs (residual-error pass, grammar-vouched-overlap upgrade,
# case-government audit, SILENT_MISS candidate disambiguation) are gathered
# up front and resolved in exactly ONE `greynir_enrich.batch_parse` call
# (itself cache-backed, so repeat ingests of an unchanged corpus dispatch no
# subprocess at all).

_WORD_CHARS = "A-Za-zÁÉÍÓÚÝÐÞÆÖáéíóúýðþæö"


def _substitute_first_word(text: str, old: str, new: str) -> Optional[str]:
    """Replace the first whole-word (case-insensitive) occurrence of `old` in
    `text` with `new`. None if `old` isn't literally present (e.g. the
    finding's token was already normalized away) — caller falls back to a
    synthetic context sentence."""
    if not old:
        return None
    pattern = re.compile(
        f"(?<![{_WORD_CHARS}]){re.escape(old)}(?![{_WORD_CHARS}])",
        re.IGNORECASE,
    )
    new_text, n = pattern.subn(lambda m: new, text, count=1)
    return new_text if n else None


def _finding_typo_intended_context(finding, confirmed_intents: dict) -> tuple:
    """(typo, intended, context_words) uniformly for an Event or a SilentMiss."""
    if isinstance(finding, Event):
        return finding.typo, finding.intended, list(finding.context)
    intended = silent_intended(finding, confirmed_intents)
    return finding.token, intended, list(finding.context)


def _vouch_eligible(typo: str, intended: str, event_cls: str = "") -> bool:
    """Is this valid-word-overlap finding even a fair grammar-vouch candidate?
    Excludes TAP_USED (its "typo" is the on-screen PREFIX at tap time, not a
    complete alternate word — substituting a bare prefix into the sentence
    and finding it "doesn't parse" is an artifact of it not being a whole
    word, not genuine grammar evidence) and any other case where typo is a
    strict prefix of intended (same reason, for events recovered the same
    way)."""
    if event_cls == "TAP_USED":
        return False
    tl, il = typo.lower(), intended.lower()
    if il.startswith(tl) and len(tl) < len(il):
        return False
    return True


def _vouch_sentences(typo: str, intended: str, context: list, final_text: str) -> tuple:
    """(typo_sentence, intended_sentence) to parse-compare for a
    valid-word-overlap finding. Prefers substituting directly into the
    session's FINAL text (the real grammatical sentence the word sat in);
    falls back to a synthetic `context + word.` clause when the token isn't
    literally findable there (e.g. an Event whose typo was corrected away
    mid-episode and never reached the final text)."""
    if final_text and typo in final_text:
        typo_sentence = final_text
        intended_sentence = _substitute_first_word(final_text, typo, intended)
        if intended_sentence is not None:
            return typo_sentence, intended_sentence
    ctx = " ".join(context)
    return (f"{ctx} {typo}.".strip(), f"{ctx} {intended}.".strip())


def greynir_enrich_session(app: list, events: list, silent: list,
                           event_tags: dict, silent_tags: dict,
                           confirmed_intents: dict = None,
                           cache_path: str = None) -> dict:
    """Optional Greynir enrichment for one session. Returns:

        {"available": bool, "note": str,
         "grammar_review": [{"sentence", "score", "reason"}],
         "vouched_ids": {id(finding), ...},   # upgraded in event_tags/silent_tags IN PLACE
         "case_disagreements": [str, ...],
         "candidate_parses": {id(silent_miss): [(word, parses_bool), ...]}}

    `event_tags`/`silent_tags` are mutated in place: any finding tagged
    valid-word-overlap that Greynir genuinely vouches for gets upgraded to
    (grammar-vouched-overlap, watch) — so callers that already hold those
    dicts (analyze.py's report, aggregate.py's top-gaps rollup) see the
    upgrade for free without re-deriving anything."""
    confirmed_intents = confirmed_intents or {}
    result = {
        "available": False, "note": "", "grammar_review": [],
        "vouched_ids": set(), "case_disagreements": [], "candidate_parses": {},
    }
    if not greynir_enrich.available():
        result["note"] = greynir_enrich.UNAVAILABLE_NOTE
        return result

    final_text = _final_text(app)

    # ---- Gather every sentence/word this session needs, up front. --------
    sentences_needed = []
    if final_text.strip():
        sentences_needed.append(final_text)

    vouch_jobs = []   # (finding_kind, finding, typo_sentence, intended_sentence)
    for e in events:
        if event_tags.get(id(e), (None,))[0] != "valid-word-overlap":
            continue
        typo, intended, ctx = _finding_typo_intended_context(e, confirmed_intents)
        if not typo or not intended or not _vouch_eligible(typo, intended, e.cls):
            continue
        ts, is_ = _vouch_sentences(typo, intended, ctx, final_text)
        sentences_needed += [ts, is_]
        vouch_jobs.append(("event", e, ts, is_))
    for m in silent:
        if silent_tags.get(id(m), (None,))[0] != "valid-word-overlap":
            continue
        typo, intended, ctx = _finding_typo_intended_context(m, confirmed_intents)
        if not typo or not intended or not _vouch_eligible(typo, intended, m.cls):
            continue
        ts, is_ = _vouch_sentences(typo, intended, ctx, final_text)
        sentences_needed += [ts, is_]
        vouch_jobs.append(("silent", m, ts, is_))

    # SILENT_MISS candidate disambiguation (top-3 candidates, contested or not
    # — annotating an uncontested one too is harmless and still informative).
    cand_jobs = []   # (m, [(word, sentence), ...])
    for m in silent:
        if m.cls != "SILENT_MISS" or len(m.candidates) < 1:
            continue
        pairs = []
        for word, _freq, _pen in m.candidates[:3]:
            sub = None
            if final_text and m.token in final_text:
                sub = _substitute_first_word(final_text, m.token, word)
            if sub is None:
                ctx = " ".join(m.context)
                sub = f"{ctx} {word}.".strip()
            sentences_needed.append(sub)
            pairs.append((word, sub))
        cand_jobs.append((m, pairs))

    # Case-government audit: INFLECTION_MISS typo/intended BÍN case compare,
    # plus a BÍN case lookup for every final-text token (cheap; lets the
    # preposition-object cross-check below run entirely off THIS ONE batch's
    # results, no follow-up call needed).
    words_needed = set()
    for e in events:
        if e.cls == "INFLECTION_MISS":
            words_needed.add(e.typo)
            words_needed.add(e.intended)
    words_needed.update(words(final_text.replace(".", " ").replace(",", " ")))

    sent_results, word_results, note = greynir_enrich.batch_parse(
        sentences=sentences_needed, words=words_needed, cache_path=cache_path)
    result["available"] = True
    result["note"] = note

    # ---- Grammar review (residual-error pass over the final text). -------
    if final_text.strip():
        for sent in sent_results.get(final_text, []):
            summary = greynir_enrich.sentence_best([sent])
            if greynir_enrich.is_low_confidence(summary):
                reason = greynir_enrich.grammar_review_reason(
                    sent.get("tokens", []), confirmed_intents)
                result["grammar_review"].append({
                    "sentence": sent.get("text", ""),
                    "score": summary.get("score"),
                    "reason": reason,
                })

    # ---- Grammar-vouched-overlap upgrade (mutates event_tags/silent_tags). -
    for kind, finding, ts, is_ in vouch_jobs:
        typo_summary = greynir_enrich.sentence_best(sent_results.get(ts, []))
        intended_summary = greynir_enrich.sentence_best(sent_results.get(is_, []))
        if greynir_enrich.vouch_decision(typo_summary, intended_summary):
            status = taxonomy.status_of(taxonomy.GRAMMAR_VOUCHED_ID)
            tags = event_tags if kind == "event" else silent_tags
            tags[id(finding)] = (taxonomy.GRAMMAR_VOUCHED_ID, status)
            result["vouched_ids"].add(id(finding))

    # ---- Case-government audit. ------------------------------------------
    for e in events:
        if e.cls != "INFLECTION_MISS":
            continue
        tcases = word_results.get(e.typo, [])
        icases = word_results.get(e.intended, [])
        if tcases and icases and set(tcases) != set(icases):
            result["case_disagreements"].append(
                f"`{e.typo}` (BÍN case {'/'.join(tcases)}) vs. intended "
                f"`{e.intended}` (BÍN case {'/'.join(icases)})"
            )
    if final_text.strip():
        for sent in sent_results.get(final_text, []):
            result["case_disagreements"].extend(
                greynir_enrich.prep_case_disagreements([sent], word_results))

    # ---- Candidate disambiguation. ----------------------------------------
    for m, pairs in cand_jobs:
        annotated = []
        for word, sub in pairs:
            summary = greynir_enrich.sentence_best(sent_results.get(sub, []))
            parses = bool(summary.get("parsed")) if not summary.get("unavailable") else False
            annotated.append((word, parses))
        result["candidate_parses"][id(m)] = annotated

    return result


# --------------------------------------------------------------------------
# Lane posterior timeline — per-word IS-lane posterior via type-repl replay
# --------------------------------------------------------------------------

_STATE_RE = re.compile(r"P\(IS\)=([0-9]*\.?[0-9]+)\s+commits=(\d+)")

# Lane whiplash: a single-word swing bigger than this is the Love-Island
# poisoning signature — a session-immediate lane flip that shouldn't happen
# on ordinary running text.
WHIPLASH_THRESHOLD = 0.35


def lane_timeline(app: list, repo_root: str) -> tuple:
    """Per-word IS-lane posterior across the session's FINAL committed text,
    extracted by replaying the words through `type-repl`'s interactive REPL:
    one word per line -> one `state P(IS)=` report per commit (see Repl.swift
    `report()`). Cheap (~tens of ms/word, dominated by process/engine
    startup — a ~50-word session finishes in well under a second).

    Returns (entries, source) where entries is a list of
    {'word', 'p', 'whiplash'} (p is None if desynced/unavailable for that
    word) and source is 'type-repl' or 'unavailable'."""
    final = _final_text(app)
    toks = words(final)
    if not toks:
        return [], "none"
    binary = _find_type_repl(repo_root)
    if not binary:
        return [], "unavailable"

    lines = []
    for w in toks:
        # A word literally starting with ':' would be misread as a REPL
        # command; the leading space keeps it a no-op typed character instead.
        line = (" " + w) if w.startswith(":") else w
        lines.append(line + " ")
    lines.append(":quit")
    script = "\n".join(lines) + "\n"
    try:
        out = subprocess.run([binary], input=script, capture_output=True,
                             text=True, timeout=120).stdout
    except Exception:
        return [], "unavailable"

    posts = [float(m.group(1)) for m in _STATE_RE.finditer(out)]
    if len(posts) < len(toks):
        posts = posts + [None] * (len(toks) - len(posts))

    entries = []
    prev = 0.5
    for w, p in zip(toks, posts):
        whiplash = p is not None and abs(p - prev) > WHIPLASH_THRESHOLD
        entries.append({"word": w, "p": p, "whiplash": whiplash})
        if p is not None:
            prev = p
    return entries, "type-repl"


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def render_report(sid: str, app: list, kb: list, events: list,
                  silent: list = None, silent_source: str = "",
                  event_tags: dict = None, silent_tags: dict = None,
                  stale_applies: list = None,
                  lane: list = None, lane_source: str = "",
                  confirmed_intents: dict = None,
                  greynir: dict = None) -> str:
    event_tags = event_tags or {}
    silent_tags = silent_tags or {}
    stale_applies = stale_applies or []
    confirmed_intents = confirmed_intents or {}
    greynir = greynir or {}
    candidate_parses = greynir.get("candidate_parses", {})

    def tag_of(finding):
        return (event_tags.get(id(finding)) or silent_tags.get(id(finding))
               or (taxonomy.NOVEL_ID, taxonomy.status_of(taxonomy.NOVEL_ID)))

    counts: dict = {}
    for e in events:
        counts[e.cls] = counts.get(e.cls, 0) + 1
    committed = committed_word_count(app)
    flagged = sum(1 for e in events if e.cls != "CLEAN")
    clean = max(committed - flagged, 0)

    novel_events = [e for e in events if event_tags.get(id(e), (None,))[0] == taxonomy.NOVEL_ID]
    novel_silent = [m for m in (silent or [])
                    if silent_tags.get(id(m), (None,))[0] == taxonomy.NOVEL_ID]
    regressions = [
        (kind, f, cls, status)
        for finding_list, tags, kind in ((events, event_tags, "event"),
                                         (silent or [], silent_tags, "silent"))
        for f in finding_list
        for cls, status in [tags.get(id(f), (None, ""))]
        if taxonomy.is_regression_status(status)
    ]

    lines = []
    lines.append(f"# Session report — {sid}")
    lines.append("")
    lines.append(f"- app records: {len(app)}  ·  kb passes: {len(kb)}")
    lines.append(f"- committed words (final text): {committed}")
    lines.append("")

    # ---- NOVEL + regressions FIRST, so a maintainer's ~10 lines of
    # attention go where the taxonomy can't yet help. ------------------
    if stale_applies or regressions:
        lines.append("## ⚠ REGRESSIONS (fixed classes recurring)")
        lines.append("")
        for sa in stale_applies:
            lines.append(f"- `stale-apply` re-applied `{sa['applied']}` "
                         f"(prev committed: `{sa['prev']}`) at t={sa['t']:.3f} "
                         f"{taxonomy.format_tag('stale-apply')}")
        for kind, f, cls, status in regressions:
            typo, intended = (f.typo, f.intended) if kind == "event" else (
                f.token, silent_intended(f, confirmed_intents) or "?")
            lines.append(f"- `{typo}` → `{intended}` {taxonomy.format_tag(cls, status)}")
        lines.append("")

    if novel_events or novel_silent:
        lines.append("## NOVEL findings (unclassified — taxonomy.py needs a look)")
        lines.append("")
        for e in novel_events:
            ctx = " ".join(e.context)
            lines.append(f"- {e.cls}: `{e.typo}` → `{e.intended}`"
                         + (f"  (…{ctx})" if ctx else ""))
        for m in novel_silent:
            intended = silent_intended(m, confirmed_intents) or "?"
            lines.append(f"- {m.cls}: `{m.token}` → `{intended}`")
        lines.append("")

    lines.append("## Event counts")
    lines.append("")
    for cls in ["AUTOCORRECT_UNDONE", "MISS_OFFERED", "MISS_ABSENT",
                "INFLECTION_MISS", "TAP_USED"]:
        lines.append(f"- {cls}: {counts.get(cls, 0)}")
    lines.append(f"- CLEAN (approx): {clean}")
    lines.append("")

    lines.append("## Events")
    lines.append("")
    if not events:
        lines.append("_none_")
    for e in events:
        ctx = " ".join(e.context)
        cls, status = tag_of(e)
        lines.append(f"### {e.cls}  {taxonomy.format_tag(cls, status)}")
        lines.append(f"- typed: `{e.typo}`  →  intended: `{e.intended}`")
        if ctx:
            lines.append(f"- context: …{ctx}")
        if e.cls == "INFLECTION_MISS" and e.note:
            lines.append(f"- inflected bar offer (wrong case): `{e.note}` "
                         "→ inflection backlog, not the corrector")
        if e.offered_bar:
            lines.append(f"- bar offered: {', '.join('`'+b+'`' for b in e.offered_bar)}")
        lines.append("")

    lines.append("## Silent misses (final-text scan)")
    lines.append("")
    if silent is None:
        lines.append("_not run_")
    elif not silent:
        lines.append("_none — every committed token is lexicon-attested_")
    else:
        lines.append(f"Attestation source: `{silent_source}`. Candidates ranked "
                     "by edit penalty (0 = one cheap edit, 1 = two, 2 = "
                     "non-adjacent) then frequency.")
        lines.append("")
        for m in silent:
            ctx = " ".join(m.context)
            cls, status = tag_of(m)
            lines.append(f"### {m.cls} — `{m.token}`  {taxonomy.format_tag(cls, status)}")
            if ctx:
                lines.append(f"- context: …{ctx} **{m.token}**")
            if m.candidates:
                guesses = ", ".join(
                    f"`{w}` (f={f}, p{p})" for w, f, p in m.candidates
                )
                lines.append(f"- candidates: {guesses}")
                parses = candidate_parses.get(id(m))
                if parses:
                    ann = ", ".join(
                        f"`{w}` {'parses' if ok else 'fails'}" for w, ok in parses
                    )
                    lines.append(f"- greynir: {ann}")
            else:
                lines.append("- candidates: _none within 2 cheap edits — "
                             "likely keyboard mash or an out-of-lexicon compound_")
            lines.append("")

    lines.append("## Grammar review (Greynir residual-error pass)")
    lines.append("")
    if not greynir.get("available"):
        lines.append(f"_{greynir.get('note') or greynir_enrich.UNAVAILABLE_NOTE}_")
    elif not greynir.get("grammar_review"):
        lines.append("_none — every final-text sentence parsed cleanly_")
    else:
        for gr in greynir["grammar_review"]:
            lines.append(f"- [{gr['reason']}] (score {gr['score']}) "
                         f"`{gr['sentence']}`")
    if greynir.get("note") and greynir.get("available"):
        lines.append("")
        lines.append(f"_{greynir['note']}_")
    lines.append("")

    lines.append("## Case government audit")
    lines.append("")
    if not greynir.get("available"):
        lines.append(f"_{greynir.get('note') or greynir_enrich.UNAVAILABLE_NOTE}_")
    elif not greynir.get("case_disagreements"):
        lines.append("_none found_")
    else:
        for line in greynir["case_disagreements"]:
            lines.append(f"- {line}")
    lines.append("")

    lines.append("## Lane posterior timeline (per word, IS-lane P)")
    lines.append("")
    if lane is None or lane_source in ("", "none"):
        lines.append("_not run_")
    elif lane_source == "unavailable":
        lines.append("_unavailable — type-repl binary not found "
                     f"(source=`{lane_source}`)_")
    elif not lane:
        lines.append("_no committed words_")
    else:
        whiplash_n = sum(1 for e in lane if e["whiplash"])
        lines.append(f"Source: `{lane_source}`. Whiplash (>{'%.2f' % WHIPLASH_THRESHOLD} "
                     f"swing in one step): **{whiplash_n}**.")
        lines.append("")
        chunk = []
        for i, e in enumerate(lane, 1):
            p = f"{e['p']:.2f}" if e["p"] is not None else "?"
            flag = " ⚠" if e["whiplash"] else ""
            chunk.append(f"{e['word']}→{p}{flag}")
            if i % 10 == 0:
                lines.append(" · ".join(chunk))
                chunk = []
        if chunk:
            lines.append(" · ".join(chunk))
    lines.append("")

    lines.append("## Per-key tap offsets")
    lines.append("")
    stats = tap_offset_stats(kb)
    if not stats:
        lines.append("_no tap samples_")
    else:
        lines.append("| key | count | mean dx | mean dy |")
        lines.append("|-----|-------|---------|---------|")
        for c in sorted(stats):
            s = stats[c]
            lines.append(f"| `{c}` | {s['count']} | {s['mean_dx']:+.3f} | {s['mean_dy']:+.3f} |")
    lines.append("")
    return "\n".join(lines)


def candidates_jsonl(events: list) -> str:
    out = []
    for e in events:
        if e.cls in ("AUTOCORRECT_UNDONE", "MISS_OFFERED", "MISS_ABSENT",
                     "INFLECTION_MISS"):
            out.append(json.dumps(e.to_candidate(), ensure_ascii=False))
    return "\n".join(out) + ("\n" if out else "")


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------

def discover_sessions(directory: str) -> list:
    ids = set()
    for name in os.listdir(directory):
        if name.endswith("-app.jsonl"):
            ids.add(name[: -len("-app.jsonl")])
    return sorted(ids)


def _repo_root() -> str:
    # tools/session-analyzer/analyze.py → repo root is two levels up.
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def analyze_one(directory: str, sid: str, repo_root: Optional[str] = None) -> dict:
    """Analyze a single session id in `directory`, writing `<id>-report.md` and
    `<id>-candidates.jsonl`. Returns a small summary dict (also used by
    ingest.py to log per-session results). Importable — no process exit."""
    repo_root = repo_root or _repo_root()
    app_path = os.path.join(directory, f"{sid}-app.jsonl")
    kb_path = os.path.join(directory, f"{sid}-kb.jsonl")
    app, kb = load_session(app_path, kb_path)
    events = classify(app, kb)
    silent, silent_source = silent_miss_scan(app, repo_root)
    confirmed_intents = taxonomy.load_confirmed_intents()
    event_tags, silent_tags, tag_source = tag_findings(
        events, kb, silent, repo_root, confirmed_intents)
    stale_applies = detect_stale_applies(kb)
    lane, lane_source = lane_timeline(app, repo_root)
    greynir = greynir_enrich_session(app, events, silent, event_tags,
                                     silent_tags, confirmed_intents)
    report = render_report(sid, app, kb, events, silent, silent_source,
                           event_tags, silent_tags, stale_applies,
                           lane, lane_source, confirmed_intents, greynir)
    with open(os.path.join(directory, f"{sid}-report.md"), "w", encoding="utf-8") as fh:
        fh.write(report)
    with open(os.path.join(directory, f"{sid}-candidates.jsonl"), "w", encoding="utf-8") as fh:
        fh.write(candidates_jsonl(events))
    sm = sum(1 for m in silent if m.cls == "SILENT_MISS")
    ur = sum(1 for m in silent if m.cls == "UNRESOLVABLE")
    novel_n = (sum(1 for e in events if event_tags.get(id(e), (None,))[0] == taxonomy.NOVEL_ID)
              + sum(1 for m in silent if silent_tags.get(id(m), (None,))[0] == taxonomy.NOVEL_ID))
    whiplash_n = sum(1 for e in lane if e["whiplash"])
    return {"sid": sid, "events": len(events), "silent_miss": sm,
            "unresolvable": ur, "silent_source": silent_source,
            "novel": novel_n, "whiplash": whiplash_n,
            "stale_applies": len(stale_applies),
            "greynir_available": greynir.get("available", False),
            "grammar_review": len(greynir.get("grammar_review", [])),
            "vouched": len(greynir.get("vouched_ids", ()))}


def analyze_dir(directory: str) -> int:
    ids = discover_sessions(directory)
    if not ids:
        print(f"No sessions (<id>-app.jsonl) found in {directory}", file=sys.stderr)
        return 1
    repo_root = _repo_root()
    for sid in ids:
        s = analyze_one(directory, sid, repo_root)
        greynir_note = (f"{s['grammar_review']} grammar-review, {s['vouched']} vouched"
                       if s["greynir_available"] else "greynir unavailable")
        print(f"{s['sid']}: {s['events']} events, {s['silent_miss']} silent-miss / "
              f"{s['unresolvable']} unresolvable ({s['silent_source']}), "
              f"{s['novel']} NOVEL, {s['whiplash']} whiplash, {greynir_note} → "
              f"{sid}-report.md, {sid}-candidates.jsonl")
    return 0


def main(argv: list) -> int:
    directory = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(__file__), "sessions")
    return analyze_dir(directory)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
