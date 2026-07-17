#!/usr/bin/env python3
"""
greynir_worker.py — runs INSIDE the dedicated venv (tools/session-analyzer/.venv,
which has `reynir`/`islenska` installed; see README.md's Setup section). Never
imported by analyze.py/aggregate.py directly — greynir_enrich.py shells out to
this file with the venv's python so the main pipeline stays stdlib-importable.

Contract: read one JSON object from argv[1] (a path), write one JSON object to
argv[2] (a path). Never raises past main() — any failure is reported as
{"error": "..."} so the stdlib-side caller can degrade gracefully.

Input shape:
    {"sentences": ["Ég fór í búð.", ...], "words": ["orð", ...]}

Output shape:
    {
      "sentences": {
        "<input text>": [
          {"text": "<reynir's sentence text>", "parsed": bool,
           "score": int|null, "skipped": bool, "terminals": [
             {"text": str, "terminal": str, "cat": str, "variants": [str]}
           ],
           "tokens": [{"text": str, "unknown": bool}]}
          ... one dict per Greynir-detected sentence inside the input text
        ]
      },
      "words": {"<word>": ["NF", "ÞGF", ...]}   # BÍN case forms, [] if none
    }

`tokens`/`unknown` (tokenizer.TOK.UNKNOWN — a chunk the tokenizer itself could
not classify at all, as opposed to a WORD it just doesn't recognize) is
reported even when the parse fails, since that is the residual-error pass's
"foreign-token vs. grammar" signal (analyze.py/greynir_enrich.py's
`grammar_review_reason`).

Per-(Greynir-detected)-sentence parse timeout: 5s (skipped, not crashed, if
exceeded — a hung/pathological parse must never stall the whole batch).
"""

import json
import sys
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutTimeout

PARSE_TIMEOUT_S = 5

_CASE_CODES = ("ÞGF", "ÞF", "NF", "EF")  # order irrelevant, no substring overlap


def _case_of(mark: str) -> str:
    for code in _CASE_CODES:
        if code in mark:
            return code
    return ""


def _bin_cases(bin_db, word: str) -> list:
    try:
        _, entries = bin_db.lookup(word)
    except Exception:
        return []
    cases = []
    for e in entries:
        c = _case_of(getattr(e, "mark", "") or "")
        if c and c not in cases:
            cases.append(c)
    return cases


def _tokens_of(sent) -> list:
    try:
        from tokenizer import TOK
        return [{"text": tok.txt, "unknown": tok.kind == TOK.UNKNOWN}
                for tok in sent.tokens if getattr(tok, "txt", None)]
    except Exception:
        return []


def _parse_one(sent) -> dict:
    tokens = _tokens_of(sent)
    with ThreadPoolExecutor(max_workers=1) as ex:
        fut = ex.submit(sent.parse)
        try:
            ok = fut.result(timeout=PARSE_TIMEOUT_S)
        except FutTimeout:
            return {"text": getattr(sent, "text", ""), "parsed": False,
                    "score": None, "skipped": True, "terminals": [],
                    "tokens": tokens}
        except Exception:
            return {"text": getattr(sent, "text", ""), "parsed": False,
                    "score": None, "skipped": False, "terminals": [],
                    "tokens": tokens}
    terminals = []
    if ok:
        try:
            for tn in sent.terminal_nodes:
                terminals.append({
                    "text": tn.text,
                    "terminal": tn.terminal,
                    "cat": getattr(tn, "cat", "") or "",
                    "variants": list(getattr(tn, "variants", []) or []),
                })
        except Exception:
            pass
    return {"text": sent.text, "parsed": bool(ok),
            "score": sent.score if ok else 0, "skipped": False,
            "terminals": terminals, "tokens": tokens}


def _parse_text(g, text: str) -> list:
    try:
        job = g.submit(text)
    except Exception:
        return [{"text": text, "parsed": False, "score": None,
                  "skipped": False, "terminals": [], "tokens": []}]
    out = []
    try:
        for sent in job:
            out.append(_parse_one(sent))
    except Exception:
        if not out:
            out = [{"text": text, "parsed": False, "score": None,
                      "skipped": False, "terminals": [], "tokens": []}]
    return out


def main(argv: list) -> int:
    in_path, out_path = argv[1], argv[2]
    with open(in_path, "r", encoding="utf-8") as fh:
        job = json.load(fh)
    result = {"sentences": {}, "words": {}}
    try:
        from reynir import Greynir
        from islenska import Bin
        g = Greynir()
        bin_db = Bin()
        for text in job.get("sentences", []):
            result["sentences"][text] = _parse_text(g, text)
        for word in job.get("words", []):
            result["words"][word] = _bin_cases(bin_db, word)
    except Exception as e:
        result["error"] = f"{type(e).__name__}: {e}"
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(result, fh, ensure_ascii=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
