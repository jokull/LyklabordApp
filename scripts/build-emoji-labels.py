#!/usr/bin/env python3
"""Build Icelandic emoji labels and the version-aware picker/search corpus.

The source versions and hashes are deliberately pinned. Updating the corpus is
an explicit dependency upgrade, not a network-dependent build step.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import unicodedata
import urllib.request
import xml.etree.ElementTree as ET


CLDR_VERSION = "48.2"
EMOJI_VERSION = "17.0"
EXPECTED_EMOJI_COUNT = 3_944
EXPECTED_FAMILY_COUNT = 1_914
EXPECTED_RELEASE_COUNTS = {"15.1": 3_773, "16.0": 3_781, "17.0": 3_944}
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
    "englishAnnotations": (
        "https://raw.githubusercontent.com/unicode-org/cldr/"
        "release-48-2/common/annotations/en.xml",
        "8511aadd046fdba2f0ffe590266ced8bbf48175ad139b2675d85d7141057b235",
    ),
    "englishAnnotationsDerived": (
        "https://raw.githubusercontent.com/unicode-org/cldr/"
        "release-48-2/common/annotationsDerived/en.xml",
        "d76bd041c8c9e7b00b716aff8b7d9dbf509877010e191d5efd068be2553e066e",
    ),
    "emojiTest": (
        "https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt",
        "1d8a944f88d7952f7ef7c5167fef3c67995bcae24543949710231b03a201acda",
    ),
    "emojiTest15_1": (
        "https://www.unicode.org/Public/emoji/15.1/emoji-test.txt",
        "d876ee249aa28eaa76cfa6dfaa702847a8d13b062aa488d465d0395ee8137ed9",
    ),
    "emojiTest16": (
        "https://www.unicode.org/Public/emoji/16.0/emoji-test.txt",
        "24f0c534e86cf142e2496953e8f0e46a3e702392911eddcd29c6cced85139697",
    ),
}

GROUP_TITLES = {
    "Smileys & Emotion": "Smileys & People",
    "People & Body": "Smileys & People",
    "Animals & Nature": "Animals & Nature",
    "Food & Drink": "Food & Drink",
    "Activities": "Activity",
    "Travel & Places": "Travel & Places",
    "Objects": "Objects",
    "Symbols": "Symbols",
    "Flags": "Flags",
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


def parse_emoji_test(document: bytes) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    group = ""
    subgroup = ""
    for line in document.decode("utf-8").splitlines():
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            continue
        if line.startswith("# subgroup:"):
            subgroup = line.split(":", 1)[1].strip()
            continue
        if "; fully-qualified" not in line:
            continue
        codepoints = line.split(";", 1)[0].strip().split()
        comment = line.split("#", 1)[1].strip().split(" ", 2)
        if len(comment) != 3 or group not in GROUP_TITLES:
            raise RuntimeError(f"malformed Emoji Test row: {line}")
        result.append({
            "emoji": "".join(chr(int(value, 16)) for value in codepoints),
            "group": group,
            "subgroup": subgroup,
            "name": comment[2],
        })
    return result


def contains_skin_tone(emoji: str) -> bool:
    return any("\U0001f3fb" <= char <= "\U0001f3ff" for char in emoji)


def family_name(record: dict[str, str]) -> str:
    name = record["name"]
    if "skin tone" in name and ":" in name:
        return name.split(":", 1)[0]
    return name


def build_catalog(
    records: list[dict[str, str]],
    release_records: dict[str, list[dict[str, str]]],
) -> tuple[bytes, list[dict[str, object]]]:
    release_keys = {
        version: {lookup_key(record["emoji"]) for record in values}
        for version, values in release_records.items()
    }
    for version, expected in EXPECTED_RELEASE_COUNTS.items():
        actual = len(release_records[version])
        if actual != expected:
            raise RuntimeError(
                f"Emoji {version} count changed: expected {expected}, got {actual}"
            )

    families_by_key: dict[tuple[str, str, str], dict[str, object]] = {}
    ordered_families: list[dict[str, object]] = []
    for record in records:
        key = (record["group"], record["subgroup"], family_name(record))
        family = families_by_key.get(key)
        if family is None:
            family = {
                "title": GROUP_TITLES[record["group"]],
                "base": None,
                "variants": [],
            }
            families_by_key[key] = family
            ordered_families.append(family)
        emoji = record["emoji"]
        normalized = lookup_key(emoji)
        tier = (
            0 if normalized in release_keys["15.1"]
            else 1 if normalized in release_keys["16.0"]
            else 2
        )
        family["variants"].append([emoji, tier])
        if not contains_skin_tone(emoji):
            if family["base"] is not None:
                raise RuntimeError(f"duplicate base for emoji family {key}")
            family["base"] = emoji

    if len(ordered_families) != EXPECTED_FAMILY_COUNT:
        raise RuntimeError(
            f"Emoji family count changed: expected {EXPECTED_FAMILY_COUNT}, "
            f"got {len(ordered_families)}"
        )
    missing_bases = [family for family in ordered_families if family["base"] is None]
    if missing_bases:
        raise RuntimeError(f"emoji families without a base: {len(missing_bases)}")

    categories: list[dict[str, object]] = []
    for title in dict.fromkeys(GROUP_TITLES.values()):
        category_families = [
            {"base": family["base"], "variants": family["variants"]}
            for family in ordered_families
            if family["title"] == title
        ]
        categories.append({"title": title, "families": category_families})

    artifact = {
        "schema": 1,
        "emojiVersion": EMOJI_VERSION,
        "sequenceCount": len(records),
        "familyCount": len(ordered_families),
        "releaseTiers": [
            {"emojiVersion": "15.1", "minimumIOS": "18.0", "tier": 0},
            {"emojiVersion": "16.0", "minimumIOS": "18.4", "tier": 1},
            {"emojiVersion": "17.0", "minimumIOS": "26.4", "tier": 2},
        ],
        "sources": {
            name: {"url": SOURCES[name][0], "sha256": SOURCES[name][1]}
            for name in ("emojiTest15_1", "emojiTest16", "emojiTest")
        },
        "categories": categories,
    }
    result = (json.dumps(artifact, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    return result, ordered_families


def build() -> tuple[bytes, bytes, bytes, bytes]:
    annotations = parse_annotations([fetch("annotations"), fetch("annotationsDerived")])
    english_annotations = parse_annotations([
        fetch("englishAnnotations"),
        fetch("englishAnnotationsDerived"),
    ])
    emoji_records = parse_emoji_test(fetch("emojiTest"))
    if len(emoji_records) != EXPECTED_EMOJI_COUNT:
        raise RuntimeError(
            f"Emoji {EMOJI_VERSION} count changed: expected {EXPECTED_EMOJI_COUNT}, "
            f"got {len(emoji_records)}"
        )
    catalog_bytes, families = build_catalog(
        emoji_records,
        {
            "15.1": parse_emoji_test(fetch("emojiTest15_1")),
            "16.0": parse_emoji_test(fetch("emojiTest16")),
            "17.0": emoji_records,
        },
    )

    entries = []
    missing = []
    for record in emoji_records:
        emoji = record["emoji"]
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
        "sources": {
            name: {"url": SOURCES[name][0], "sha256": SOURCES[name][1]}
            for name in ("annotations", "annotationsDerived", "emojiTest")
        },
        "entries": entries,
    }
    corpus_bytes = (
        json.dumps(corpus, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode()
    entries_by_key = {lookup_key(str(entry["emoji"])): entry for entry in entries}
    return (
        corpus_bytes,
        build_suggestions(families, entries_by_key),
        build_search(families, entries_by_key, english_annotations),
        catalog_bytes,
    )


def normalized_term(value: str) -> str:
    return unicodedata.normalize("NFC", value.strip()).lower()


def search_tokens(value: str) -> list[str]:
    return re.findall(r"[^\W_]+(?:-[^\W_]+)*", normalized_term(value), flags=re.UNICODE)


def token_field(values: list[str]) -> str:
    tokens: list[str] = []
    for value in values:
        tokens.extend(search_tokens(value))
    return "|" + "|".join(dict.fromkeys(tokens)) + "|"


def keyword_field(values: list[str]) -> str:
    if any("|" in value or value.startswith("#") for value in values):
        raise RuntimeError("search term contains reserved field delimiter")
    tokens = token_field(values).removesuffix("|")
    phrases = [f"#{value}" for value in values if len(search_tokens(value)) > 1]
    return tokens + ("|" + "|".join(phrases) if phrases else "") + "|"


def bilingual_name_field(icelandic_name: str, english_name: str) -> str:
    if "|" in english_name or english_name.startswith("#"):
        raise RuntimeError("English emoji name contains reserved field delimiter")
    return token_field([icelandic_name, english_name]).removesuffix("|") + f"|#{english_name}|"


def build_search(
    families: list[dict[str, object]],
    entries_by_key: dict[str, dict[str, object]],
    english_annotations: dict[str, dict[str, object]],
) -> bytes:
    """Emit the compact version-aware Icelandic + English search corpus."""
    rows: list[list[str]] = []
    token_postings: dict[str, set[int]] = {}

    for family in families:
        emoji = str(family["base"])
        entry = entries_by_key[lookup_key(emoji)]
        english = english_annotations.get(lookup_key(emoji))
        if english is None or not english["name"]:
            raise RuntimeError(f"CLDR {CLDR_VERSION} lacks English label for {emoji}")
        name = normalized_term(str(entry["name"]))
        english_name = normalized_term(str(english["name"]))
        keywords = list(dict.fromkeys(
            normalized_term(str(value))
            for value in [*entry["keywords"], *english["keywords"]]
            if normalized_term(str(value))
            and normalized_term(str(value)) != name
            and normalized_term(str(value)) != english_name
        ))
        row_index = len(rows)
        base_variant = next(value for value in family["variants"] if value[0] == emoji)
        rows.append([
            emoji,
            name,
            bilingual_name_field(name, english_name),
            keyword_field(keywords),
            str(base_variant[1]),
        ])
        tokens = set(search_tokens(name) + search_tokens(english_name))
        for keyword in keywords:
            tokens.update(search_tokens(keyword))
        for token in tokens:
            token_postings.setdefault(token, set()).add(row_index)

    posting_count = sum(len(postings) for postings in token_postings.values())
    expected = (1_914, 7_202, 18_350)
    actual = (len(rows), len(token_postings), posting_count)
    if actual != expected:
        raise RuntimeError(f"search metrics changed: expected {expected}, got {actual}")

    artifact = {
        "schema": 6,
        "locales": ["is", "en"],
        "cldrVersion": CLDR_VERSION,
        "emojiVersion": EMOJI_VERSION,
        "catalogSchema": 1,
        "emojiCount": len(rows),
        "tokenCount": len(token_postings),
        "postingCount": posting_count,
        "sources": {
            name: {"url": SOURCES[name][0], "sha256": SOURCES[name][1]}
            for name in (
                "annotations",
                "annotationsDerived",
                "englishAnnotations",
                "englishAnnotationsDerived",
            )
        },
        # Conventional unqualified matches where CLDR intentionally assigns
        # the same generic keyword to a family (e.g. every coloured heart).
        "strongMatches": {"hjarta": "❤️", "heart": "❤️"},
        # Positional row: emoji, Icelandic display name, compact bilingual name
        # field, keyword field, then availability tier. Multiword exact names
        # are #marked in the compact field, avoiding a retained English-name
        # Swift string per emoji in the constrained extension.
        "entries": rows,
    }
    result = (json.dumps(artifact, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    if len(result) >= 300_000:
        raise RuntimeError(f"search artifact exceeds 300KB gate: {len(result)} bytes")
    return result


def build_suggestions(
    families: list[dict[str, object]],
    entries_by_key: dict[str, dict[str, object]],
) -> bytes:
    """Emit the small, conservative exact-match index shipped in the appex."""
    base_entries = [
        (family, entries_by_key[lookup_key(str(family["base"]))])
        for family in families
    ]

    names: dict[str, set[tuple[str, int]]] = {}
    keywords: dict[str, set[tuple[str, int]]] = {}
    for family, entry in base_entries:
        emoji = str(family["base"])
        tier = int(next(value[1] for value in family["variants"] if value[0] == emoji))
        candidate = (emoji, tier)
        name = normalized_term(str(entry["name"]))
        if name and " " not in name:
            names.setdefault(name, set()).add(candidate)
        for raw_keyword in entry["keywords"]:
            keyword = normalized_term(str(raw_keyword))
            if keyword and " " not in keyword:
                keywords.setdefault(keyword, set()).add(candidate)

    suggestions: dict[str, tuple[str, int]] = {}
    for term, candidates in names.items():
        if len(candidates) == 1:
            suggestions[term] = next(iter(candidates))
    for term, candidates in keywords.items():
        if term not in suggestions and len(candidates) == 1:
            suggestions[term] = next(iter(candidates))

    # CLDR applies the generic keyword to every coloured/decorated heart.
    # The conventional strong match in ordinary Icelandic text is red heart.
    overrides = {"hjarta": ("❤️", 0)}
    for term, emoji in overrides.items():
        suggestions[term] = emoji

    if (
        lookup_key(suggestions.get("hjarta", ("", 0))[0]) != lookup_key("❤️")
        or lookup_key(suggestions.get("kaffi", ("", 0))[0]) != lookup_key("☕")
    ):
        raise RuntimeError("required Icelandic emoji suggestion smoke checks failed")

    artifact = {
        "schema": 2,
        "locale": "is",
        "cldrVersion": CLDR_VERSION,
        "emojiVersion": EMOJI_VERSION,
        "match": "exact-single-token",
        "count": len(suggestions),
        "suggestions": {
            term: [emoji, tier]
            for term, (emoji, tier) in sorted(suggestions.items())
        },
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
        "--catalog-output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "data/emoji/catalog.json",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if the generated bytes differ from the existing output",
    )
    args = parser.parse_args()
    generated, generated_suggestions, generated_search, generated_catalog = build()
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
        catalog_ok = (
            args.catalog_output.exists()
            and args.catalog_output.read_bytes() == generated_catalog
        )
        if not corpus_ok:
            print(f"out of date: {args.output}", file=sys.stderr)
        if not suggestions_ok:
            print(f"out of date: {args.suggestions_output}", file=sys.stderr)
        if not search_ok:
            print(f"out of date: {args.search_output}", file=sys.stderr)
        if not catalog_ok:
            print(f"out of date: {args.catalog_output}", file=sys.stderr)
        if not corpus_ok or not suggestions_ok or not search_ok or not catalog_ok:
            return 1
        match_count = len(json.loads(generated_suggestions)["suggestions"])
        print(
            f"ok: {args.output} ({EXPECTED_EMOJI_COUNT} emoji); "
            f"{args.suggestions_output} ({match_count} matches); "
            f"{args.search_output} ({len(generated_search)} bytes); "
            f"{args.catalog_output} ({len(generated_catalog)} bytes)"
        )
        return 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(generated)
    args.suggestions_output.parent.mkdir(parents=True, exist_ok=True)
    args.suggestions_output.write_bytes(generated_suggestions)
    args.search_output.parent.mkdir(parents=True, exist_ok=True)
    args.search_output.write_bytes(generated_search)
    args.catalog_output.parent.mkdir(parents=True, exist_ok=True)
    args.catalog_output.write_bytes(generated_catalog)
    print(f"wrote {args.output} ({EXPECTED_EMOJI_COUNT} emoji, {len(generated)} bytes)")
    match_count = len(json.loads(generated_suggestions)["suggestions"])
    print(
        f"wrote {args.suggestions_output} "
        f"({match_count} matches, {len(generated_suggestions)} bytes)"
    )
    print(f"wrote {args.search_output} ({len(generated_search)} bytes)")
    print(f"wrote {args.catalog_output} ({len(generated_catalog)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
