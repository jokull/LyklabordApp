#!/usr/bin/env python3
"""Build `data/is/paradigms.bin` — the GENERATION direction of BÍN morphology
(lemma -> every inflected surface form + its feature bundle), for nouns and
adjectives only (v1 scope; verbs are a later wave — see PARADIGMS_FORMAT.md
"Scope").

This is the mirror image of what already ships in lemma-is.bin v2 (surface
form -> lemma + morph tag, the ANALYSIS direction). Stage B (the Swift
engine, not built here) needs the other direction to answer "given this
lemma, what are all its forms?" (inflection-aware completion/prediction) and
"given this exact surface form, what feature bundle(s) can it be?" fast
(wrong-form correction, personal-lemma lift).

Usage:
    python3 scripts/build-paradigms.py \\
        --src /Users/jokull/Code/lemma-is/data/SHsnid.csv \\
        --unigrams data/is/unigrams.json.gz \\
        --output data/is/paradigms.bin

    python3 scripts/build-paradigms.py --output data/is/paradigms.bin --verify

Source data: BÍN's raw "Sigrúnarsnið" CSV (`SHsnid.csv`), NOT redistributed
in this repo (BÍN license: no raw-data redistribution — see
data/ATTRIBUTION.md). It must be present locally (as it is at
`/Users/jokull/Code/lemma-is/data/SHsnid.csv`, downloaded from
https://bin.arnastofnun.is/DMII/LTdata/data/ per lemma-is's own
`scripts/build-data.py` instructions) or re-downloaded from that URL.

Determinism: fixed sort orders throughout (lemma groups by (lemma bytes, pos,
gender); entries within a group by (bundle, form bytes); string pool
populated in that same deterministic traversal order) — re-running against
the same inputs produces a byte-identical file.

See data/is/PARADIGMS_FORMAT.md for the full binary layout, join-key
documentation, and worked examples.

Stdlib only.
"""
import argparse
import gzip
import json
import mmap
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import bin_morph as bm

MAGIC = 0x50415231  # "PAR1" little-endian bytes
VERSION = 1

DEFAULT_SRC = '/Users/jokull/Code/lemma-is/data/SHsnid.csv'
DEFAULT_UNIGRAMS = str(Path(__file__).parent.parent / 'data' / 'is' / 'unigrams.json.gz')
DEFAULT_OUTPUT = str(Path(__file__).parent.parent / 'data' / 'is' / 'paradigms.bin')

GENDER_TABLE_CODE = {'kk': 0, 'kvk': 1, 'hk': 2}  # noun lemma-group gender; 0xFF = n/a (adjectives)
ADJ_GENDER_SENTINEL = 0xFF


def load_unigram_freqs(path):
    with gzip.open(path, 'rt', encoding='utf-8') as f:
        return json.load(f)


def build(src_path, unigrams_path, out_path, min_lemma_freq):
    print(f'Loading unigram frequencies from {unigrams_path}...')
    freqs = load_unigram_freqs(unigrams_path)
    print(f'  {len(freqs):,} words')

    print(f'Reading {src_path}...')
    # (lemma, pos_code, gender_code_or_0xFF) -> set of (form, bundle)
    groups = {}
    rows_seen = 0
    rows_kept_lemma_pass = 0
    for lemma, word_class, form, mark in bm.iter_bin_rows(src_path):
        rows_seen += 1
        if freqs.get(lemma, 0) < min_lemma_freq:
            continue
        rows_kept_lemma_pass += 1
        if word_class == 'lo':
            parsed = bm.parse_adj_mark(mark)
            if parsed is None:
                continue
            case, number, gender, degree, strength = parsed
            bundle = bm.pack_adj_bundle(case, number, gender, degree, strength)
            key = (lemma, bm.POS_ADJ, ADJ_GENDER_SENTINEL)
        else:
            parsed = bm.parse_noun_mark(mark)
            if parsed is None:
                continue
            case, number, definite = parsed
            bundle = bm.pack_noun_bundle(case, number, definite)
            key = (lemma, bm.POS_NOUN, GENDER_TABLE_CODE[word_class])
        groups.setdefault(key, set()).add((form, bundle))
        if rows_seen % 1_000_000 == 0:
            print(f'  ...{rows_seen:,} rows scanned')

    print(f'  Rows scanned: {rows_seen:,}; rows passing lemma-frequency filter: {rows_kept_lemma_pass:,}')
    print(f'  Lemma groups (lemma,pos,gender) kept: {len(groups):,}')

    sorted_group_keys = sorted(groups.keys(), key=lambda k: (k[0].encode('utf-8'), k[1], k[2]))

    # --- string pool (dedup) --------------------------------------------
    pool = bytearray()
    pool_offsets = {}

    def intern(s):
        off = pool_offsets.get(s)
        if off is not None:
            return off
        off = len(pool)
        pool.extend(s.encode('utf-8'))
        pool_offsets[s] = off
        return off

    lemma_group_records = []  # (lemmaOff, lemmaLen, pos, gender, entryStart, entryCount)
    entries = []  # (lemmaGroupIdx, formOffset, formLen, bundle)

    for gi, key in enumerate(sorted_group_keys):
        lemma, pos, gender = key
        lemma_off = intern(lemma)
        lemma_len = len(lemma.encode('utf-8'))
        entry_start = len(entries)
        form_bundle_pairs = sorted(groups[key], key=lambda fb: (fb[1], fb[0].encode('utf-8')))
        for form, bundle in form_bundle_pairs:
            form_off = intern(form)
            form_len = len(form.encode('utf-8'))
            entries.append((gi, form_off, form_len, bundle))
        entry_count = len(entries) - entry_start
        lemma_group_records.append((lemma_off, lemma_len, pos, gender, entry_start, entry_count))

    while len(pool) % 4 != 0:
        pool.append(0)

    print(f'  String pool: {len(pool):,} bytes')
    print(f'  Entries: {len(entries):,}')

    # --- surface form table + permutation array -------------------------
    # Group entry indices by form string (the same form string can arise
    # from multiple lemma groups and/or multiple bundles — homographs and
    # syncretism both land here; both are legitimate and kept). Recover the
    # form string from the pool via (offset,len) rather than re-walking
    # `groups` a second time.
    form_to_entry_indices = {}
    for idx, (gi, form_off, form_len, bundle) in enumerate(entries):
        form_str = bytes(pool[form_off:form_off + form_len]).decode('utf-8')
        form_to_entry_indices.setdefault(form_str, []).append(idx)

    sorted_forms = sorted(form_to_entry_indices.keys(), key=lambda s: s.encode('utf-8'))
    surface_form_records = []  # (formOff, formLen, permStart, permCount)
    permutation = []
    for form in sorted_forms:
        idxs = sorted(form_to_entry_indices[form])  # ascending entry index, deterministic
        perm_start = len(permutation)
        permutation.extend(idxs)
        perm_count = len(idxs)
        form_off = pool_offsets[form]
        form_len = len(form.encode('utf-8'))
        surface_form_records.append((form_off, form_len, perm_start, perm_count))

    assert len(permutation) == len(entries)
    print(f'  Distinct surface forms: {len(sorted_forms):,}')

    # --- write ------------------------------------------------------------
    print(f'Writing {out_path}...')
    with open(out_path, 'wb') as f:
        header = struct.pack(
            '<IIIIIIII',
            MAGIC, VERSION, len(pool), len(lemma_group_records),
            len(entries), len(sorted_forms), min_lemma_freq, 0,
        )
        assert len(header) == 32
        f.write(header)
        f.write(bytes(pool))
        for lemma_off, lemma_len, pos, gender, entry_start, entry_count in lemma_group_records:
            f.write(struct.pack('<IBBBBII', lemma_off, lemma_len, pos, gender, 0, entry_start, entry_count))
        for gi, form_off, form_len, bundle in entries:
            f.write(struct.pack('<IIBHB', gi, form_off, form_len, bundle, 0))
        for form_off, form_len, perm_start, perm_count in surface_form_records:
            f.write(struct.pack('<IBxxxII', form_off, form_len, perm_start, perm_count))
        for idx in permutation:
            f.write(struct.pack('<I', idx))

    size = Path(out_path).stat().st_size
    print(f'\nOutput: {out_path}')
    print(f'  File size: {size / 1024 / 1024:.2f} MB')
    print(f'  Lemma groups: {len(lemma_group_records):,}')
    print(f'  Entries: {len(entries):,}')
    print(f'  Surface forms: {len(sorted_forms):,}')
    return {
        'pool': bytes(pool),
        'lemma_group_records': lemma_group_records,
        'entries': entries,
        'surface_form_records': surface_form_records,
        'sorted_forms': sorted_forms,
        'sorted_group_keys': sorted_group_keys,
    }


# ---------------------------------------------------------------------
# --verify: mmap the written file back and exercise both access patterns.
# ---------------------------------------------------------------------

class ParadigmsReader:
    def __init__(self, path):
        self._f = open(path, 'rb')
        self._mm = mmap.mmap(self._f.fileno(), 0, access=mmap.ACCESS_READ)
        (self.magic, self.version, self.pool_size, self.group_count,
         self.entry_count, self.form_count, self.min_lemma_freq, _reserved) = struct.unpack(
            '<IIIIIIII', self._mm[0:32])
        assert self.magic == MAGIC, f'bad magic {self.magic:#x}'
        assert self.version == VERSION
        off = 32
        self.pool_off = off
        off += self.pool_size
        self.group_tbl_off = off
        off += self.group_count * 16
        self.entries_off = off
        off += self.entry_count * 12
        self.form_tbl_off = off
        off += self.form_count * 16
        self.perm_off = off
        off += self.entry_count * 4
        assert off == len(self._mm), f'size mismatch: computed {off}, file {len(self._mm)}'

    def _str(self, offset, length):
        base = self.pool_off + offset
        return self._mm[base:base + length].decode('utf-8')

    def _group(self, gi):
        rec = self._mm[self.group_tbl_off + gi * 16: self.group_tbl_off + gi * 16 + 16]
        lemma_off, lemma_len, pos, gender, _pad, entry_start, entry_count = struct.unpack('<IBBBBII', rec)
        return lemma_off, lemma_len, pos, gender, entry_start, entry_count

    def _entry(self, ei):
        rec = self._mm[self.entries_off + ei * 12: self.entries_off + ei * 12 + 12]
        gi, form_off, form_len, bundle, _pad = struct.unpack('<IIBHB', rec)
        return gi, form_off, form_len, bundle

    def _bsearch_groups(self, lemma_bytes):
        lo, hi = 0, self.group_count
        while lo < hi:
            mid = (lo + hi) // 2
            lemma_off, lemma_len, *_ = self._group(mid)
            if self._str(lemma_off, lemma_len).encode('utf-8') < lemma_bytes:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def forms_of_lemma(self, lemma):
        """All (pos, gender_or_none, form, bundle) tuples for every lemma
        group matching this exact lemma spelling (may be >1: e.g. a noun
        and adjective sharing a spelling, or two genders)."""
        lemma_bytes = lemma.encode('utf-8')
        i = self._bsearch_groups(lemma_bytes)
        out = []
        while i < self.group_count:
            lemma_off, lemma_len, pos, gender, entry_start, entry_count = self._group(i)
            if self._str(lemma_off, lemma_len).encode('utf-8') != lemma_bytes:
                break
            for ei in range(entry_start, entry_start + entry_count):
                gi, form_off, form_len, bundle = self._entry(ei)
                form = self._str(form_off, form_len)
                out.append((pos, gender, form, bundle))
            i += 1
        return out

    def _form_record(self, fi):
        rec = self._mm[self.form_tbl_off + fi * 16: self.form_tbl_off + fi * 16 + 16]
        form_off, form_len, _pad1, _pad2, _pad3, perm_start, perm_count = struct.unpack('<IBBBBII', rec)
        return form_off, form_len, perm_start, perm_count

    def _bsearch_forms(self, form_bytes):
        lo, hi = 0, self.form_count
        while lo < hi:
            mid = (lo + hi) // 2
            form_off, form_len, *_ = self._form_record(mid)
            if self._str(form_off, form_len).encode('utf-8') < form_bytes:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def features_of_form(self, form):
        """All (lemma, pos, gender_or_none, bundle) analyses for this exact
        surface form string."""
        form_bytes = form.encode('utf-8')
        fi = self._bsearch_forms(form_bytes)
        if fi >= self.form_count:
            return []
        form_off, form_len, perm_start, perm_count = self._form_record(fi)
        if self._str(form_off, form_len).encode('utf-8') != form_bytes:
            return []
        out = []
        for k in range(perm_start, perm_start + perm_count):
            (ei,) = struct.unpack('<I', self._mm[self.perm_off + k * 4: self.perm_off + k * 4 + 4])
            gi, _fo, _fl, bundle = self._entry(ei)
            lemma_off, lemma_len, pos, gender, _es, _ec = self._group(gi)
            lemma = self._str(lemma_off, lemma_len)
            out.append((lemma, pos, gender, bundle))
        return out


def verify(out_path):
    print(f'Verifying {out_path}...')
    r = ParadigmsReader(out_path)
    print(f'  magic=OK version={r.version} groups={r.group_count:,} entries={r.entry_count:,} '
          f'forms={r.form_count:,} min_lemma_freq={r.min_lemma_freq}')

    ok = True

    # (a) lemma -> forms
    hestur_forms = r.forms_of_lemma('hestur')
    print(f'\n  lemma "hestur" -> {len(hestur_forms)} entries:')
    for pos, gender, form, bundle in sorted(hestur_forms, key=lambda t: t[3]):
        print(f'    {form:15s} {bm.bundle_to_string(bundle)}')
    if len(hestur_forms) != 16:
        print(f'  !! expected 16 forms for hestur (4 case x 2 number x 2 definiteness), got {len(hestur_forms)}')
        ok = False

    # (b) surface form -> features
    for probe in ('hesti', 'hestsins' if False else 'hestinum'):
        analyses = r.features_of_form(probe)
        print(f'\n  form "{probe}" -> {len(analyses)} analyses:')
        for lemma, pos, gender, bundle in analyses:
            print(f'    lemma={lemma} {bm.bundle_to_string(bundle)}')
        if not analyses:
            print(f'  !! expected at least one analysis for {probe!r}')
            ok = False

    # sanity on a known adjective
    good_forms = r.forms_of_lemma('góður')
    print(f'\n  lemma "góður" (adjective) -> {len(good_forms)} entries (expect up to 120: '
          f'4 case x 2 number x 3 gender x 5 degree/strength combos)')
    if not good_forms:
        print('  !! expected forms for góður')
        ok = False

    if ok:
        print('\nVerification PASSED')
    else:
        print('\nVerification FAILED')
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--src', default=DEFAULT_SRC, help='BÍN SHsnid.csv path')
    ap.add_argument('--unigrams', default=DEFAULT_UNIGRAMS, help='unigrams.json.gz for lemma-frequency filtering')
    ap.add_argument('--output', default=DEFAULT_OUTPUT, help='output paradigms.bin path')
    ap.add_argument('--min-lemma-freq', type=int, default=10,
                     help='keep a lemma group only if the lemma\'s unigram frequency is >= this '
                          '(default 10; tunable — see PARADIGMS_FORMAT.md "Size budget" for the '
                          'threshold sweep that picked this default)')
    ap.add_argument('--verify', action='store_true', help='verify an already-built --output file and exit')
    args = ap.parse_args()

    if args.verify:
        verify(args.output)
        return

    if not Path(args.src).exists():
        print(f'Error: {args.src} not found.')
        print('Download from https://bin.arnastofnun.is/DMII/LTdata/data/ (Sigrúnarsnið CSV) '
              'or point --src at a local copy (e.g. the lemma-is checkout).')
        sys.exit(1)

    build(args.src, args.unigrams, args.output, args.min_lemma_freq)
    verify(args.output)


if __name__ == '__main__':
    main()
