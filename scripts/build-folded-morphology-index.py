#!/usr/bin/env python3
"""Build the mmap-able folded BÍN reverse index.

The sidecar maps an accent-stripped word key to one or more word-form ids in
the matching ``bin-morph.bin`` artifact. Canonical strings are not duplicated:
the runtime resolves ids through BinaryLemmatizer's existing word-form pool.

Only single-token Icelandic-alphabet forms whose spelling actually changes
when combining marks are removed are indexed. This keeps the sidecar scoped to
diacritic restoration rather than turning all of BÍN into a fuzzy dictionary.

Usage:
    python3 scripts/build-folded-morphology-index.py \
        --morphology data/is/bin-morph.bin \
        --include-forms-from data/is/bin-morph.core.bin \
        --out data/is/bin-morph.folded.bin
"""

import argparse
import re
import struct
import unicodedata
from collections import defaultdict
from pathlib import Path

MORPH_MAGIC = 0x4C45_4D41  # "LEMA"
MAGIC = 0x4642_4931  # "FBI1"
VERSION = 1
WORD_RE = re.compile(r"^[a-zþðæöáéíóúý]+$")


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def align4(value: int) -> int:
    return (value + 3) & ~3


def fold_accents(word: str) -> str:
    decomposed = unicodedata.normalize("NFD", word)
    stripped = "".join(
        char for char in decomposed if unicodedata.category(char) != "Mn"
    )
    return unicodedata.normalize("NFC", stripped)


def morphology_fingerprint(path: Path) -> int:
    """O(1)-at-runtime structural identity for one morphology cohort."""
    data = path.read_bytes()
    if len(data) < 32 or u32(data, 0) != MORPH_MAGIC:
        raise ValueError(f"{path}: not a bin-morph artifact")
    values = (
        u32(data, 8),   # string pool bytes
        u32(data, 12),  # lemmas
        u32(data, 16),  # word forms
        u32(data, 20),  # entries
        u32(data, 24),  # bigrams
        len(data),
    )
    fingerprint = 14_695_981_039_346_656_037
    for byte in struct.pack("<6Q", *values):
        fingerprint ^= byte
        fingerprint = (fingerprint * 1_099_511_628_211) & 0xFFFF_FFFF_FFFF_FFFF
    return fingerprint


def read_word_forms(path: Path):
    data = path.read_bytes()
    if len(data) < 32 or u32(data, 0) != MORPH_MAGIC:
        raise ValueError(f"{path}: not a bin-morph artifact")

    string_pool_size = u32(data, 8)
    lemma_count = u32(data, 12)
    word_form_count = u32(data, 16)

    string_pool_offset = 32
    lemma_offsets_offset = string_pool_offset + string_pool_size
    lemma_lengths_offset = lemma_offsets_offset + lemma_count * 4
    word_offsets_offset = align4(lemma_lengths_offset + lemma_count)
    word_lengths_offset = word_offsets_offset + word_form_count * 4

    if word_lengths_offset + word_form_count > len(data):
        raise ValueError(f"{path}: truncated word-form sections")

    for word_id in range(word_form_count):
        pool_offset = u32(data, word_offsets_offset + word_id * 4)
        length = data[word_lengths_offset + word_id]
        start = string_pool_offset + pool_offset
        yield word_form_count, word_id, data[start : start + length].decode("utf-8")


def build(morphology: Path, out: Path, include_forms_from: Path | None = None) -> None:
    source_artifact_fingerprint = morphology_fingerprint(morphology)
    included_forms = None
    if include_forms_from is not None:
        included_forms = {word.lower() for _, _, word in read_word_forms(include_forms_from)}

    groups = defaultdict(list)
    source_word_form_count = 0
    indexed_forms = 0

    for source_word_form_count, word_id, raw_word in read_word_forms(morphology):
        word = raw_word.lower()
        if included_forms is not None and word not in included_forms:
            continue
        if not WORD_RE.fullmatch(word):
            continue
        folded = fold_accents(word)
        if folded == word:
            continue
        groups[folded].append(word_id)
        indexed_forms += 1

    keys = sorted(groups, key=lambda value: value.encode("utf-8"))
    key_pool = bytearray()
    key_offsets = []
    key_lengths = []
    value_offsets = [0]
    word_ids = []

    collision_keys = 0
    for key in keys:
        encoded = key.encode("utf-8")
        if len(encoded) > 255:
            raise ValueError(f"folded key exceeds u8 length: {key!r}")
        key_offsets.append(len(key_pool))
        key_lengths.append(len(encoded))
        key_pool.extend(encoded)
        ids = groups[key]
        if len(ids) > 1:
            collision_keys += 1
        word_ids.extend(ids)
        value_offsets.append(len(word_ids))

    while len(key_pool) % 4:
        key_pool.append(0)

    header = struct.pack(
        "<8I",
        MAGIC,
        VERSION,
        len(keys),
        len(word_ids),
        len(key_pool),
        source_word_form_count,
        source_artifact_fingerprint & 0xFFFF_FFFF,
        source_artifact_fingerprint >> 32,
    )

    payload = bytearray(header)
    payload.extend(key_pool)
    payload.extend(struct.pack(f"<{len(key_offsets)}I", *key_offsets))
    payload.extend(bytes(key_lengths))
    while len(payload) % 4:
        payload.append(0)
    payload.extend(struct.pack(f"<{len(value_offsets)}I", *value_offsets))
    payload.extend(struct.pack(f"<{len(word_ids)}I", *word_ids))

    out.parent.mkdir(parents=True, exist_ok=True)
    temporary = out.with_suffix(out.suffix + ".tmp")
    temporary.write_bytes(payload)
    temporary.replace(out)

    print(
        f"wrote {out}: {len(keys):,} folded keys, {indexed_forms:,} forms, "
        f"{collision_keys:,} collision keys, {len(payload):,} bytes; "
        f"source forms={source_word_form_count:,}, "
        f"fingerprint={source_artifact_fingerprint:016x}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--morphology", required=True, type=Path)
    parser.add_argument("--include-forms-from", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    build(args.morphology, args.out, args.include_forms_from)


if __name__ == "__main__":
    main()
