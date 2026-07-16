"""Shared BÍN morph-tag parsing + feature-bundle encoding for the inflection
intelligence pipeline (`build-paradigms.py`, `build-governors.py`).

Source data: BÍN's "Sigrúnarsnið" CSV (`SHsnid.csv`, semicolon-delimited,
columns `lemma;bin_id;word_class;domain;word_form;mark`), the same raw format
lemma-is's own `scripts/build-data.py`/`build-binary.py` read (see
`data/is/PARADIGMS_FORMAT.md` "Source data" section for where this file comes
from / how it's obtained). Only rows with `word_class` in `{kk, kvk, hk, lo}`
(nouns split by grammatical gender, and adjectives) are in v1 scope — verbs
(`so`) and everything else are a later wave.

`mark` examples seen in the data (see PARADIGMS_FORMAT.md for the full
survey):
  nouns:      "NFET", "ÞGFETgr", "EFFTgr2"  (case + number, optional "gr"
              suffix for the definite/article-suffixed form; trailing digits
              like "2"/"3" mark BÍN-internal alternate-spelling variants for
              the exact same grammatical slot and are irrelevant to parsing —
              substring matching below ignores them harmlessly)
  adjectives: "FSB-KK-NFET"   (frumstig sterk beyging = positive/strong)
              "FVB-KVK-ÞGFFT" (frumstig veik beyging  = positive/weak)
              "MST-HK-EFET"   (miðstig = comparative; BÍN gives no strong/weak
                                split for comparatives — see DEGREE below)
              "ESB-KK-NFET"   (efsta stig sterk beyging = superlative/strong)
              "EVB-KK-NFET"   (efsta stig veik beyging  = superlative/weak)

Feature-bundle encoding: a compact uint16 packed as documented in
PARADIGMS_FORMAT.md and mirrored here in BUNDLE bit-layout comments. The same
bundle also has a human-readable string form (`bundle_to_string`) used in
`governors.json` and in `--verify` reports.

Stdlib only.
"""

# --- POS ---------------------------------------------------------------
POS_NOUN = 0
POS_ADJ = 1

# --- Case (2 bits: 0-3) --------------------------------------------------
CASE_NF, CASE_ÞF, CASE_ÞGF, CASE_EF = 0, 1, 2, 3
CASE_CODE = {'nf': CASE_NF, 'þf': CASE_ÞF, 'þgf': CASE_ÞGF, 'ef': CASE_EF}
CASE_NAME = {v: k for k, v in CASE_CODE.items()}

# --- Number (1 bit) -------------------------------------------------------
NUM_ET, NUM_FT = 0, 1
NUMBER_CODE = {'et': NUM_ET, 'ft': NUM_FT}
NUMBER_NAME = {v: k for k, v in NUMBER_CODE.items()}

# --- Noun-only: definiteness (1 bit) --------------------------------------
DEF_INDEF, DEF_DEF = 0, 1
DEF_NAME = {DEF_INDEF: 'ngr', DEF_DEF: 'gr'}

# --- Adjective-only: gender (2 bits: 0-2) ---------------------------------
GENDER_KK, GENDER_KVK, GENDER_HK = 0, 1, 2
GENDER_CODE = {'kk': GENDER_KK, 'kvk': GENDER_KVK, 'hk': GENDER_HK}
GENDER_NAME = {v: k for k, v in GENDER_CODE.items()}

# --- Adjective-only: degree (2 bits: 0-2) ---------------------------------
DEGREE_FST, DEGREE_MST, DEGREE_EST = 0, 1, 2  # frumstig/miðstig/efsta stig
DEGREE_NAME = {DEGREE_FST: 'fst', DEGREE_MST: 'mst', DEGREE_EST: 'est'}

# --- Adjective-only: strength (1 bit) --------------------------------------
STRENGTH_SB, STRENGTH_VB = 0, 1  # sterk/veik beyging (strong/weak)
STRENGTH_NAME = {STRENGTH_SB: 'sb', STRENGTH_VB: 'vb'}


def parse_noun_mark(mark: str):
    """Parse a noun `mark` field -> (case_code, number_code, def_code), or
    None if the mark contains no recognizable case (defensive; should not
    happen for kk/kvk/hk rows in practice)."""
    m = mark.upper()
    if 'ÞGF' in m:
        case = CASE_ÞGF
    elif 'ÞF' in m:
        case = CASE_ÞF
    elif 'NF' in m:
        case = CASE_NF
    elif 'EF' in m:
        case = CASE_EF
    else:
        return None
    number = NUM_FT if 'FT' in m else NUM_ET
    definite = DEF_DEF if 'GR' in m else DEF_INDEF
    return (case, number, definite)


def parse_adj_mark(mark: str):
    """Parse an adjective `mark` field ->
    (case_code, number_code, gender_code, degree_code, strength_code), or
    None if unparseable.

    Comparatives (MST) carry no strong/weak distinction in BÍN (Icelandic
    comparative adjectives always decline weak); we record strength=vb for
    MST rows by convention (documented in PARADIGMS_FORMAT.md) rather than
    inventing a third strength value, so Stage B's strength axis stays
    2-valued.
    """
    m = mark.upper()
    if 'MST' in m:
        degree, strength = DEGREE_MST, STRENGTH_VB
    elif 'ESB' in m:
        degree, strength = DEGREE_EST, STRENGTH_SB
    elif 'EVB' in m:
        degree, strength = DEGREE_EST, STRENGTH_VB
    elif 'FSB' in m:
        degree, strength = DEGREE_FST, STRENGTH_SB
    elif 'FVB' in m:
        degree, strength = DEGREE_FST, STRENGTH_VB
    else:
        return None

    if 'ÞGF' in m:
        case = CASE_ÞGF
    elif 'ÞF' in m:
        case = CASE_ÞF
    elif 'NF' in m:
        case = CASE_NF
    elif 'EF' in m:
        case = CASE_EF
    else:
        return None

    number = NUM_FT if 'FT' in m else NUM_ET

    if 'KVK' in m:
        gender = GENDER_KVK
    elif 'KK' in m:
        gender = GENDER_KK
    elif 'HK' in m:
        gender = GENDER_HK
    else:
        return None

    return (case, number, gender, degree, strength)


def pack_noun_bundle(case, number, definite) -> int:
    """bits 0-1 case | bit 2 number | bit 3 pos(=0) | bit 4 definiteness."""
    return (case & 0x3) | (number & 0x1) << 2 | (POS_NOUN & 0x1) << 3 | (definite & 0x1) << 4


def pack_adj_bundle(case, number, gender, degree, strength) -> int:
    """bits 0-1 case | bit 2 number | bit 3 pos(=1) | bits 4-5 gender |
    bits 6-7 degree | bit 8 strength."""
    return (
        (case & 0x3)
        | (number & 0x1) << 2
        | (POS_ADJ & 0x1) << 3
        | (gender & 0x3) << 4
        | (degree & 0x3) << 6
        | (strength & 0x1) << 8
    )


def unpack_bundle(bundle: int):
    """Returns a dict of decoded fields; always has 'pos','case','number'.
    Adds 'definite' for nouns, 'gender'/'degree'/'strength' for adjectives."""
    case = bundle & 0x3
    number = (bundle >> 2) & 0x1
    pos = (bundle >> 3) & 0x1
    if pos == POS_NOUN:
        definite = (bundle >> 4) & 0x1
        return {'pos': 'no', 'case': CASE_NAME[case], 'number': NUMBER_NAME[number],
                'definite': DEF_NAME[definite]}
    gender = (bundle >> 4) & 0x3
    degree = (bundle >> 6) & 0x3
    strength = (bundle >> 8) & 0x1
    return {'pos': 'lo', 'case': CASE_NAME[case], 'number': NUMBER_NAME[number],
            'gender': GENDER_NAME[gender], 'degree': DEGREE_NAME[degree],
            'strength': STRENGTH_NAME[strength]}


def bundle_to_string(bundle: int) -> str:
    """Human-readable, stable string key for a feature bundle, e.g.
    'no:þgf:et:gr' or 'lo:þgf:et:kk:fst:sb'. Used in governors.json and
    --verify reports (never in paradigms.bin itself, which stores the packed
    uint16)."""
    d = unpack_bundle(bundle)
    if d['pos'] == 'no':
        return f"no:{d['case']}:{d['number']}:{d['definite']}"
    return f"lo:{d['case']}:{d['number']}:{d['gender']}:{d['degree']}:{d['strength']}"


def iter_bin_rows(src_path, word_classes=('kk', 'kvk', 'hk', 'lo')):
    """Yields (lemma_lower, word_class, form_lower, mark) for every row of
    SHsnid.csv whose word_class is in `word_classes`. Stdlib csv module,
    semicolon-delimited. Rows with fewer than 6 columns are skipped (should
    not occur in a well-formed SHsnid.csv)."""
    import csv
    with open(src_path, 'r', encoding='utf-8') as f:
        reader = csv.reader(f, delimiter=';')
        for row in reader:
            if len(row) < 6:
                continue
            lemma, _bin_id, word_class, _domain, form, mark = row[:6]
            if word_class not in word_classes:
                continue
            yield lemma.lower(), word_class, form.lower(), mark
