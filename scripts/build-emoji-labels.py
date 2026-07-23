#!/usr/bin/env python3
"""Build the complete Icelandic emoji label corpus from Unicode CLDR.

The source versions and hashes are deliberately pinned. Updating the corpus is
an explicit dependency upgrade, not a network-dependent build step.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys
import unicodedata
import urllib.request
import xml.etree.ElementTree as ET


CLDR_VERSION = "48.2"
EMOJI_VERSION = "17.0"
EXPECTED_EMOJI_COUNT = 3_944
EXPECTED_PICKER_EMOJI_COUNT = 2_501
PICKER_PATH = (
    Path(__file__).resolve().parents[1]
    / "Packages/ISEmojiView/Sources/ISEmojiView/Assets/ISEmojiList.plist"
)
SOURCES = {
    "annotations": (
        "https://raw.githubusercontent.com/unicode-org/cldr/"
        "release-48-2/common/annotations/is.xml",
        "f39e53f8b8555f5b68cca96bf6be4ed17664dee10be99be3a361507e11060739",
    ),
    "annotationsDerived": (
        "https://raw.githubusercontent.com/unicode-org/cldr/"
        "release-48-2/common/annotationsDerived/is.xml",
        "5ffa629672a72953a4300f1b7aed706ea19a2df5a97714a014aa5b33cced1510",
    ),
    "emojiTest": (
        "https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt",
        "1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda",
    ),
}


def fetch(name: str) -> bytes:
    url, expected_hash = SOURCES[name]
    request = urllib.request.Request(url, headers={"User-Agent": "LyklabordApp emoji builder"})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
    actual_hash = hashlib.sha256(data).hexdigest()
    if actual_hash != expected_hash:
        raise RuntimeError(
            f"{name} SHA-256 mismatch: expected {expected_hash}, got {actual_hash}"
        )
    return data


def lookup_key(text: str) -> str:
    # CLDR deliberately omits Emoji/Text Variation Selectors from annotation
    # keys. Preserve them in the emitted emoji, but remove them for lookup.
    return text.replace("\ufe0e", "").replace("\ufe0f", "")


def parse_annotations(documents: list[bytes]) -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    for document in documents:
        for annotation in ET.fromstring(document).findall(".//annotation"):
            key = lookup_key(annotation.attrib["cp"])
            record = result.setdefault(key, {"name": None, "keywords": []})
            text = (annotation.text or "").strip()
            if annotation.attrib.get("type") == "tts":
                # Explicit annotations are loaded before derived annotations,
                # so preserve the explicit value if CLDR ever overlaps them.
                if record["name"] is None:
                    record["name"] = text
            else:
                keywords = [value.strip() for value in text.split("|") if value.strip()]
                record["keywords"] = list(dict.fromkeys(record["keywords"] + keywords))
    return result


def parse_emoji_test(document: bytes) -> list[str]:
    result: list[str] = []
    for line in document.decode("utf-8").splitlines():
        if "; fully-qualified" not in line:
            continue
        codepoints = line.split(";", 1)[0].strip().split()
        result.append("".join(chr(int(value, 16)) for value in codepoints))
    return result


def build() -> tuple[bytes, bytes, bytes]:
    annotations = parse_annotations([fetch("annotations"), fetch("annotationsDerived")])
    emojis = parse_emoji_test(fetch("emojiTest"))
    if len(emojis) != EXPECTED_EMOJI_COUNT:
        raise RuntimeError(
            f"Emoji {EMOJI_VERSION} count changed: expected {EXPECTED_EMOJI_COUNT}, "
            f"got {len(emojis)}"
        )

    entries = []
    missing = []
    for emoji in emojis:
        annotation = annotations.get(lookup_key(emoji))
        if annotation is None or not annotation["name"]:
            missing.append(emoji)
            continue
        entries.append(
            {
                "emoji": emoji,
                "name": annotation["name"],
                "keywords": annotation["keywords"],
            }
        )
    if missing:
        raise RuntimeError(
            f"CLDR {CLDR_VERSION} lacks Icelandic labels for {len(missing)} emoji: "
            + " ".join(missing[:20])
        )

    corpus = {
        "schema": 1,
        "locale": "is",
        "cldrVersion": CLDR_VERSION,
        "emojiVersion": EMOJI_VERSION,
        "license": "Unicode-3.0",
        "count": len(entries),
        "sources": {name: {"url": url, "sha256": digest} for name, (url, digest) in SOURCES.items()},
        "entries": entries,
    }
    corpus_bytes = (
        json.dumps(corpus, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode()
    return corpus_bytes, build_suggestions(entries), build_search(entries)


def normalized_term(value: str) -> str:
    return unicodedata.normalize("NFC", value.strip()).lower()


def search_tokens(value: str) -> list[str]:
    return re.findall(r"[^\W_]+(?:-[^\W_]+)*", normalized_term(value), flags=re.UNICODE)


def picker_emojis() -> set[str]:
    with PICKER_PATH.open("rb") as file:
        categories = plistlib.load(file)
    result: set[str] = set()
    for category in categories:
        for value in category["emojis"]:
            if isinstance(value, list):
                result.update(value)
            else:
                result.add(value)
    if len(result) != EXPECTED_PICKER_EMOJI_COUNT:
        raise RuntimeError(
            "ISEmojiView picker count changed: expected "
            f"{EXPECTED_PICKER_EMOJI_COUNT}, got {len(result)}"
        )
    return result


def build_search(entries: list[dict[str, object]]) -> bytes:
    """Emit the compact picker-only Icelandic browse-search corpus."""
    supported = picker_emojis()
    picker_by_key = {lookup_key(emoji): emoji for emoji in supported}
    rows: list[list[str]] = []
    token_postings: dict[str, set[int]] = {}

    for entry in entries:
        source_emoji = str(entry["emoji"])
        if any("\U0001f3fb" <= char <= "\U0001f3ff" for char in source_emoji):
            continue
        emoji = picker_by_key.get(lookup_key(source_emoji))
        if emoji is None:
            continue
        name = normalized_term(str(entry["name"]))
        keywords = list(dict.fromkeys(
            normalized_term(str(value))
            for value in entry["keywords"]
            if normalized_term(str(value))
            and normalized_term(str(value)) != name
        ))
        row_index = len(rows)
        rows.append([emoji, name, *keywords])
        tokens = set(search_tokens(name))
        for keyword in keywords:
            tokens.update(search_tokens(keyword))
        for token in tokens:
            token_postings.setdefault(token, set()).add(row_index)

    posting_count = sum(len(postings) for postings in token_postings.values())
    expected = (1_586, 2_798, 6_024)
    actual = (len(rows), len(token_postings), posting_count)
    if actual != expected:
        raise RuntimeError(f"search metrics changed: expected {expected}, got {actual}")

    artifact = {
        "schema": 1,
        "locale": "is",
        "cldrVersion": CLDR_VERSION,
        "emojiVersion": EMOJI_VERSION,
        "pickerSha256": hashlib.sha256(PICKER_PATH.read_bytes()).hexdigest(),
        "emojiCount": len(rows),
        "tokenCount": len(token_postings),
        "postingCount": posting_count,
        # Conventional unqualified matches where CLDR intentionally assigns
        # the same generic keyword to a family (e.g. every coloured heart).
        "strongMatches": {"hjarta": "❤️"},
        # Positional row: emoji, CLDR display name, then CLDR keywords.
        "entries": rows,
    }
    result = (json.dumps(artifact, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    if len(result) >= 100_000:
        raise RuntimeError(f"search artifact exceeds 100KB gate: {len(result)} bytes")
    return result


def build_suggestions(entries: list[dict[str, object]]) -> bytes:
    """Emit the small, conservative exact-match index shipped in the appex."""
    supported = picker_emojis()
    # Emoji/Text presentation selectors differ between Emoji Test and the
    # picker plist. Join on the CLDR-style selector-free key, but emit the
    # picker's exact string so insertion matches the grid.
    picker_by_key = {lookup_key(emoji): emoji for emoji in supported}
    base_entries = [
        entry
        for entry in entries
        if lookup_key(str(entry["emoji"])) in picker_by_key
        and not any("\U0001f3fb" <= char <= "\U0001f3ff" for char in str(entry["emoji"]))
    ]

    names: dict[str, set[str]] = {}
    keywords: dict[str, set[str]] = {}
    for entry in base_entries:
        emoji = picker_by_key[lookup_key(str(entry["emoji"]))]
        name = normalized_term(str(entry["name"]))
        if name and " " not in name:
            names.setdefault(name, set()).add(emoji)
        for raw_keyword in entry["keywords"]:
            keyword = normalized_term(str(raw_keyword))
            if keyword and " " not in keyword:
                keywords.setdefault(keyword, set()).add(emoji)

    suggestions: dict[str, str] = {}
    for term, candidates in names.items():
        if len(candidates) == 1:
            suggestions[term] = next(iter(candidates))
    for term, candidates in keywords.items():
        if term not in suggestions and len(candidates) == 1:
            suggestions[term] = next(iter(candidates))

    # CLDR applies the generic keyword to every coloured/decorated heart.
    # The conventional strong match in ordinary Icelandic text is red heart.
    overrides = {"hjarta": "❤️"}
    for term, emoji in overrides.items():
        if emoji not in supported:
            raise RuntimeError(f"emoji override is not in the picker: {term} -> {emoji}")
        suggestions[term] = emoji

    if (
        lookup_key(suggestions.get("hjarta", "")) != lookup_key("❤️")
        or lookup_key(suggestions.get("kaffi", "")) != lookup_key("☕")
    ):
        raise RuntimeError("required Icelandic emoji suggestion smoke checks failed")

    artifact = {
        "schema": 1,
        "locale": "is",
        "cldrVersion": CLDR_VERSION,
        "emojiVersion": EMOJI_VERSION,
        "match": "exact-single-token",
        "count": len(suggestions),
        "suggestions": dict(sorted(suggestions.items())),
    }
    return (json.dumps(artifact, ensure_ascii=False, separators=(",", ":")) + "\n").encode()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "data/emoji/is.json",
    )
    parser.add_argument(
        "--suggestions-output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "data/emoji/is-suggestions.json",
    )
    parser.add_argument(
        "--search-output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "data/emoji/is-search.json",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if the generated bytes differ from the existing output",
    )
    args = parser.parse_args()
    generated, generated_suggestions, generated_search = build()
    if args.check:
        corpus_ok = args.output.exists() and args.output.read_bytes() == generated
        suggestions_ok = (
            args.suggestions_output.exists()
            and args.suggestions_output.read_bytes() == generated_suggestions
        )
        search_ok = (
            args.search_output.exists()
            and args.search_output.read_bytes() == generated_search
        )
        if not corpus_ok:
            print(f"out of date: {args.output}", file=sys.stderr)
        if not suggestions_ok:
            print(f"out of date: {args.suggestions_output}", file=sys.stderr)
        if not search_ok:
            print(f"out of date: {args.search_output}", file=sys.stderr)
        if not corpus_ok or not suggestions_ok or not search_ok:
            return 1
        match_count = len(json.loads(generated_suggestions)["suggestions"])
        print(
            f"ok: {args.output} ({EXPECTED_EMOJI_COUNT} emoji); "
            f"{args.suggestions_output} ({match_count} matches); "
            f"{args.search_output} ({len(generated_search)} bytes)"
        )
        return 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(generated)
    args.suggestions_output.parent.mkdir(parents=True, exist_ok=True)
    args.suggestions_output.write_bytes(generated_suggestions)
    args.search_output.parent.mkdir(parents=True, exist_ok=True)
    args.search_output.write_bytes(generated_search)
    print(f"wrote {args.output} ({EXPECTED_EMOJI_COUNT} emoji, {len(generated)} bytes)")
    match_count = len(json.loads(generated_suggestions)["suggestions"])
    print(
        f"wrote {args.suggestions_output} "
        f"({match_count} matches, {len(generated_suggestions)} bytes)"
    )
    print(f"wrote {args.search_output} ({len(generated_search)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
