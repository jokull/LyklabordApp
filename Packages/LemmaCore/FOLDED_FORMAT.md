# Folded morphology sidecar format (v1)

Produced by `scripts/build-folded-morphology-index.py` and read by
`FoldedMorphologyIndex`. The sidecar belongs to one exact `bin-morph.bin`
cohort and maps accent-stripped keys to the canonical artifact's word-form
ids. It never duplicates canonical strings or morphology entries.

## Header

Eight little-endian `u32` values (32 bytes):

| Offset | Field |
|---:|---|
| 0 | magic `0x46424931` (`FBI1`) |
| 4 | version (`1`) |
| 8 | folded key count |
| 12 | word-form reference count |
| 16 | padded folded-key pool size |
| 20 | source `bin-morph.bin` word-form count |
| 24 | source morphology structural fingerprint, low 32 bits |
| 28 | source morphology structural fingerprint, high 32 bits |

## Sections

1. Concatenated UTF-8 folded-key pool, padded to four bytes.
2. Key offsets (`keyCount × u32`).
3. Key byte lengths (`keyCount × u8`), padded to four bytes.
4. Reference range offsets (`(keyCount + 1) × u32`).
5. Source word-form ids (`referenceCount × u32`).

Keys are sorted by raw UTF-8 bytes. A binary search resolves a key; its two
range offsets select all canonical word-form ids sharing that folded key.
Only letter-only forms containing a removable combining mark are included,
so this is a diacritic-recovery index rather than a general fuzzy BÍN index.

The shipping build additionally passes `--include-forms-from
data/is/bin-morph.core.bin`: the 350k core tier selects which canonical
surfaces receive reverse keys, while every stored id still belongs to the
full `bin-morph.bin`. The header therefore records the full artifact's
3,698,020-form cohort. Before attaching the sidecar, the reader verifies both
that count and an O(1) FNV-1a structural fingerprint over every source-header
count plus the source artifact's byte size. This catches stale or cross-cohort
pairings without reading the full mmap into resident memory.
