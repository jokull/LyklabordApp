#!/usr/bin/env python3
"""
greynir_enrich.py — OPTIONAL Greynir grammar-parse enrichment for
session-analyzer findings (eval-studio v2 phase 1.5).

Stdlib only at import time — `reynir` itself lives in a dedicated venv
(tools/session-analyzer/.venv, see README.md's Setup section) and is never
imported here directly. All actual parsing happens in `greynir_worker.py`,
invoked as a SINGLE batched subprocess call per `batch_parse()` invocation
(reynir's grammar load dominates startup cost, so one call amortizes it
across every sentence/word the caller needs). Results are cached on disk in `.greynir-cache.json` (gitignored — it quotes
real typed sentences, same rule as sessions/) keyed by sentence-hash /
lowercase word, so re-ingests with an unchanged corpus need zero subprocess
calls.

Every public function degrades gracefully: if the venv or `reynir` import is
unavailable, or the subprocess call fails/times out, functions return empty
results plus note="greynir: unavailable" — NEVER an exception. analyze.py and
aggregate.py must both keep working, unchanged, with this module absent
entirely.
"""

import hashlib
import json
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_VENV_PYTHON = os.path.join(_HERE, ".venv", "bin", "python")
_WORKER = os.path.join(_HERE, "greynir_worker.py")
DEFAULT_CACHE_PATH = os.path.join(_HERE, ".greynir-cache.json")

UNAVAILABLE_NOTE = "greynir: unavailable"

_availability_cache: dict = {}


def venv_python_path() -> str:
    return _DEFAULT_VENV_PYTHON


def available(venv_python: str = None) -> bool:
    """Cheap, cached check: does the venv exist and import reynir+islenska?"""
    venv_python = venv_python or _DEFAULT_VENV_PYTHON
    if venv_python in _availability_cache:
        return _availability_cache[venv_python]
    ok = False
    if os.path.exists(venv_python):
        try:
            r = subprocess.run(
                [venv_python, "-c", "import reynir, islenska"],
                capture_output=True, timeout=15,
            )
            ok = r.returncode == 0
        except Exception:
            ok = False
    _availability_cache[venv_python] = ok
    return ok


# --------------------------------------------------------------------------
# Cache
# --------------------------------------------------------------------------

def _load_cache(path: str) -> dict:
    if not os.path.exists(path):
        return {"sentences": {}, "words": {}}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        data.setdefault("sentences", {})
        data.setdefault("words", {})
        return data
    except Exception:
        return {"sentences": {}, "words": {}}


def _save_cache(path: str, cache: dict) -> None:
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(cache, fh, ensure_ascii=False)
    except Exception:
        pass


def _sent_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------
# Batched subprocess dispatch
# --------------------------------------------------------------------------

def batch_parse(sentences=(), words=(), cache_path: str = None,
                venv_python: str = None, subprocess_timeout: float = 60.0) -> tuple:
    """Resolve every sentence/word, preferring the on-disk cache; only the
    cache MISSES are sent to the venv, in exactly one subprocess invocation
    (empty request short-circuits with no subprocess at all).

    Returns (sent_results, word_results, note):
      sent_results: {sentence_text: [ {text,parsed,score,skipped,terminals}, ... ]}
      word_results: {word: [case_code, ...]}
      note: "" on success, else "greynir: unavailable" (never raises).
    """
    cache_path = cache_path or DEFAULT_CACHE_PATH
    venv_python = venv_python or _DEFAULT_VENV_PYTHON
    cache = _load_cache(cache_path)

    sentences = list(dict.fromkeys(sentences))
    words = list(dict.fromkeys(words))

    sent_out, word_out = {}, {}
    missing_sents, missing_words = [], []

    for s in sentences:
        h = _sent_hash(s)
        if h in cache["sentences"]:
            sent_out[s] = cache["sentences"][h]["result"]
        else:
            missing_sents.append(s)
    for w in words:
        k = w.lower()
        if k in cache["words"]:
            word_out[w] = cache["words"][k]
        else:
            missing_words.append(w)

    if not missing_sents and not missing_words:
        return sent_out, word_out, ""

    if not available(venv_python):
        for s in missing_sents:
            sent_out[s] = []
        for w in missing_words:
            word_out[w] = []
        return sent_out, word_out, UNAVAILABLE_NOTE

    note = ""
    try:
        import tempfile
        with tempfile.TemporaryDirectory(prefix="greynir-batch-") as td:
            in_path = os.path.join(td, "in.json")
            out_path = os.path.join(td, "out.json")
            with open(in_path, "w", encoding="utf-8") as fh:
                json.dump({"sentences": missing_sents, "words": missing_words},
                          fh, ensure_ascii=False)
            r = subprocess.run(
                [venv_python, _WORKER, in_path, out_path],
                capture_output=True, text=True, timeout=subprocess_timeout,
            )
            if r.returncode != 0 or not os.path.exists(out_path):
                raise RuntimeError(f"worker exit {r.returncode}: {r.stderr[-500:]}")
            with open(out_path, "r", encoding="utf-8") as fh:
                fresh = json.load(fh)
        if fresh.get("error"):
            note = f"greynir: worker error ({fresh['error']})"
        for s in missing_sents:
            result = fresh.get("sentences", {}).get(s, [])
            sent_out[s] = result
            cache["sentences"][_sent_hash(s)] = {"result": result}
        for w in missing_words:
            result = fresh.get("words", {}).get(w, [])
            word_out[w] = result
            cache["words"][w.lower()] = result
        _save_cache(cache_path, cache)
    except Exception as e:
        note = f"greynir: unavailable ({type(e).__name__})"
        for s in missing_sents:
            sent_out.setdefault(s, [])
        for w in missing_words:
            word_out.setdefault(w, [])

    return sent_out, word_out, note


# --------------------------------------------------------------------------
# Feature helpers — pure post-processing over batch_parse's results, so the
# classification/threshold logic is unit-testable without a real venv.
# --------------------------------------------------------------------------

LOW_SCORE_THRESHOLD = 0  # parsed but score <= this is "very low confidence"
VOUCH_SCORE_MARGIN = 8   # intended must beat typo by this much when both parse


def sentence_best(parses: list) -> dict:
    """Reduce a batch_parse sentence result (possibly several Greynir-detected
    sentences inside one input text) to one summary: parsed iff ALL detected
    sentences parsed, score = the minimum (the weakest link), skipped iff any
    sentence timed out. Empty input (venv unavailable) -> parsed=False,
    score=None, skipped=False, unavailable=True."""
    if not parses:
        return {"parsed": False, "score": None, "skipped": False, "unavailable": True}
    parsed = all(p.get("parsed") for p in parses)
    scores = [p.get("score") for p in parses if p.get("score") is not None]
    score = min(scores) if scores else (0 if parsed else None)
    skipped = any(p.get("skipped") for p in parses)
    return {"parsed": parsed, "score": score, "skipped": skipped, "unavailable": False}


def is_low_confidence(summary: dict) -> bool:
    if summary.get("unavailable") or summary.get("skipped"):
        return False
    if not summary.get("parsed"):
        return True
    score = summary.get("score")
    return score is not None and score <= LOW_SCORE_THRESHOLD


def grammar_review_reason(problem_tokens: list, confirmed_intents: dict = None) -> str:
    """'foreign-token' when the failing sentence contains a token the
    TOKENIZER itself couldn't classify at all (kind == TOK.UNKNOWN — reserved
    for genuinely foreign/garbled chunks, unlike an ordinary misspelled
    Icelandic WORD, which the tokenizer still recognizes as word-shaped) or a
    token confirmed-intents.jsonl marks `intentional` (slang/foreign, not a
    typo); else 'grammar'. Deliberately NOT keyed on "lacks Icelandic
    diacritics" — that would mislabel ordinary accent-drop typos (þvi, Eg)
    as foreign, which is exactly the false positive this module must avoid."""
    confirmed_intents = confirmed_intents or {}
    for t in problem_tokens:
        if t.get("unknown"):
            return "foreign-token"
        txt = (t.get("text") or "").lower()
        rec = confirmed_intents.get(txt)
        if rec and rec.get("intentional"):
            return "foreign-token"
    return "grammar"


def vouch_decision(typo_summary: dict, intended_summary: dict) -> bool:
    """Does Greynir genuinely prefer `intended` over `typo`? Yes iff intended
    parses AND (typo doesn't parse OR intended's score clearly beats typo's
    by VOUCH_SCORE_MARGIN). A few points' difference when both parse cleanly
    is NOT "clearly better" — stay conservative, this gates a taxonomy
    upgrade that feeds the top-gaps ranking."""
    if typo_summary.get("unavailable") or intended_summary.get("unavailable"):
        return False
    if not intended_summary.get("parsed"):
        return False
    if not typo_summary.get("parsed"):
        return True
    ts, iscore = typo_summary.get("score"), intended_summary.get("score")
    if ts is None or iscore is None:
        return False
    return (iscore - ts) >= VOUCH_SCORE_MARGIN


_CASE_MAP = {"nf": "NF", "þf": "ÞF", "þgf": "ÞGF", "ef": "EF"}


def prep_case_disagreements(parses: list, bin_cases: dict) -> list:
    """For each preposition ('fs') terminal in a successfully parsed sentence,
    compare its governed case against the following nominal terminal's actual
    BÍN case set (`bin_cases`, keyed by the surface word as typed — an
    INDEPENDENT check, not just trusting Greynir's own resolution of an
    unattested/fallback token). Returns one string per disagreement."""
    out = []
    for sent in parses:
        if not sent.get("parsed"):
            continue
        terms = sent.get("terminals", [])
        for i, t in enumerate(terms):
            if t.get("cat") != "fs":
                continue
            governed = ""
            for v in t.get("variants", []):
                vl = v.lower()
                if vl in _CASE_MAP:
                    governed = _CASE_MAP[vl]
                    break
            if not governed or i + 1 >= len(terms):
                continue
            nxt = terms[i + 1]
            word = nxt.get("text", "")
            cases = bin_cases.get(word)
            if cases is None or not cases:
                continue  # unknown to BÍN — not this audit's concern
            if governed not in cases:
                out.append(
                    f"`{t.get('text')}` governs {governed} but `{word}` is "
                    f"only attested as {'/'.join(cases)}"
                )
    return out
