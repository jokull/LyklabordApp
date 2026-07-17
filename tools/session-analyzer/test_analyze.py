#!/usr/bin/env python3
"""
test_analyze.py — proves the classifier on the synthetic fixture.

Run:  python3 test_analyze.py       (exit 0 = pass)

The fixture (fixtures/fixture-*.jsonl) is a hand-built session that contains
exactly one of each classifiable event, so this doubles as living documentation
of what each class looks like on the wire.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from analyze import (  # noqa: E402
    AppRecord,
    KBRecord,
    SilentMiss,
    classify,
    load_session,
    reconstruct_pairs,
    _inflection_offer,
    _silent_candidates,
    _is_junk_tier,
    detect_stale_applies,
    _substitute_first_word,
    greynir_enrich_session,
)
import greynir_enrich  # noqa: E402
import taxonomy  # noqa: E402
from taxonomy import FindingContext, classify_finding  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "fixtures", "fixture-app.jsonl")
KB = os.path.join(HERE, "fixtures", "fixture-kb.jsonl")


def run():
    app, kb = load_session(APP, KB)
    events = classify(app, kb)
    by_cls = {}
    for e in events:
        by_cls.setdefault(e.cls, []).append(e)

    def expect(cls, typo, intended):
        assert cls in by_cls, f"missing {cls}; got classes {sorted(by_cls)}"
        pair = [(e.typo, e.intended) for e in by_cls[cls]]
        assert (typo, intended) in pair, f"{cls}: expected {(typo, intended)}, got {pair}"
        print(f"  OK  {cls:18} {typo!r} -> {intended!r}")

    print("Classifier results:")
    expect("AUTOCORRECT_UNDONE", "kaffo", "kaffi")
    expect("MISS_OFFERED", "hus", "hús")
    expect("MISS_ABSENT", "kvld", "kvöld")
    expect("TAP_USED", "t", "takk")

    # MISS_OFFERED must have surfaced the offered word; MISS_ABSENT must not.
    off = by_cls["MISS_OFFERED"][0]
    assert "hús" in off.offered_bar, f"MISS_OFFERED bar should contain hús: {off.offered_bar}"
    absent = by_cls["MISS_ABSENT"][0]
    assert "kvöld" not in absent.offered_bar, "MISS_ABSENT bar must not contain kvöld"
    print("  OK  offered/absent bar discrimination")

    # Candidate shape check.
    cand = off.to_candidate()
    for key in ("typo", "intended", "context", "lang", "class"):
        assert key in cand, f"candidate missing {key}"
    assert cand["lang"] == "is", f"expected is lang for hús, got {cand['lang']}"
    print("  OK  candidate shape (matches data/eval/dev.jsonl)")

    print(f"\nPASS — {len(events)} events, all 4 classes detected.")


# --------------------------------------------------------------------------
# v2 behaviours (built in-memory — living documentation of the three upgrades)
# --------------------------------------------------------------------------

def _session(texts):
    """Build an (app, kb) pair from a list of pad-text snapshots (t = index)."""
    app = [AppRecord(t=0.0, sid="v2", kind="start", text="")]
    app += [AppRecord(t=float(i + 1), sid="v2", kind="snapshot", text=t)
            for i, t in enumerate(texts)]
    app[-1] = AppRecord(t=app[-1].t, sid="v2", kind="stop", text=texts[-1])
    return app, []


def test_erase_retype_alignment():
    """Upgrade 2: erase one word, retype a LONGER stretch. The erased word must
    pair with its plausible match, not the inserted word (the real "foðu" →
    "af góðu" bug, where v1 emitted "foðu"→"af")."""
    # Pure reconstruction (the real session's peak/end, "á" survives in `end`).
    pairs = reconstruct_pairs(
        "til að fa snefil á foðu veðri",
        "til að fa snefil á af góðu veðri",
    )
    got = [(t, i) for _, t, i in pairs]
    assert ("foðu", "góðu") in got, f"expected foðu→góðu, got {got}"
    assert all(i != "af" and t != "af" for _, t, i in pairs), \
        f"'af' must be an insertion, not a pair: {got}"

    # End-to-end through classify on a synthetic episode ("til" survives).
    app, kb = _session([
        "til f", "til fo", "til fod", "til fodu",            # peak
        "til fod", "til fo", "til f", "til ",                # erase
        "til a", "til af", "til af ", "til af g", "til af go",
        "til af god", "til af goda",                          # retype (longer)
    ])
    events = classify(app, kb)
    pairs = [(e.typo, e.intended) for e in events]
    assert ("fodu", "goda") in pairs, f"classify alignment: {pairs}"
    assert all(t != "af" and i != "af" for t, i in pairs), \
        f"'af' leaked as a pair: {pairs}"
    print("  OK  erase-retype alignment  fodu -> goda ('af' dropped)")


def test_inflection_miss():
    """Upgrade 3: a MISS whose bar offered a different inflection of the same
    stem is tagged INFLECTION_MISS (Kirkjubæjarklaustri vs -klaustur)."""
    off = _inflection_offer(
        "Kirkjubæjars", "Kirkjubæjarklaustur", ["Kirkjubæjarklaustri", "Kirkjubær"])
    assert off == "Kirkjubæjarklaustri", off
    # The typo echoed in the bar, and short-word near-typos, must NOT qualify.
    assert _inflection_offer("mew", "með", ["MEÐ", "mew", "me", "Menn"]) is None

    # End-to-end: bar offers the wrong-case inflection while typing the typo.
    app, kb = _session(["reykjaviks", "reykjavik", "reykjaviku", "reykjavikur"])
    kb = [KBRecord(t=0.5, sid="v2", window="reykjaviks", field="standard",
                   bar=[{"text": "reykjaviki"}], applied={"kind": "none"},
                   taps=[], backspaces=0)]
    events = classify(app, kb)
    infl = [e for e in events if e.cls == "INFLECTION_MISS"]
    assert infl and infl[0].intended == "reykjavikur" and infl[0].note == "reykjaviki", \
        f"expected INFLECTION_MISS reykjaviks→reykjavikur: {[(e.cls, e.typo, e.intended, e.note) for e in events]}"
    print("  OK  INFLECTION_MISS  reykjaviks -> reykjavikur (offer reykjaviki)")


def test_silent_candidates():
    """Upgrade 1: an unattested token gets ranked cheap-edit neighbours; a
    keyboard-mash token resolves to nothing (UNRESOLVABLE)."""
    common = {"hann": 3772234, "frá": 2644106, "fá": 482541,
              "síðan": 379301, "að": 34196092}
    # habb → hann via two adjacency subs (b→n, b→n).
    top = _silent_candidates("habb", common)
    assert top and top[0][0] == "hann", top
    # fra → frá via one accent edit (penalty 0, ranked first).
    top = _silent_candidates("fra", common)
    assert top and top[0][0] == "frá" and top[0][2] == 0, top
    # Keyboard mash has no cheap high-frequency neighbour.
    assert _silent_candidates("awgke", common) == [], "mash should be UNRESOLVABLE"
    print("  OK  silent-miss  habb->hann, fra->frá, mash->UNRESOLVABLE")


def test_junk_tier_attestation():
    """Regression test for the 'lss' bug: is.lex is a raw frequency table,
    not a curated dictionary, so a low-z attestation must NOT exempt a token
    from the silent-miss scan unless BÍN also validates it as a real word.
    Values below are real `type-repl :word` output from this repo's own
    session corpus (see analyze.py's `_is_junk_tier` docstring)."""
    # "lss" — the actual bug: attested in is.lex as web-noise junk (low z,
    # not BÍN-known) — must be treated as junk-tier (scan it).
    assert _is_junk_tier(is_present=True, is_z=-1.03, bin_known=False) is True
    # "gil" — a real word at the EXACT SAME z as "lss" — BÍN saves it.
    assert _is_junk_tier(is_present=True, is_z=-1.03, bin_known=True) is False
    # "hárblásara" — real word, much lower z still — BÍN saves it.
    assert _is_junk_tier(is_present=True, is_z=-2.35, bin_known=True) is False
    # "kjúklinginn" — real word just above the floor — never even junk-tier
    # regardless of BÍN (the z check alone already exempts it).
    assert _is_junk_tier(is_present=True, is_z=-0.94, bin_known=False) is False
    # Absent from is.lex entirely — not this function's concern (attest_tokens
    # gates on `is_present` before this ever matters), but must not misfire.
    assert _is_junk_tier(is_present=False, is_z=-3.55, bin_known=False) is False
    print("  OK  junk-tier attestation  lss->junk, gil/hárblásara->real (BÍN-saved)")



# --------------------------------------------------------------------------
# v3 — taxonomy classifier (known-class triage tagging, see taxonomy.py)
# --------------------------------------------------------------------------
#
# classify_finding is pure — no type-repl, no kb.jsonl — so every case below
# is hand-fed the attestation/bar facts a real session would have produced
# (verified against this repo's own `type-repl :word` output and real
# sessions/*-report.md where noted). This doubles as living documentation of
# the taxonomy's PRECEDENCE order.

def test_taxonomy_restoration_fold():
    """þvi -> því (real SILENT_MISS in 2026-07-16T22-45-30): differs only by
    an acute accent on an otherwise identical skeleton. þvi is not BÍN-known
    (typo_valid=False); því is (intended_valid=True) — but only ONE side is
    valid, so valid-word-overlap (which needs BOTH) doesn't preempt it."""
    ctx = FindingContext(
        typo="þvi", intended="því", event_cls="SILENT_MISS",
        typo_valid=False, intended_valid=True, edit_distance=1,
    )
    cls, status = classify_finding(ctx)
    assert cls == "restoration-fold", (cls, status)
    assert status == "watch"
    print("  OK  taxonomy  þvi -> því  =>  restoration-fold · watch")


def test_taxonomy_valid_word_overlap():
    """syndur -> sýndur (real SILENT_MISS in 2026-07-17T08-30-35): BOTH are
    BÍN-known real words ("syndur" = able to swim, "sýndur" = shown) — a
    doctrine non-fire, must outrank restoration-fold even though the pair is
    ALSO skeleton-equal by accent alone."""
    ctx = FindingContext(
        typo="syndur", intended="sýndur", event_cls="SILENT_MISS",
        typo_valid=True, intended_valid=True, edit_distance=1,
    )
    cls, status = classify_finding(ctx)
    assert cls == "valid-word-overlap", (cls, status)
    assert status == "accepted-gap"
    print("  OK  taxonomy  syndur -> sýndur  =>  valid-word-overlap · accepted-gap (NONFIRE)")


def test_taxonomy_compound_oov():
    """stökklrikanum -> stökkleikanum (real MISS_ABSENT in
    2026-07-16T14-59-28): intended is absent from is.lex entirely but its
    tail (minus the -anum inflection) is the attested stem "leik"."""
    ctx = FindingContext(
        typo="stökklrikanum", intended="stökkleikanum", event_cls="MISS_ABSENT",
        typo_valid=False, intended_valid=False, intended_is_lex_present=False,
        compound_hit="leik", edit_distance=1,
    )
    cls, status = classify_finding(ctx)
    assert cls == "compound-oov", (cls, status)
    assert status == "in-flight:#22"
    print("  OK  taxonomy  stökklrikanum -> stökkleikanum  =>  compound-oov · in-flight:#22")


def test_taxonomy_deep_decode():
    """eotthbap -> eitthvað (real UNRESOLVABLE in 2026-07-16T22-45-30, only
    resolvable via confirmed-intents.jsonl): 3 character substitutions
    (o/i, b/v, p/ð) is >= the deep-decode threshold, and it is NOT a
    restoration-fold (more than an accent/dental difference)."""
    ctx = FindingContext(
        typo="eotthbap", intended="eitthvað", event_cls="UNRESOLVABLE",
        typo_valid=False, intended_valid=True, intended_is_lex_present=True,
        edit_distance=3,
    )
    cls, status = classify_finding(ctx)
    assert cls == "deep-decode", (cls, status)
    assert status == "in-flight:#27"
    print("  OK  taxonomy  eotthbap -> eitthvað  =>  deep-decode · in-flight:#27")


def test_taxonomy_context_ranking():
    """The 'gret' class: the real SILENT_MISS session has "gret"'s top
    candidate resolve to "gert" (a transposition, not an accent fold) via
    `_silent_candidates`; the live kb bar for that word ALSO offered "gert"
    (at a losing rank behind "Greta") which is what actually happened in
    2026-07-16T22-45-30. Reconstructed here as a fabricated bar fixture
    (classify_finding is pure and takes no kb.jsonl) so the "bar had it but
    it was outranked" signal is exercised deterministically: edit_distance
    is only 2 (not deep-decode) and the skeletons differ (not a restoration
    fold), so context-ranking is the first class left standing."""
    ctx = FindingContext(
        typo="gret", intended="gert", event_cls="SILENT_MISS",
        bar_seen=("gret", "Greta", "gert"),
        typo_valid=False, intended_valid=True, edit_distance=2,
    )
    cls, status = classify_finding(ctx)
    assert cls == "context-ranking", (cls, status)
    assert status == "in-flight:#27"
    print("  OK  taxonomy  gret -> gert (fabricated bar)  =>  context-ranking · in-flight:#27")


def test_taxonomy_proper_noun_oov():
    """lindgren/astrid class: a capitalized, non-BÍN-known intended word
    (foreign surname) with a SHORT edit distance from the typo — short
    enough that deep-decode (which precedes proper-noun-oov) doesn't win
    the pair first."""
    ctx = FindingContext(
        typo="Lindgre", intended="Lindgren", event_cls="MISS_ABSENT",
        typo_valid=False, intended_valid=False, edit_distance=1,
    )
    cls, status = classify_finding(ctx)
    assert cls == "proper-noun-oov", (cls, status)
    assert status == "accepted-gap"
    print("  OK  taxonomy  Lindgre -> Lindgren  =>  proper-noun-oov · accepted-gap")


def test_taxonomy_slangur_intentional():
    """kozy (real SILENT_MISS in 2026-07-16T16-14-00, confirmed intentional
    in confirmed-intents.jsonl): the confirmed override wins over EVERY
    other signal, including a deep-decode-sized edit distance."""
    ctx = FindingContext(
        typo="kozy", intended="kost", event_cls="SILENT_MISS",
        edit_distance=4, confirmed={"typo": "kozy", "intentional": True},
    )
    cls, status = classify_finding(ctx)
    assert cls == "slangur-intentional", (cls, status)
    assert status == "not-error"
    print("  OK  taxonomy  kozy (confirmed intentional)  =>  slangur-intentional · not-error")


def test_taxonomy_novel():
    """A pair matching none of the detectors falls through to NOVEL —
    rendered prominently, not silently dropped."""
    ctx = FindingContext(
        typo="blorf", intended="florby", event_cls="MISS_ABSENT",
        typo_valid=False, intended_valid=False, edit_distance=2,
    )
    cls, status = classify_finding(ctx)
    assert cls == taxonomy.NOVEL_ID, (cls, status)
    print("  OK  taxonomy  blorf -> florby  =>  NOVEL")


def test_stale_apply_detection():
    """wave-28 regression watch, currently unobserved in any of this repo's
    real sessions (`git grep`-verified: no "stale-skip" applied kind exists
    yet) — this proves the detector isn't dead code by constructing the two
    positive cases directly against kb.jsonl-shaped KBRecords:
      1. an explicit `stale-skip` applied kind
      2. an autocorrect that re-applies the word already committed one pass
         back, while the bar concurrently held a DIFFERENT `ac` candidate
    and a healthy negative case (autocorrect of a genuinely new word)."""
    kb_explicit = [
        KBRecord(t=1.0, sid="s", window="hann ", field="standard",
                 bar=[], applied={"kind": "stale-skip", "text": "hann"},
                 taps=[], backspaces=0),
    ]
    assert len(detect_stale_applies(kb_explicit)) == 1

    kb_repeat = [
        KBRecord(t=1.0, sid="s", window="kaffi ", field="standard",
                 bar=[{"text": "kaffi", "ac": True}],
                 applied={"kind": "autocorrect", "text": "kaffi"},
                 taps=[], backspaces=0),
        KBRecord(t=2.0, sid="s", window="kaffi ", field="standard",
                 bar=[{"text": "kaffi", "ac": True}, {"text": "kaffe", "ac": True}],
                 applied={"kind": "autocorrect", "text": "kaffi"},
                 taps=[], backspaces=0),
    ]
    hits = detect_stale_applies(kb_repeat)
    assert len(hits) == 1 and hits[0]["applied"] == "kaffi", hits

    kb_healthy = [
        KBRecord(t=1.0, sid="s", window="kaffi ", field="standard",
                 bar=[{"text": "kaffi", "ac": True}],
                 applied={"kind": "autocorrect", "text": "kaffi"},
                 taps=[], backspaces=0),
        KBRecord(t=2.0, sid="s", window="kaffi te ", field="standard",
                 bar=[{"text": "tex", "ac": True}],
                 applied={"kind": "autocorrect", "text": "tex"},
                 taps=[], backspaces=0),
    ]
    assert detect_stale_applies(kb_healthy) == []
    print("  OK  stale-apply detection  stale-skip + repeated-autocorrect fire, "
          "healthy session stays clean")


def test_taxonomy_precedence_order():
    """PRECEDENCE sanity: valid-word-overlap must preempt restoration-fold
    when a pair is BOTH (the syndur/sýndur real case already proves this
    indirectly; this makes the ordering itself an explicit, isolated
    assertion) and slangur-intentional preempts everything, even a
    stale-apply-shaped context."""
    both_valid_and_fold = FindingContext(
        typo="thil", intended="þíl", typo_valid=True, intended_valid=True,
    )
    assert classify_finding(both_valid_and_fold)[0] == "valid-word-overlap"

    intentional_over_stale = FindingContext(
        typo="x", intended="y", applied_kind="stale-skip",
        confirmed={"typo": "x", "intentional": True},
    )
    assert classify_finding(intentional_over_stale)[0] == "slangur-intentional"
    print("  OK  taxonomy  precedence  valid-word-overlap > restoration-fold; "
          "slangur-intentional > stale-apply")


# --------------------------------------------------------------------------
# v4 — Greynir grammar-parse enrichment (see greynir_enrich.py). Pure logic
# is tested directly (fabricated parse-result dicts, no venv/reynir needed);
# the graceful-degradation path is exercised by monkeypatching
# `greynir_enrich.available`; the real reynir integration check is skipped
# cleanly when the dedicated venv isn't present.
# --------------------------------------------------------------------------

def test_greynir_vouch_decision():
    """The grammar-vouched-overlap upgrade must be conservative: intended
    must parse, and either typo fails outright or intended clearly
    outscores it (>= VOUCH_SCORE_MARGIN). A few points' difference when both
    parse cleanly must NOT vouch (this is the real syndur/sýndur case before
    the margin was calibrated: too small a gap must stay a non-fire)."""
    parsed = lambda score: {"parsed": True, "score": score, "skipped": False, "unavailable": False}
    failed = {"parsed": False, "score": 0, "skipped": False, "unavailable": False}
    unavail = {"parsed": False, "score": None, "skipped": False, "unavailable": True}

    assert greynir_enrich.vouch_decision(failed, parsed(5)) is True, \
        "intended parses, typo doesn't -> vouch"
    assert greynir_enrich.vouch_decision(parsed(4), parsed(23)) is True, \
        "clear margin (real syndur->sýndur scores: 4 vs 23) -> vouch"
    assert greynir_enrich.vouch_decision(parsed(77), parsed(80)) is False, \
        "3-point gap when both parse cleanly -> NOT a clear preference"
    assert greynir_enrich.vouch_decision(parsed(10), failed) is False, \
        "intended doesn't parse -> never vouch"
    assert greynir_enrich.vouch_decision(unavail, parsed(50)) is False, \
        "unavailable summary -> never vouch"
    print("  OK  greynir  vouch_decision  clear-margin/fail-vs-parse vouch; "
          "small-gap and unavailable don't")


def test_greynir_is_low_confidence_and_sentence_best():
    """sentence_best reduces possibly-multiple Greynir-detected sentences to
    one summary (parsed iff ALL parsed, score = the weakest link); a failed
    parse or score <= 0 is low-confidence, a healthy positive score isn't,
    and an empty/unavailable result is neither (nothing to flag)."""
    ok_a = {"text": "a", "parsed": True, "score": 60, "skipped": False}
    ok_b = {"text": "b", "parsed": True, "score": 10, "skipped": False}
    bad = {"text": "c", "parsed": False, "score": 0, "skipped": False}

    both_ok = greynir_enrich.sentence_best([ok_a, ok_b])
    assert both_ok == {"parsed": True, "score": 10, "skipped": False, "unavailable": False}
    assert greynir_enrich.is_low_confidence(both_ok) is False

    with_failure = greynir_enrich.sentence_best([ok_a, bad])
    assert with_failure["parsed"] is False
    assert greynir_enrich.is_low_confidence(with_failure) is True

    unavailable = greynir_enrich.sentence_best([])
    assert unavailable["unavailable"] is True
    assert greynir_enrich.is_low_confidence(unavailable) is False
    print("  OK  greynir  sentence_best/is_low_confidence  weakest-link "
          "reduction, failed/low-score flagged, unavailable never flagged")


def test_greynir_grammar_review_reason():
    """'foreign-token' only for a tokenizer-UNKNOWN chunk or a
    confirmed-intents `intentional` token (e.g. kozy) — NOT merely an
    accent-dropped Icelandic typo (Eg, þvi), which the tokenizer still
    classifies as an ordinary word. This is a regression test for the real
    bug this module almost shipped with (an ascii-only heuristic mislabeled
    every accent-drop typo in this repo's corpus as 'foreign-token')."""
    confirmed = {"kozy": {"typo": "kozy", "intentional": True}}
    assert greynir_enrich.grammar_review_reason(
        [{"text": "Eg", "unknown": False}, {"text": "lss", "unknown": False}],
        confirmed,
    ) == "grammar"
    assert greynir_enrich.grammar_review_reason(
        [{"text": "Eg", "unknown": False}, {"text": "kozy", "unknown": False}],
        confirmed,
    ) == "foreign-token"
    assert greynir_enrich.grammar_review_reason(
        [{"text": "Xqzwy", "unknown": True}], {},
    ) == "foreign-token"
    print("  OK  greynir  grammar_review_reason  accent-drop typo -> grammar; "
          "confirmed-intentional/UNKNOWN-token -> foreign-token")


def test_greynir_prep_case_disagreements():
    """A preposition's governed case (from Greynir's own terminal) crossed
    against the following word's INDEPENDENT BÍN case set (bin_cases) — a
    real disagreement (word attested only in a different case) is one line;
    a BÍN-unknown following word is silently skipped (not this audit's
    concern); a matching case produces nothing."""
    parsed_sentence = {
        "parsed": True,
        "terminals": [
            {"text": "á", "cat": "fs", "variants": ["þgf"]},
            {"text": "Sjónvarp", "cat": "hk", "variants": ["nf"]},
        ],
    }
    disagree = greynir_enrich.prep_case_disagreements(
        [parsed_sentence], {"Sjónvarp": ["NF", "ÞF"]})
    assert len(disagree) == 1 and "ÞGF" in disagree[0] and "Sjónvarp" in disagree[0], disagree

    agree = greynir_enrich.prep_case_disagreements(
        [parsed_sentence], {"Sjónvarp": ["ÞGF"]})
    assert agree == []

    unknown_word = greynir_enrich.prep_case_disagreements(
        [parsed_sentence], {"Sjónvarp": []})
    assert unknown_word == []
    print("  OK  greynir  prep_case_disagreements  mismatch flagged, "
          "matching/BÍN-unknown silent")


def test_greynir_substitute_first_word():
    """Word-boundary, case-insensitive, first-occurrence substitution — the
    primitive the vouch/candidate-disambiguation features use to build a
    sentence variant without needing reynir's own tokenization."""
    assert (_substitute_first_word("Þátturinn er syndur á sjónvarpi.", "syndur", "sýndur")
            == "Þátturinn er sýndur á sjónvarpi.")
    # Word-boundary: must not match "syndur" inside a longer word.
    assert _substitute_first_word("ósyndur maður", "syndur", "sýndur") is None
    # Not present at all -> None (caller falls back to a synthetic sentence).
    assert _substitute_first_word("allt annað", "syndur", "sýndur") is None
    print("  OK  greynir  _substitute_first_word  word-boundary substitution")


def test_greynir_graceful_degradation():
    """The entire enrichment must no-op cleanly (no exception, a one-line
    note) when the venv/reynir is unavailable — analyze_one's report/tags
    must be byte-identical in shape to a build with the module absent
    entirely. Monkeypatches `greynir_enrich.available` (no venv needed)."""
    real_available = greynir_enrich.available
    greynir_enrich._availability_cache.clear()
    greynir_enrich.available = lambda *a, **k: False
    try:
        app = [AppRecord(t=0.0, sid="s", kind="stop", text="syndur.")]
        m = SilentMiss(token="syndur", cls="SILENT_MISS",
                       candidates=[("sýndur", 100, 0)], context=[])
        event_tags, silent_tags = {}, {id(m): ("valid-word-overlap", "accepted-gap")}
        bundle = greynir_enrich_session(app, [], [m], event_tags, silent_tags, {})
        assert bundle["available"] is False
        assert bundle["note"] == greynir_enrich.UNAVAILABLE_NOTE
        assert bundle["grammar_review"] == []
        assert bundle["case_disagreements"] == []
        assert bundle["candidate_parses"] == {}
        # Tag must be left untouched — no upgrade possible without greynir.
        assert silent_tags[id(m)] == ("valid-word-overlap", "accepted-gap")
        print("  OK  greynir  graceful degradation  unavailable -> empty "
              "bundle + note, tags untouched, no exception")
    finally:
        greynir_enrich.available = real_available
        greynir_enrich._availability_cache.clear()


def test_greynir_vouch_upgrade_with_stubbed_batch_parse():
    """End-to-end (analyze.py's own orchestration), with `batch_parse`
    stubbed so no real reynir is needed: a valid-word-overlap SilentMiss
    whose intended-substituted sentence parses clearly better than the
    original gets upgraded to grammar-vouched-overlap IN PLACE."""
    real_available = greynir_enrich.available
    real_batch = greynir_enrich.batch_parse
    greynir_enrich._availability_cache.clear()
    greynir_enrich.available = lambda *a, **k: True

    def fake_batch_parse(sentences=(), words=(), cache_path=None,
                         venv_python=None, subprocess_timeout=60.0):
        sent_out = {}
        for s in sentences:
            score = 80 if "sýndur" in s else 4
            sent_out[s] = [{"text": s, "parsed": True, "score": score,
                            "skipped": False, "terminals": [], "tokens": []}]
        return sent_out, {w: [] for w in words}, ""

    greynir_enrich.batch_parse = fake_batch_parse
    try:
        final = "Þátturinn er syndur á sjónvarpi."
        app = [AppRecord(t=0.0, sid="s", kind="stop", text=final)]
        m = SilentMiss(token="syndur", cls="SILENT_MISS",
                       candidates=[("sýndur", 100, 0)], context=["er"])
        silent_tags = {id(m): ("valid-word-overlap", "accepted-gap")}
        bundle = greynir_enrich_session(app, [], [m], {}, silent_tags, {})
        assert bundle["available"] is True
        assert id(m) in bundle["vouched_ids"], bundle
        assert silent_tags[id(m)] == (taxonomy.GRAMMAR_VOUCHED_ID,
                                      taxonomy.status_of(taxonomy.GRAMMAR_VOUCHED_ID))
        print("  OK  greynir  vouch upgrade (stubbed batch_parse)  "
              "syndur -> sýndur  =>  grammar-vouched-overlap · watch")
    finally:
        greynir_enrich.available = real_available
        greynir_enrich.batch_parse = real_batch
        greynir_enrich._availability_cache.clear()


def test_greynir_real_integration():
    """Skipped cleanly when the dedicated venv (tools/session-analyzer/.venv)
    isn't present — otherwise actually shells out to reynir and asserts a
    known-good Icelandic sentence parses."""
    if not greynir_enrich.available():
        print("  SKIP  greynir  real integration (venv/reynir not installed "
              "— see README.md's Setup section)")
        return
    sent_out, _words, note = greynir_enrich.batch_parse(
        sentences=["Ég hef unun af því að forrita."])
    assert note == "", f"unexpected note: {note}"
    parses = sent_out.get("Ég hef unun af því að forrita.")
    assert parses, "no result for the known-good sentence"
    summary = greynir_enrich.sentence_best(parses)
    assert summary["parsed"] is True, f"expected a clean parse: {parses}"
    print(f"  OK  greynir  real integration  'Ég hef unun af því að forrita.' "
          f"parses (score {summary['score']})")


if __name__ == "__main__":
    run()
    print("\nv2 behaviours:")
    test_erase_retype_alignment()
    test_inflection_miss()
    test_silent_candidates()
    test_junk_tier_attestation()
    print("\nv3 behaviours (taxonomy classifier):")
    test_taxonomy_restoration_fold()
    test_taxonomy_valid_word_overlap()
    test_taxonomy_compound_oov()
    test_taxonomy_deep_decode()
    test_taxonomy_context_ranking()
    test_taxonomy_proper_noun_oov()
    test_taxonomy_slangur_intentional()
    test_taxonomy_novel()
    test_taxonomy_precedence_order()
    test_stale_apply_detection()
    print("\nPASS — v2 + v3 behaviours (alignment, inflection, silent-miss, "
          "taxonomy) verified.")

    print("\nv4 behaviours (Greynir enrichment, greynir_enrich.py):")
    test_greynir_vouch_decision()
    test_greynir_is_low_confidence_and_sentence_best()
    test_greynir_grammar_review_reason()
    test_greynir_prep_case_disagreements()
    test_greynir_substitute_first_word()
    test_greynir_graceful_degradation()
    test_greynir_vouch_upgrade_with_stubbed_batch_parse()
    test_greynir_real_integration()
    print("\nPASS — v4 Greynir enrichment (vouch decision, low-confidence, "
          "grammar-review reason, case audit, substitution, graceful "
          "degradation, stubbed upgrade, real integration) verified.")
