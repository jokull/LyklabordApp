#!/usr/bin/env python3
"""
taxonomy.py — known-failure-class taxonomy for session-analyzer findings.

Every finding analyze.py/aggregate.py surface (a corrector `Event` —
AUTOCORRECT_UNDONE / MISS_OFFERED / MISS_ABSENT / INFLECTION_MISS — or a
final-text-scan `SilentMiss` — SILENT_MISS / UNRESOLVABLE) gets triaged into
exactly one class below, in `PRECEDENCE` order (first match wins), so a
maintainer reading a report sees a `[class · status]` tag on every line
instead of re-deriving "have I seen this before?" from scratch each time.
Findings that match nothing render as `NOVEL`, in its own section at the TOP
of the report — a signal that the taxonomy itself needs a new entry, not that
the finding is unimportant.

This module is dependency-light and side-effect-free: `classify_finding` is a
pure function over a `FindingContext` of plain values, so it (and every
detection primitive below it) is unit-testable without shelling out to
`type-repl` or touching `sessions/`. analyze.py is what gathers the REAL
context (BÍN/is.lex attestation via type-repl, bar contents, confirmed-intents
overrides) and calls into here.

Status vocabulary: `fixed:<wave/commit>` (recurrence is a REGRESSION — flag
loudly), `in-flight:<task#>` (has an owner, not yet closed), `accepted-gap`
(known, intentionally not fixed — doctrine, not a bug), `watch` (machinery
shipped; watching for residual misses), `not-error` (not a defect at all).
"""

import json
import os
from dataclasses import dataclass


# --------------------------------------------------------------------------
# The taxonomy itself
# --------------------------------------------------------------------------

CLASSES = [
    dict(
        id="slangur-intentional",
        title="Intentional slang / confirmed non-typo",
        detect="token has an `intentional: true` entry in confirmed-intents.jsonl",
        status="not-error",
        notes="Tag and exclude from gap counts — this is not an error.",
    ),
    dict(
        id="stale-apply",
        title="Stale autocorrect re-apply",
        detect="applied kind is `stale-skip`, or an applied autocorrect's text "
               "equals the previously committed word while the bar concurrently "
               "held a different `ac` candidate",
        status="fixed:wave-28",
        notes="Any recurrence is a REGRESSION of a shipped fix — flag it loudly.",
    ),
    dict(
        id="valid-word-overlap",
        title="Valid-word overlap (doctrine non-fire)",
        detect="BOTH typo and intended are attested real words (BÍN-known or a "
               "non-junk-tier is.lex/en.lex entry) — the corrector must never "
               "silently replace one valid word with another",
        status="accepted-gap",
        notes="Tag NONFIRE, not error; excluded from the top-gaps ranking.",
    ),
    dict(
        id="inflection",
        title="Inflection miss",
        detect="analyze.py's own INFLECTION_MISS class — the bar offered a "
               "different inflection of the same stem",
        status="in-flight:#23",
        notes="",
    ),
    dict(
        id="space-miss",
        title="Space / dotted-token miss",
        detect="typo has no space where intended has one (or vice versa), or a "
               "dotted-token split (interior '.' present on only one side)",
        status="watch",
        notes="Machinery already shipped; watching for residual misses.",
    ),
    dict(
        id="compound-oov",
        title="Compound out-of-vocabulary",
        detect="intended length >= 8, absent from is.lex, but a trailing "
               "substring is independently attested (cheap/approximate — a "
               "triage hint, not a validity engine)",
        status="in-flight:#22",
        notes="",
    ),
    dict(
        id="restoration-fold",
        title="Accent/dental restoration fold",
        detect="typo/intended differ ONLY by acute accents (á é í ó ú ý) "
               "and/or the d<->ð, t<->þ pairs, on an otherwise identical "
               "skeleton",
        status="watch",
        notes="Wave 26 fixed the learning-poisoning half; residual misses "
              "still matter.",
    ),
    dict(
        id="deep-decode",
        title="Deep decode (>= 3 substitutions)",
        detect=">= 3 character-level edits between typo and intended",
        status="in-flight:#27",
        notes="",
    ),
    dict(
        id="context-ranking",
        title="Context ranking / margin miss",
        detect="intended appeared in the recorded bar (rs or plain) but a "
               "different candidate outranked it, or the margin missed",
        status="in-flight:#27",
        notes="the 'gret' class.",
    ),
    dict(
        id="proper-noun-oov",
        title="Proper-noun OOV",
        detect="intended is capitalized and not BÍN-known",
        status="accepted-gap",
        notes="lindgren/astrid class.",
    ),
]

NOVEL_ID = "NOVEL"
NOVEL = dict(
    id=NOVEL_ID,
    title="Novel / unclassified",
    detect="matched no class above",
    status="novel",
    notes="Render prominently at the TOP of the report — the taxonomy needs "
          "a fresh look, not just triage.",
)

CLASSES_BY_ID = {c["id"]: c for c in CLASSES}
CLASSES_BY_ID[NOVEL_ID] = NOVEL

# grammar-vouched-overlap (phase 1.5, Greynir enrichment): NOT a
# `classify_finding` precedence entry — it is an UPGRADE analyze.py/
# aggregate.py apply AFTER the base classifier tags something
# valid-word-overlap, when a Greynir parse of the sentence genuinely prefers
# `intended` over `typo` (intended parses cleanly and either typo doesn't
# parse at all, or intended's score clearly beats it — see
# greynir_enrich.vouch_decision). Registered directly in CLASSES_BY_ID (like
# NOVEL) rather than CLASSES so it never accidentally gets matched by the
# precedence cascade.
GRAMMAR_VOUCHED_ID = "grammar-vouched-overlap"
GRAMMAR_VOUCHED = dict(
    id=GRAMMAR_VOUCHED_ID,
    title="Grammar-vouched valid-word overlap",
    detect="upgrade of valid-word-overlap: Greynir parses the sentence with "
           "`intended` substituted for `typo` and genuinely prefers it "
           "(see greynir_enrich.vouch_decision)",
    status="watch",
    notes="candidate for context-aware margin work — measured, not yet "
          "acted on. Unlike plain valid-word-overlap this ranks in the "
          "top-gaps table (it is evidence the corrector COULD safely have "
          "fired, not a doctrine non-fire).",
)
CLASSES_BY_ID[GRAMMAR_VOUCHED_ID] = GRAMMAR_VOUCHED

# Precedence order — first matching detector wins. NOVEL is the fallback and
# deliberately excluded (it is never "matched", only defaulted to).
PRECEDENCE = [c["id"] for c in CLASSES]

# Classes that are doctrine-correct non-fires, not gaps — excluded from the
# top-gaps ranking (aggregate.py), shown separately instead.
DOCTRINE_NONFIRE_CLASSES = {"slangur-intentional", "valid-word-overlap"}


def status_of(class_id: str) -> str:
    return CLASSES_BY_ID.get(class_id, NOVEL)["status"]


def is_regression_status(status: str) -> bool:
    return status.startswith("fixed:")


def format_tag(class_id: str, status: str = None) -> str:
    """Render the `[class · status]` suffix a report line gets. NOVEL renders
    bare (it has no "status" worth stating — it's a call to classify it)."""
    if class_id == NOVEL_ID:
        return "[NOVEL]"
    status = status if status is not None else status_of(class_id)
    tag = f"[{class_id} · {status}]"
    if is_regression_status(status):
        tag += "  ⚠ REGRESSION"
    return tag


# --------------------------------------------------------------------------
# Detection primitives (pure — no I/O, no type-repl)
# --------------------------------------------------------------------------

_RESTORATION_FOLD = str.maketrans({
    "á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ý": "y",
    "ð": "d", "þ": "t",
})


def restoration_skeleton(s: str) -> str:
    return (s or "").lower().translate(_RESTORATION_FOLD)


def is_restoration_pair(typo: str, intended: str) -> bool:
    """Differ only by acute accents and/or d<->ð, t<->þ, on an identical
    skeleton (which also pins the length — a fold never changes it)."""
    if not typo or not intended or typo.lower() == intended.lower():
        return False
    if len(typo) != len(intended):
        return False
    return restoration_skeleton(typo) == restoration_skeleton(intended)


def is_space_miss(typo: str, intended: str) -> bool:
    if not typo or not intended:
        return False
    has_space_t = " " in typo or "\n" in typo
    has_space_i = " " in intended or "\n" in intended
    if has_space_t != has_space_i:
        return True
    # Dotted-token split: an interior '.' on only one side (sentence-final
    # dots are stripped first so they don't count).
    dot_t = "." in typo.strip(".")
    dot_i = "." in intended.strip(".")
    return dot_t != dot_i


def compound_probe_substrings(word: str, min_len: int = 4, max_trim: int = 3) -> list:
    """Cheap/approximate candidate substrings for the compound-oov heuristic:
    every slice of at least `min_len` chars, allowing up to `max_trim`
    trailing chars to be trimmed off the very end (Icelandic compounds often
    carry an inflectional suffix the bare stem doesn't), excluding the whole
    word itself. Not a validity engine — a triage hint only."""
    w = (word or "").lower()
    subs = []
    for start in range(0, max(0, len(w) - min_len + 1)):
        for trim in range(0, max_trim + 1):
            end = len(w) - trim
            seg = w[start:end]
            if min_len <= len(seg) < len(w):
                subs.append(seg)
    return list(dict.fromkeys(subs))


def _clean_token(tok: str) -> str:
    return (tok or "").strip(".,!?;:…“”\"'()[]")


# --------------------------------------------------------------------------
# Classifier
# --------------------------------------------------------------------------

@dataclass
class FindingContext:
    """Everything `classify_finding` needs, precomputed by the caller
    (analyze.py) so this module never has to touch type-repl, kb.jsonl, or
    confirmed-intents.jsonl directly."""
    typo: str
    intended: str
    event_cls: str = ""              # e.g. MISS_ABSENT, SILENT_MISS, INFLECTION_MISS...
    bar_seen: tuple = ()              # bar texts seen while typing (or cross-referenced)
    typo_valid: bool = False          # attested real word (BÍN-known or non-junk is/en.lex)
    intended_valid: bool = False
    intended_is_lex_present: bool = False  # raw is.lex membership (any freq/junk-tier)
    compound_hit: str = ""            # attested substring found, "" if none
    edit_distance: int = 0            # precomputed char-level edit distance
    applied_kind: str = ""            # "autocorrect" | "tap" | "none" | "stale-skip"
    stale_repeat: bool = False        # applied autocorrect repeats prev committed word
    confirmed: dict = None            # confirmed-intents.jsonl record for typo, if any


def classify_finding(ctx: FindingContext) -> tuple:
    """Return (class_id, status) — the first PRECEDENCE class whose detector
    fires against `ctx`, else (NOVEL, novel)."""
    typo = _clean_token(ctx.typo)
    intended = _clean_token(ctx.intended)
    bar_lower = {b.lower() for b in ctx.bar_seen if b}
    intended_l = intended.lower()

    if ctx.confirmed and ctx.confirmed.get("intentional"):
        return "slangur-intentional", status_of("slangur-intentional")

    if ctx.applied_kind == "stale-skip" or ctx.stale_repeat:
        return "stale-apply", status_of("stale-apply")

    if (ctx.typo_valid and ctx.intended_valid and typo and intended
            and typo.lower() != intended_l):
        return "valid-word-overlap", status_of("valid-word-overlap")

    if ctx.event_cls == "INFLECTION_MISS":
        return "inflection", status_of("inflection")

    if is_space_miss(typo, intended):
        return "space-miss", status_of("space-miss")

    if len(intended) >= 8 and not ctx.intended_is_lex_present and ctx.compound_hit:
        return "compound-oov", status_of("compound-oov")

    if is_restoration_pair(typo, intended):
        return "restoration-fold", status_of("restoration-fold")

    if intended and typo and ctx.edit_distance >= 3:
        return "deep-decode", status_of("deep-decode")

    if intended_l and intended_l in bar_lower:
        return "context-ranking", status_of("context-ranking")

    if intended[:1].isupper() and intended.isalpha() and not ctx.intended_valid:
        return "proper-noun-oov", status_of("proper-noun-oov")

    return NOVEL_ID, status_of(NOVEL_ID)


# --------------------------------------------------------------------------
# Confirmed intents (moved here from aggregate.py — the taxonomy's own
# slangur-intentional / user-confirmed-correction data source).
# --------------------------------------------------------------------------

def load_confirmed_intents(path: str = None) -> dict:
    """User-confirmed intents for tokens the scan can't resolve on its own
    (contested SILENT_MISS guesses, UNRESOLVABLE mashes). One JSON object per
    line in confirmed-intents.jsonl (gitignored — personal typing):

        {"typo": "dlmk", "intended": "dæmi"}
        {"typo": "kozy", "intentional": true}   # not a typo — suppress

    Keyed by lowercased typo."""
    if path is None:
        path = os.path.join(os.path.dirname(__file__), "confirmed-intents.jsonl")
    intents = {}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                typo = rec.get("typo", "")
                if typo:
                    intents[typo.lower()] = rec
    return intents
