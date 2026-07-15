#!/usr/bin/env python3
"""Fetch clean sentence corpora for the autocorrect eval datasets (data/eval/).

Source chosen: **Wikipedia** article extracts via the public MediaWiki API
(is.wikipedia.org, en.wikipedia.org), one language at a time.

Why Wikipedia, and why not the alternatives named in research/typing-datasets.md
and PLAN.md:

  - **lemma-is's IFD corpus** (data/ifd/ifd.jsonl in the lemma-is sibling repo,
    36,186 gold-tagged Icelandic sentences) was checked FIRST as instructed.
    It is clean, real, well-formed prose — but its CLARIN license ("Icelandic
    Frequency Dictionary" license, see
    https://repository.clarin.is/repository/xmlui/page/license-frequency-dictionary)
    is a restrictive research-only grant with an explicit no-redistribution
    clause: "Members of the said research group must not copy, publish,
    communicate to the public, or otherwise give to any third party access to
    the whole or any part of IFD." better-keyboard is a public FOSS repo —
    committing IFD-derived sentences would violate that clause. Documented as
    an acquisition gap; NOT used. (It remains fine to use privately/locally
    for e.g. one-off frequency analysis, just not to redistribute in this repo.)
  - **Icelandic Wikipedia** (is.wikipedia.org): CC BY-SA 4.0, openly
    redistributable, available live via API, no dump download needed.
  - **English**: Project Gutenberg (public domain) and the Leipzig Corpora
    English news sample were both considered per the task brief, but using
    Wikipedia for English too keeps the acquisition methodology identical
    across languages (same cleaning/filtering code, same license story, same
    "random article sample" selection process) rather than requiring a
    separate boilerplate-stripping pipeline for Gutenberg headers/footers.
    English Wikipedia is CC BY-SA 4.0.
  - OSCAR/CC-100 were considered for Icelandic but require bulk dump downloads
    (GBs) with noisier web-scrape text; Wikipedia's `explaintext` API gives
    already-clean prose extracts with no HTML/wikitext to strip beyond
    headers/lists handled below.

Method: repeatedly draw random article titles (`list=random`, namespace 0,
articles only) and fetch each article's full plain-text extract
(`prop=extracts&explaintext=1`) concurrently (thread pool — extracts are
capped to one full article per API call server-side, so parallel *requests*
are the only way to get throughput). Paragraphs that look like headers,
lists, or tables are dropped; remaining paragraphs are split into sentences
with a lightweight regex splitter and filtered for length/shape. Sentences
are deduplicated (NFC-normalized) across the whole run.

Usage:
    python3 scripts/fetch-eval-corpora.py --lang is --target 7000 --out-dir data/eval
    python3 scripts/fetch-eval-corpora.py --lang en --target 7000 --out-dir data/eval

Writes:
    data/eval/sentences.{lang}.txt  - one clean sentence per line, NFC, deduped
    data/eval/sources.{lang}.jsonl  - {"pageid", "title"} manifest of every
                                       article that contributed >=1 sentence
                                       (CC BY-SA attribution/reproducibility trail)

Network access required (Wikipedia API). If a fetch run comes up short of
--target, the script writes whatever it collected and prints a warning —
callers should treat that as a documented acquisition gap, not fail silently.

Stdlib only (urllib, json, re, unicodedata, concurrent.futures).
"""
import argparse
import json
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

USER_AGENT = (
    "better-keyboard-eval-corpus/0.1 "
    "(https://github.com/jokull/better-keyboard; research/eval dataset build; "
    "contact: jokull@triptojapan.com)"
)

API_HOST = {"is": "is.wikipedia.org", "en": "en.wikipedia.org"}

# Lines that are structural (headers, lists, tables) rather than prose.
HEADER_RE = re.compile(r"^\s*=+.*=+\s*$")
BULLET_RE = re.compile(r"^\s*([*#;:]|[-–—]\s|\d+[.)]\s)")
CITATION_RE = re.compile(r"\[\d+\]")
MULTI_WS_RE = re.compile(r"\s+")

# Sentence-ending punctuation run.
SENTENCE_END_RE = re.compile(r"[.!?]+")

# Common abbreviations whose internal/trailing "." must not be treated as a
# sentence boundary (checked against the bare word token immediately before
# the period). Single-letter tokens (initials, e.g. "J. Smith") are handled
# separately below. Not exhaustive — a heuristic, not a full abbreviation
# dictionary; residual false splits are a documented known limitation.
ABBREVIATIONS = {
    # Icelandic
    "t.d", "o.s.frv", "þ.e", "m.a", "þ.á.m", "sbr", "nr", "hr", "frú", "dr",
    "próf", "kt", "sf", "hf", "ehf", "o.fl", "o.þ.h", "s.s", "þ.á",
    # English
    "mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "etc", "e.g",
    "i.e", "no", "co", "inc", "ltd", "gen", "capt", "col", "vol", "op",
    "approx",
}

MIN_SENTENCE_CHARS = 30
MAX_SENTENCE_CHARS = 240
MIN_WORDS = 5
MAX_DIGIT_RATIO = 0.2
BAD_SUBSTRINGS = ("{{", "}}", "[[", "]]", "http://", "https://", "www.", "|", "==")


def api_get(lang: str, params: dict, timeout: float = 15.0, retries: int = 5) -> dict:
    host = API_HOST[lang]
    url = f"https://{host}/w/api.php?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    backoff = 1.0
    last_err: Exception | None = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code == 429 or e.code >= 500:
                retry_after = e.headers.get("Retry-After") if e.headers else None
                wait = float(retry_after) if retry_after and retry_after.isdigit() else backoff
                time.sleep(wait)
                backoff = min(backoff * 2, 30.0)
                continue
            raise
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            last_err = e
            time.sleep(backoff)
            backoff = min(backoff * 2, 30.0)
            continue
    raise last_err  # type: ignore[misc]


def fetch_random_titles(lang: str, n: int) -> list[tuple[int, str]]:
    """Returns (pageid, title) pairs. list=random doesn't give pageid reliably
    across all MediaWiki versions in one shot without a follow-up, so we
    just carry titles and re-derive pageid from the extract response."""
    data = api_get(
        lang,
        {
            "action": "query",
            "list": "random",
            "rnnamespace": 0,
            "rnlimit": n,
            "format": "json",
        },
    )
    return [(p["id"], p["title"]) for p in data.get("query", {}).get("random", [])]


def fetch_extract(lang: str, title: str) -> tuple[int | None, str, str]:
    """Returns (pageid, title, extract_text). extract_text is '' on failure
    (missing page, redirect loop, network error)."""
    try:
        data = api_get(
            lang,
            {
                "action": "query",
                "prop": "extracts",
                "explaintext": 1,
                "redirects": 1,
                "format": "json",
                "titles": title,
            },
        )
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
        return None, title, ""
    pages = data.get("query", {}).get("pages", {})
    for pageid, page in pages.items():
        if "missing" in page:
            return None, title, ""
        return page.get("pageid"), page.get("title", title), page.get("extract", "")
    return None, title, ""


def clean_paragraphs(extract: str) -> list[str]:
    paragraphs = []
    for line in extract.split("\n"):
        line = line.strip()
        if not line:
            continue
        if HEADER_RE.match(line):
            continue
        if BULLET_RE.match(line):
            continue
        paragraphs.append(line)
    return paragraphs


def is_abbreviation_before(text: str, period_pos: int) -> bool:
    """True if the bare token immediately preceding text[period_pos] (a '.')
    looks like an abbreviation/initial rather than a real sentence end."""
    start_tok = text.rfind(" ", 0, period_pos) + 1
    token = text[start_tok:period_pos]
    if not token:
        return False
    if len(token) == 1 and token.isalpha():
        return True  # single-letter initial, e.g. "J." in "J. Smith"
    return token.lower() in ABBREVIATIONS


def split_sentences(paragraph: str) -> list[str]:
    text = MULTI_WS_RE.sub(" ", paragraph).strip()
    if not text:
        return []
    sentences = []
    start = 0
    for m in SENTENCE_END_RE.finditer(text):
        end = m.end()
        if end >= len(text):
            continue
        if text[m.start() : m.end()] == "." and is_abbreviation_before(text, m.start()):
            continue
        next_char = text[end : end + 1]
        if next_char != " ":
            continue
        after_space = text[end + 1 : end + 2]
        if after_space and (after_space.isupper() or after_space in "\"'“”"):
            candidate = text[start:end].strip()
            if candidate:
                sentences.append(candidate)
            start = end + 1
    tail = text[start:].strip()
    if tail:
        sentences.append(tail)
    return sentences


def is_clean_sentence(s: str) -> bool:
    if not (MIN_SENTENCE_CHARS <= len(s) <= MAX_SENTENCE_CHARS):
        return False
    if len(s.split()) < MIN_WORDS:
        return False
    if s[-1] not in ".!?":
        return False
    if not s[0].isupper():
        return False
    if any(bad in s for bad in BAD_SUBSTRINGS):
        return False
    digits = sum(1 for c in s if c.isdigit())
    if digits / len(s) > MAX_DIGIT_RATIO:
        return False
    stripped = CITATION_RE.sub("", s)
    if stripped != s and not (MIN_SENTENCE_CHARS <= len(stripped) <= MAX_SENTENCE_CHARS):
        return False
    return True


def extract_to_sentences(extract: str) -> list[str]:
    out = []
    for para in clean_paragraphs(extract):
        para = CITATION_RE.sub("", para)
        for sent in split_sentences(para):
            sent = unicodedata.normalize("NFC", sent)
            if is_clean_sentence(sent):
                out.append(sent)
    return out


def run(lang: str, target: int, max_articles: int, workers: int, batch: int) -> tuple[list[str], list[dict]]:
    seen_titles: set[str] = set()
    seen_sentences: set[str] = set()
    sentences: list[str] = []
    sources: list[dict] = []
    articles_tried = 0

    with ThreadPoolExecutor(max_workers=workers) as pool:
        while len(sentences) < target and articles_tried < max_articles:
            titles = fetch_random_titles(lang, batch)
            fresh = [t for _, t in titles if t not in seen_titles]
            for t in fresh:
                seen_titles.add(t)
            if not fresh:
                continue
            futures = [pool.submit(fetch_extract, lang, t) for t in fresh]
            for fut in as_completed(futures):
                pageid, title, extract = fut.result()
                articles_tried += 1
                if not extract:
                    continue
                new_sents = extract_to_sentences(extract)
                added = 0
                for s in new_sents:
                    if s not in seen_sentences:
                        seen_sentences.add(s)
                        sentences.append(s)
                        added += 1
                if added:
                    sources.append({"pageid": pageid, "title": title, "sentences_added": added})
            print(
                f"[{lang}] articles_tried={articles_tried} "
                f"sentences={len(sentences)}/{target}",
                flush=True,
            )
            if len(sentences) >= target or articles_tried >= max_articles:
                break
            time.sleep(0.3)
    return sentences, sources


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lang", required=True, choices=["is", "en"])
    ap.add_argument("--target", type=int, default=7000, help="target sentence count (buffer above the 5000 floor)")
    ap.add_argument("--max-articles", type=int, default=6000, help="hard cap on articles fetched (safety valve)")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--batch", type=int, default=25, help="random titles requested per list=random call")
    ap.add_argument("--out-dir", default="data/eval")
    args = ap.parse_args()

    t0 = time.time()
    sentences, sources = run(args.lang, args.target, args.max_articles, args.workers, args.batch)
    elapsed = time.time() - t0

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    sent_path = out_dir / f"sentences.{args.lang}.txt"
    src_path = out_dir / f"sources.{args.lang}.jsonl"

    sent_path.write_text("\n".join(sentences) + "\n", encoding="utf-8")
    with src_path.open("w", encoding="utf-8") as f:
        for rec in sources:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    print(
        f"[{args.lang}] done in {elapsed:.1f}s: {len(sentences)} sentences "
        f"from {len(sources)} articles -> {sent_path}"
    )
    if len(sentences) < 5000:
        print(
            f"WARNING [{args.lang}]: only {len(sentences)} sentences collected, "
            f"below the 5000 floor. Documented gap — rerun with a higher "
            f"--max-articles or investigate network access.",
            flush=True,
        )


if __name__ == "__main__":
    main()
