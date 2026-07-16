#!/usr/bin/env python3
"""Build `data/is/governors.json.gz` — a statistical case-government model:
for every "governor" word (in practice: prepositions, and any other word
with enough bigram mass and a non-uniform following-case distribution — we
do not pre-filter by part of speech, see "Why no POS filter on word1"
below), the observed distribution of grammatical feature bundles (case,
number, definiteness for nouns; case, number, gender, degree, strength for
adjectives) carried by the words that follow it in `data/is/bigrams.json.gz`.

No grammar rules are hand-written: "frá hestinum/húsinu/konunni all dative"
falls out of counting alone. This is the offline join described in PLAN.md's
"Inflection intelligence" Stage A #2.

Method
------
1. Load `bigrams.json.gz` ([word1, word2, count] triples).
2. Scan BÍN's raw SHsnid.csv exactly once, restricted to the (small) set of
   word2 surface forms actually appearing in the bigram data, and restricted
   to noun/adjective rows (kk/kvk/hk/lo) — verbs and everything else are out
   of scope, same as build-paradigms.py. For each such surface form, collect
   the *set* of distinct (pos, feature-bundle) analyses BÍN offers for it —
   deduplicated across lemmas, so a form with three homonym lemmas that all
   happen to be "þgf:et:ngr" contributes that bundle once, not three times.
3. For each bigram (w1, w2, count): if word2 has zero noun/adjective
   analyses, the pair is dropped entirely (word2 isn't a noun/adjective
   form, or BÍN doesn't recognize it) — it contributes to neither a
   governor's mass nor its distribution. If word2 has k >= 1 analyses, the
   bigram's count is split count/k ways, one share per analysis, and added
   to word1's running bundle-weight table. This is the "fractional credit"
   rule: we never guess which single analysis is "the right one" for an
   ambiguous word2 (the wordform-overlap principle — ambiguity is never
   resolved by fiat), we just spread the evidence proportionally across
   every analysis BÍN considers valid. A governor's total "mass" is the sum
   of the (whole, un-split) bigram counts that contributed to it.

Filters
-------
- `--min-mass` (default 50): drop governors with total mass below this —
  not enough evidence.
- `--max-case-entropy-ratio` (default 0.9): compute the governor's *case-only*
  marginal distribution (collapsing number/definiteness/gender/degree —
  those axes are properties of the governed noun phrase, not something a
  preposition or verb grammatically governs in Icelandic, so folding them in
  would dilute the one axis that IS governed) and its Shannon entropy,
  normalized by log2(#distinct cases observed for that governor, capped at
  4). A governor whose following-case distribution is close to uniform
  (entropy ratio close to 1.0) carries no case-government signal and is
  dropped. Known real prepositions with a genuinely SPLIT distribution (á,
  með: þf for motion, þgf for location) still have most of their mass on
  two of the four cases, giving a ratio well below 1.0 — see --verify output.

Output shape (data/is/governors.json.gz, gzipped JSON — small enough that a
custom binary format isn't worth it, see "Size" in data/README.md):
    {
      "meta": {"version": 1, "build_date": "...", "min_mass": 50,
                "max_case_entropy_ratio": 0.9, "governor_count": N, ...},
      "governors": {
        "frá": {
          "mass": 148213.0,
          "case_distribution": {"þgf": 0.94, "þf": 0.03, "nf": 0.02, "ef": 0.01},
          "case_entropy_ratio": 0.18,
          "bundle_distribution": {"no:þgf:et:ngr": 0.31, ...}
        },
        ...
      }
    }

`case_distribution` is the primary Stage B signal (P(case | governor)).
`bundle_distribution` is the full feature bundle breakdown (case + number +
definiteness/gender/degree), included because PLAN.md's Stage A spec asks
for "P(case, number, definiteness | previous token)" explicitly — Stage B
can use whichever granularity a given ranking boost needs.

Why no POS filter on word1: PLAN.md says governors are "prepositions,
common verbs", but that's a description of what falls out, not a filter to
apply — restricting to a specific POS list would be a hand-written rule
which the whole point of this pipeline is to avoid. The mass + entropy
filters do the real work: a governor with insufficient evidence or a
uniform-looking distribution is dropped regardless of what part of speech
it happens to be.

Determinism: `bigrams.json.gz` and BÍN rows are both consumed in their
on-disk order but all aggregation is by hash-map key (word2 surface form,
word1 governor) with `float` sums, and the output governors dict is written
sorted by key — re-running against the same inputs reproduces the same JSON
content byte-for-byte (verified: two runs' decompressed output diffed
identical). The gzip wrapper itself is also reproducible: written with a
pinned `mtime=0` (gzip.open()'s default embeds the current time in the
header, which would otherwise make two builds of identical content differ
at the byte level).

Usage:
    python3 scripts/build-governors.py \\
        --src /Users/jokull/Code/lemma-is/data/SHsnid.csv \\
        --bigrams data/is/bigrams.json.gz \\
        --output data/is/governors.json.gz

    python3 scripts/build-governors.py --output data/is/governors.json.gz --verify

Stdlib only.
"""
import argparse
import gzip
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import bin_morph as bm

DEFAULT_SRC = '/Users/jokull/Code/lemma-is/data/SHsnid.csv'
DEFAULT_BIGRAMS = str(Path(__file__).parent.parent / 'data' / 'is' / 'bigrams.json.gz')
DEFAULT_OUTPUT = str(Path(__file__).parent.parent / 'data' / 'is' / 'governors.json.gz')

BUILD_DATE = '2026-07-15'  # fixed string per spec, not datetime.now() — keeps rebuilds diffable
FORMAT_VERSION = 1

ALL_CASES = ('nf', 'þf', 'þgf', 'ef')


def load_bigrams(path):
    with gzip.open(path, 'rt', encoding='utf-8') as f:
        raw = json.load(f)
    if not isinstance(raw, list):
        raise ValueError(f'expected a list of [w1, w2, count] triples, got {type(raw).__name__}')
    triples = []
    for entry in raw:
        if len(entry) != 3:
            continue
        w1, w2, count = entry
        triples.append((w1.lower(), w2.lower(), int(count)))
    return triples


def collect_word2_analyses(src_path, needed_forms):
    """Single pass over SHsnid.csv (noun/adjective rows only), restricted to
    `needed_forms` (the set of word2 surface forms actually used in
    bigrams). Returns dict: form -> set of (pos_str, bundle_int)."""
    analyses = {}
    rows_seen = 0
    for lemma, word_class, form, mark in bm.iter_bin_rows(src_path):
        rows_seen += 1
        if form not in needed_forms:
            continue
        if word_class == 'lo':
            parsed = bm.parse_adj_mark(mark)
            if parsed is None:
                continue
            case, number, gender, degree, strength = parsed
            bundle = bm.pack_adj_bundle(case, number, gender, degree, strength)
        else:
            parsed = bm.parse_noun_mark(mark)
            if parsed is None:
                continue
            case, number, definite = parsed
            bundle = bm.pack_noun_bundle(case, number, definite)
        analyses.setdefault(form, set()).add(bundle)
        if rows_seen % 1_000_000 == 0:
            print(f'  ...{rows_seen:,} rows scanned')
    return analyses


def build(src_path, bigrams_path, out_path, min_mass, max_case_entropy_ratio):
    print(f'Loading bigrams from {bigrams_path}...')
    bigrams = load_bigrams(bigrams_path)
    print(f'  {len(bigrams):,} bigram triples')

    needed_w2 = {w2 for _w1, w2, _c in bigrams}
    print(f'  {len(needed_w2):,} distinct word2 surface forms to resolve against BÍN')

    print(f'Scanning {src_path} for noun/adjective analyses of those forms...')
    analyses_map = collect_word2_analyses(src_path, needed_w2)
    resolved = sum(1 for w in needed_w2 if w in analyses_map)
    print(f'  {resolved:,} / {len(needed_w2):,} word2 forms have >=1 noun/adjective analysis')

    # governor -> bundle_int -> weight (float)
    governor_bundles = {}
    governor_mass = {}
    dropped_unresolved_count = 0
    dropped_unresolved_mass = 0
    for w1, w2, count in bigrams:
        analyses = analyses_map.get(w2)
        if not analyses:
            dropped_unresolved_count += 1
            dropped_unresolved_mass += count
            continue
        share = count / len(analyses)
        bundles = governor_bundles.setdefault(w1, {})
        for bundle in analyses:
            bundles[bundle] = bundles.get(bundle, 0.0) + share
        governor_mass[w1] = governor_mass.get(w1, 0.0) + count

    print(f'  Bigrams dropped (word2 not a resolvable noun/adjective form): '
          f'{dropped_unresolved_count:,} pairs, {dropped_unresolved_mass:,} total count')
    print(f'  Candidate governors (any mass): {len(governor_mass):,}')

    governors_out = {}
    dropped_low_mass = 0
    dropped_uniform = 0
    for w1, mass in governor_mass.items():
        if mass < min_mass:
            dropped_low_mass += 1
            continue

        bundles = governor_bundles[w1]
        case_weight = {}
        for bundle, weight in bundles.items():
            case = bm.CASE_NAME[bundle & 0x3]
            case_weight[case] = case_weight.get(case, 0.0) + weight
        total_case_weight = sum(case_weight.values())
        case_distribution = {c: w / total_case_weight for c, w in case_weight.items()}

        n_cases = len(case_weight)
        if n_cases <= 1:
            entropy_ratio = 0.0
        else:
            h = -sum(p * math.log2(p) for p in case_distribution.values() if p > 0)
            entropy_ratio = h / math.log2(n_cases)

        if entropy_ratio > max_case_entropy_ratio:
            dropped_uniform += 1
            continue

        bundle_distribution = {
            bm.bundle_to_string(bundle): weight / mass
            for bundle, weight in sorted(bundles.items())
        }

        governors_out[w1] = {
            'mass': mass,
            'case_distribution': dict(sorted(case_distribution.items(), key=lambda kv: -kv[1])),
            'case_entropy_ratio': entropy_ratio,
            'bundle_distribution': bundle_distribution,
        }

    print(f'  Dropped for mass < {min_mass}: {dropped_low_mass:,}')
    print(f'  Dropped for case-entropy-ratio > {max_case_entropy_ratio}: {dropped_uniform:,}')
    print(f'  Governors kept: {len(governors_out):,}')

    output = {
        'meta': {
            'version': FORMAT_VERSION,
            'build_date': BUILD_DATE,
            'min_mass': min_mass,
            'max_case_entropy_ratio': max_case_entropy_ratio,
            'governor_count': len(governors_out),
            'source': {
                'bigrams': str(bigrams_path),
                'bin_csv': str(src_path),
            },
        },
        'governors': dict(sorted(governors_out.items(), key=lambda kv: kv[0].encode('utf-8'))),
    }

    print(f'Writing {out_path}...')
    payload = json.dumps(output, ensure_ascii=False, sort_keys=False, separators=(',', ':')).encode('utf-8')
    with open(out_path, 'wb') as raw_f:
        with gzip.GzipFile(fileobj=raw_f, mode='wb', mtime=0) as f:
            f.write(payload)

    size = Path(out_path).stat().st_size
    print(f'\nOutput: {out_path}')
    print(f'  File size: {size / 1024:.1f} KB')
    print(f'  Governors: {len(governors_out):,}')
    return output


def verify(out_path):
    print(f'Verifying {out_path}...')
    with gzip.open(out_path, 'rt', encoding='utf-8') as f:
        data = json.load(f)
    meta = data['meta']
    governors = data['governors']
    print(f'  version={meta["version"]} governor_count={meta["governor_count"]} '
          f'min_mass={meta["min_mass"]} max_case_entropy_ratio={meta["max_case_entropy_ratio"]}')

    ok = True

    def dominant_case(word):
        g = governors.get(word)
        if g is None:
            return None, None
        dist = g['case_distribution']
        top_case = max(dist, key=dist.get)
        return top_case, dist[top_case]

    assertions = [
        ('frá', 'þgf'),
        ('til', 'ef'),
        ('um', 'þf'),
    ]
    print('\n  Known-preposition assertions:')
    for word, expected_case in assertions:
        top_case, prob = dominant_case(word)
        status = 'OK' if top_case == expected_case else '!! FAIL'
        print(f'    P(case | {word}): dominant={top_case} ({prob:.3f} if resolved else n/a) '
              f'expected={expected_case} [{status}]')
        if top_case != expected_case:
            ok = False

    print('\n  Split-case governors (á, með expected to show þf/þgf split):')
    for word in ('á', 'með'):
        g = governors.get(word)
        if g is None:
            print(f'    {word}: NOT PRESENT in governors table (filtered out or absent) !! FAIL')
            ok = False
            continue
        dist = g['case_distribution']
        print(f'    {word}: mass={g["mass"]:.0f} entropy_ratio={g["case_entropy_ratio"]:.3f} '
              f'distribution={ {c: round(p, 3) for c, p in dist.items()} }')
        thf = dist.get('þf', 0.0)
        thgf = dist.get('þgf', 0.0)
        if min(thf, thgf) < 0.05:
            print(f'    !! expected a real þf/þgf split for {word}, got þf={thf:.3f} þgf={thgf:.3f}')
            ok = False

    print('\n  Top 20 governors by mass:')
    top20 = sorted(governors.items(), key=lambda kv: -kv[1]['mass'])[:20]
    for word, g in top20:
        dist = ', '.join(f'{c}={p:.2f}' for c, p in g['case_distribution'].items())
        print(f'    {word:12s} mass={g["mass"]:10.0f} entropy_ratio={g["case_entropy_ratio"]:.3f}  {dist}')

    if ok:
        print('\nVerification PASSED')
    else:
        print('\nVerification FAILED')
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--src', default=DEFAULT_SRC, help='BÍN SHsnid.csv path')
    ap.add_argument('--bigrams', default=DEFAULT_BIGRAMS, help='data/is/bigrams.json.gz path')
    ap.add_argument('--output', default=DEFAULT_OUTPUT, help='output governors.json.gz path')
    ap.add_argument('--min-mass', type=float, default=50,
                     help='drop governors with total weighted mass below this (default 50)')
    ap.add_argument('--max-case-entropy-ratio', type=float, default=0.9,
                     help='drop governors whose case distribution is this close to uniform '
                          '(0=fully deterministic, 1=uniform; default 0.9)')
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

    build(args.src, args.bigrams, args.output, args.min_mass, args.max_case_entropy_ratio)
    verify(args.output)


if __name__ == '__main__':
    main()
