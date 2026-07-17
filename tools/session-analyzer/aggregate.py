#!/usr/bin/env python3
"""
aggregate.py — roll every analyzed DEV-MODE session in a directory up into one
cross-session report, GROUPED BY ENGINE BUILD, and maintain the append-only
personal eval corpus.

Stdlib only. Run directly:

    python3 aggregate.py [SESSIONS_DIR]      # default: ./sessions

or import and call `build(sessions_dir)` (ingest.py does this after pulling new
sessions). Reads, per session id in the directory:

    <id>-app.jsonl   authoritative pad timeline   (required)
    <id>-kb.jsonl    keyboard passes              (optional)
    <id>-meta.json   provenance manifest          (optional; groups by build)

and re-derives every event via analyze.py (single source of truth for the
classifier), so the aggregate never drifts from the per-session reports.

Outputs (all inside SESSIONS_DIR, which is gitignored — they carry typed text):

    AGGREGATE.md     human-readable: per-build totals + rates, weighted per-key
                     tap-offset table, PATTERNS (tuning candidates + watch list),
                     build-over-build trend, PENDING-REVIEW.
    aggregate.json   the same, machine-readable.

and, in this tool's own directory (also gitignored — typed text):

    personal-eval.jsonl  confirmed unambiguous candidates in data/eval/dev.jsonl
                         schema, deduped + append-only, with provenance. This is
                         a first-class TUNING GATE: ambiguous cases stay OUT
                         (listed under PENDING-REVIEW) pending confirmation.
"""

import json
import os
import sys
from collections import defaultdict

import analyze
import taxonomy

CORRECTOR_CLASSES = ("AUTOCORRECT_UNDONE", "MISS_OFFERED", "MISS_ABSENT")
PROVENANCE_SOURCE = "session-pipeline"


# --------------------------------------------------------------------------
# Category classifier (mirrors data/eval/dev.jsonl `category` values so the
# personal corpus and the seeded corpus speak the same language).
# --------------------------------------------------------------------------

_ACCENT_BASE = str.maketrans({
    "á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ý": "y",
    "ð": "d", "þ": "t", "æ": "a", "ö": "o",
    "Á": "A", "É": "E", "Í": "I", "Ó": "O", "Ú": "U", "Ý": "Y",
    "Ð": "D", "Þ": "T", "Æ": "A", "Ö": "O",
})


def _strip_accents(s: str) -> str:
    return s.translate(_ACCENT_BASE)


def categorize(typo: str, intended: str) -> str:
    """Best-effort edit category shared with the seeded eval corpus."""
    t, w = typo.lower(), intended.lower()
    if not t or not w or t == w:
        return "other"
    if "'" in t or "'" in w or "'" in t:
        return "contraction_damage"
    if " " in t or " " in w:
        return "space_miss"
    if _strip_accents(t) == _strip_accents(w) and t != w:
        return "accent_drop"
    if len(t) == len(w):
        if sorted(t) == sorted(w):
            return "transposition"
        return "substitution"
    if abs(len(t) - len(w)) == 1:
        shorter, longer = (t, w) if len(t) < len(w) else (w, t)
        # Gemination: the extra char in `longer` duplicates its neighbour.
        for i in range(len(longer)):
            if longer[: i] + longer[i + 1:] == shorter:
                if i > 0 and longer[i] == longer[i - 1]:
                    return "gemination"
                if i + 1 < len(longer) and longer[i] == longer[i + 1]:
                    return "gemination"
                # typo missing a char that intended has → deletion (in the typo)
                return "deletion" if len(t) < len(w) else "insertion"
    return "substitution"


# --------------------------------------------------------------------------
# Per-session metrics
# --------------------------------------------------------------------------

def _load_meta(directory: str, sid: str) -> dict:
    path = os.path.join(directory, f"{sid}-meta.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (json.JSONDecodeError, OSError):
        return {}


def _uncontested_silent(sm) -> bool:
    """A SILENT_MISS is corpus-eligible only when its top guess is a single
    cheap edit (penalty 0) and clearly beats the runner-up (no other penalty-0
    rival, or >= 3x its frequency). Everything else is PENDING-REVIEW."""
    c = sm.candidates
    if not c:
        return False
    top = c[0]
    if top[2] != 0:
        return False
    if len(c) == 1:
        return True
    second = c[1]
    if second[2] > 0:
        return True
    return top[1] >= 3 * second[1]


def analyze_session(directory: str, sid: str, repo_root: str,
                    confirmed_intents: dict = None) -> dict:
    """Re-derive everything the aggregate needs for one session."""
    app_path = os.path.join(directory, f"{sid}-app.jsonl")
    kb_path = os.path.join(directory, f"{sid}-kb.jsonl")
    app, kb = analyze.load_session(app_path, kb_path)
    events = analyze.classify(app, kb)
    silent, silent_source = analyze.silent_miss_scan(app, repo_root)
    meta = _load_meta(directory, sid)

    event_tags, silent_tags, tag_source = analyze.tag_findings(
        events, kb, silent, repo_root, confirmed_intents)
    stale_applies = analyze.detect_stale_applies(kb)
    lane, lane_source = analyze.lane_timeline(app, repo_root)
    whiplash = sum(1 for e in lane if e["whiplash"])
    # Greynir enrichment (optional — degrades gracefully): upgrades
    # valid-word-overlap -> grammar-vouched-overlap IN PLACE in event_tags/
    # silent_tags, so the top-gaps rollup below sees it for free. Cache-backed
    # (see greynir_enrich.py), so this is a no-op subprocess-wise once
    # analyze.py's own per-session pass has already populated the cache.
    greynir = analyze.greynir_enrich_session(
        app, events, silent, event_tags, silent_tags, confirmed_intents)

    counts = defaultdict(int)
    for e in events:
        counts[e.cls] += 1
    autocorrects_fired = sum(
        1 for r in kb if r.applied.get("kind") == "autocorrect")
    taps = sum(len(r.taps) for r in kb)
    committed = analyze.committed_word_count(app)
    silent_miss = sum(1 for m in silent if m.cls == "SILENT_MISS")
    unresolvable = sum(1 for m in silent if m.cls == "UNRESOLVABLE")

    # Per-key tap-offset raw sums (for weighted merge across sessions).
    offsets = {}
    for r in kb:
        for tap in r.taps:
            c = tap.get("c", "")
            s = offsets.setdefault(c, {"n": 0, "sx": 0.0, "sy": 0.0})
            s["n"] += 1
            s["sx"] += tap.get("dx", 0.0)
            s["sy"] += tap.get("dy", 0.0)

    return {
        "sid": sid,
        "build": meta.get("engineCommit", "unknown"),
        "meta": meta,
        "committed_words": committed,
        "autocorrects_fired": autocorrects_fired,
        "counts": dict(counts),
        "taps": taps,
        "silent_miss": silent_miss,
        "unresolvable": unresolvable,
        "silent_source": silent_source,
        "events": events,
        "silent": silent,
        "offsets": offsets,
        "event_tags": event_tags,
        "silent_tags": silent_tags,
        "tag_source": tag_source,
        "stale_applies": stale_applies,
        "whiplash": whiplash,
        "lane_source": lane_source,
        "greynir": greynir,
    }


# --------------------------------------------------------------------------
# Aggregation
# --------------------------------------------------------------------------

def _rate(num: int, den: int) -> float:
    return round(num / den, 4) if den else 0.0


def _build_totals(sessions: list) -> dict:
    """Sum a list of per-session metric dicts into build-level totals + rates."""
    t = {
        "sessions": len(sessions),
        "committed_words": 0,
        "autocorrects_fired": 0,
        "autocorrect_undone": 0,
        "miss_offered": 0,
        "miss_absent": 0,
        "inflection_miss": 0,
        "taps_used": 0,
        "silent_miss": 0,
        "unresolvable": 0,
        "taps": 0,
    }
    for s in sessions:
        c = s["counts"]
        t["committed_words"] += s["committed_words"]
        t["autocorrects_fired"] += s["autocorrects_fired"]
        t["autocorrect_undone"] += c.get("AUTOCORRECT_UNDONE", 0)
        t["miss_offered"] += c.get("MISS_OFFERED", 0)
        t["miss_absent"] += c.get("MISS_ABSENT", 0)
        t["inflection_miss"] += c.get("INFLECTION_MISS", 0)
        t["taps_used"] += c.get("TAP_USED", 0)
        t["silent_miss"] += s["silent_miss"]
        t["unresolvable"] += s["unresolvable"]
        t["taps"] += s["taps"]
    cw = t["committed_words"]
    t["rates"] = {
        # False-positive rate: of the autocorrects that fired, how many the
        # user undid. THE overcorrection instrument.
        "autocorrect_false_positive": _rate(t["autocorrect_undone"], t["autocorrects_fired"]),
        "miss_offered_per_word": _rate(t["miss_offered"], cw),
        "miss_absent_per_word": _rate(t["miss_absent"], cw),
        "inflection_miss_per_word": _rate(t["inflection_miss"], cw),
        "silent_miss_per_word": _rate(t["silent_miss"], cw),
        "taps_per_session": round(t["taps"] / len(sessions), 2) if sessions else 0.0,
    }
    return t


def _merge_offsets(sessions: list) -> dict:
    acc = {}
    for s in sessions:
        for c, o in s["offsets"].items():
            a = acc.setdefault(c, {"n": 0, "sx": 0.0, "sy": 0.0})
            a["n"] += o["n"]
            a["sx"] += o["sx"]
            a["sy"] += o["sy"]
    out = {}
    for c, a in acc.items():
        n = a["n"]
        out[c] = {"count": n, "mean_dx": a["sx"] / n, "mean_dy": a["sy"] / n}
    return out


def _collect_candidates(sessions: list) -> list:
    """Every corrector-class candidate across all sessions, with category +
    provenance. INFLECTION_MISS is kept separate (inflection backlog)."""
    out = []
    for s in sessions:
        for e in s["events"]:
            if e.cls not in CORRECTOR_CLASSES and e.cls != "INFLECTION_MISS":
                continue
            typo, intended = e.typo, e.intended
            if not typo or not intended or typo == intended:
                continue
            out.append({
                "typo": typo,
                "intended": intended,
                "context": list(e.context),
                "lang": analyze.guess_lang(intended or typo),
                "category": categorize(typo, intended),
                "class": e.cls,
                "session": s["sid"],
                "engine_commit": s["build"],
                "note": e.note,
            })
    return out


def _patterns(candidates: list) -> dict:
    """Group candidates into tuning candidates (>=2 occurrences of the same
    typo->intended pair, OR >=2 of the same category) vs. a singles watch list."""
    by_pair = defaultdict(list)
    by_category = defaultdict(int)
    for c in candidates:
        if c["class"] == "INFLECTION_MISS":
            continue
        key = (c["typo"].lower(), c["intended"].lower())
        by_pair[key].append(c)
        by_category[c["category"]] += 1
    tuning, watch = [], []
    for (typo, intended), items in sorted(by_pair.items(), key=lambda kv: -len(kv[1])):
        rec = {
            "typo": items[0]["typo"],
            "intended": items[0]["intended"],
            "category": items[0]["category"],
            "count": len(items),
            "sessions": sorted({i["session"] for i in items}),
            "classes": sorted({i["class"] for i in items}),
        }
        (tuning if len(items) >= 2 else watch).append(rec)
    category_hist = dict(sorted(by_category.items(), key=lambda kv: -kv[1]))
    return {"tuning": tuning, "watch": watch, "category_hist": category_hist}


# --------------------------------------------------------------------------
# Personal eval corpus (append-only, deduped, with provenance)
# --------------------------------------------------------------------------

def _corpus_key(typo: str, intended: str) -> tuple:
    return (typo.lower(), intended.lower())


def _seed_for(sid: str) -> int:
    """Deterministic provenance seed from the session date (yyyymmdd)."""
    digits = "".join(ch for ch in sid[:10] if ch.isdigit())
    return int(digits) if digits else 0


# load_confirmed_intents lives in taxonomy.py now (it's the taxonomy's own
# slangur-intentional / user-confirmed-correction data source); re-exported
# here for backward compat with any existing callers of aggregate.*.
load_confirmed_intents = taxonomy.load_confirmed_intents


def update_personal_eval(corpus_path: str, sessions: list,
                         intents: dict = None) -> dict:
    """Append confirmed, unambiguous candidates to the personal eval corpus.

    Eligible (unambiguous intended word):
      * AUTOCORRECT_UNDONE / MISS_OFFERED / MISS_ABSENT — a directly observed
        typo->correction pair (the user themselves produced the intended word).
      * SILENT_MISS — only when the top guess is UNCONTESTED (see
        `_uncontested_silent`); the synthesized intended is that guess.
      * any silent token with a user-confirmed intent (confirmed-intents.jsonl)
        — including UNRESOLVABLE mashes the candidate scan gave up on.
    Held back to PENDING-REVIEW (returned, not written):
      * INFLECTION_MISS — belongs in the inflection backlog, not the corrector.
      * SILENT_MISS with a contested/absent top guess and no confirmed intent.
    """
    if intents is None:
        intents = load_confirmed_intents()
    existing = {}
    if os.path.exists(corpus_path):
        with open(corpus_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                existing[_corpus_key(rec.get("typo", ""), rec.get("intended", ""))] = rec

    added = []
    pending = []  # ambiguous → surfaced in AGGREGATE.md, never written to corpus

    for s in sessions:
        for e in s["events"]:
            if e.cls in CORRECTOR_CLASSES:
                key = _corpus_key(e.typo, e.intended)
                if not e.typo or not e.intended or e.typo == e.intended:
                    continue
                if key in existing:
                    continue
                rec = {
                    "typo": e.typo,
                    "intended": e.intended,
                    "context": list(e.context),
                    "lang": analyze.guess_lang(e.intended or e.typo),
                    "category": categorize(e.typo, e.intended),
                    "seed": _seed_for(s["sid"]),
                    "class": e.cls,
                    "source": PROVENANCE_SOURCE,
                    "session": s["sid"],
                    "engine_commit": s["build"],
                }
                existing[key] = rec
                added.append(rec)
            elif e.cls == "INFLECTION_MISS":
                pending.append({
                    "typo": e.typo, "intended": e.intended,
                    "reason": "inflection backlog (bar offered wrong inflection: "
                              f"`{e.note}`)" if e.note else "inflection backlog",
                    "session": s["sid"],
                })
        for m in s["silent"]:
            override = intents.get(m.token.lower())
            if override is not None:
                if override.get("intentional"):
                    continue
                intended = override.get("intended", "")
                if not intended or intended.lower() == m.token.lower():
                    continue
                key = _corpus_key(m.token, intended)
                if key in existing:
                    continue
                rec = {
                    "typo": m.token,
                    "intended": intended,
                    "context": list(m.context),
                    "lang": analyze.guess_lang(intended),
                    "category": categorize(m.token, intended),
                    "seed": _seed_for(s["sid"]),
                    "class": m.cls,
                    "source": "user-confirmed",
                    "session": s["sid"],
                    "engine_commit": s["build"],
                }
                existing[key] = rec
                added.append(rec)
                continue
            if m.cls != "SILENT_MISS":
                continue
            top = m.candidates[0]
            if _uncontested_silent(m):
                key = _corpus_key(m.token, top[0])
                if key in existing:
                    continue
                rec = {
                    "typo": m.token,
                    "intended": top[0],
                    "context": list(m.context),
                    "lang": analyze.guess_lang(top[0]),
                    "category": categorize(m.token, top[0]),
                    "seed": _seed_for(s["sid"]),
                    "class": "SILENT_MISS",
                    "source": PROVENANCE_SOURCE,
                    "session": s["sid"],
                    "engine_commit": s["build"],
                }
                existing[key] = rec
                added.append(rec)
            else:
                parses = s.get("greynir", {}).get("candidate_parses", {}).get(id(m))
                parse_map = dict(parses) if parses else {}
                guesses = ", ".join(
                    f"{w}(p{p})" + (
                        "[parses]" if parse_map.get(w) else "[fails]"
                        if w in parse_map else ""
                    )
                    for w, _f, p in m.candidates[:3]
                )
                pending.append({
                    "typo": m.token, "intended": (top[0] if m.candidates else "?"),
                    "reason": f"SILENT_MISS contested top guess ({guesses})",
                    "session": s["sid"],
                })

    # Rewrite the corpus (existing + newly added), stable-sorted for a clean diff.
    rows = sorted(existing.values(),
                  key=lambda r: (r.get("intended", ""), r.get("typo", "")))
    with open(corpus_path, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")

    return {"total": len(rows), "added": added, "pending": pending}


# --------------------------------------------------------------------------
# Top-gaps rollup (the next-wave queue) — every taxonomy-tagged finding
# across ALL sessions, bucketed by class. This is the roadmap input, so it
# renders as the FIRST section of AGGREGATE.md.
# --------------------------------------------------------------------------

def _collect_tagged_findings(sessions: list, confirmed_intents: dict = None) -> list:
    """Every taxonomy-tagged finding (event + silent-miss + stale-apply)
    across all sessions, flattened to {typo, intended, class, status,
    session} for the top-gaps rollup."""
    confirmed_intents = confirmed_intents or {}
    out = []
    for s in sessions:
        for e in s["events"]:
            cls, status = s["event_tags"].get(
                id(e), (taxonomy.NOVEL_ID, taxonomy.status_of(taxonomy.NOVEL_ID)))
            out.append({"typo": e.typo, "intended": e.intended,
                       "class": cls, "status": status, "session": s["sid"]})
        for m in s["silent"]:
            cls, status = s["silent_tags"].get(
                id(m), (taxonomy.NOVEL_ID, taxonomy.status_of(taxonomy.NOVEL_ID)))
            intended = analyze.silent_intended(m, confirmed_intents) or "?"
            out.append({"typo": m.token, "intended": intended,
                       "class": cls, "status": status, "session": s["sid"]})
        for sa in s.get("stale_applies", []):
            out.append({"typo": sa.get("prev") or "?", "intended": sa.get("applied", ""),
                       "class": "stale-apply", "status": taxonomy.status_of("stale-apply"),
                       "session": s["sid"]})
    return out


def _trend_arrow(latest_count: int, latest_n: int, prior_count: int, prior_n: int) -> str:
    """Rising/flat/falling by comparing the latest-3-sessions rate to the
    rate over every session before that. No prior sessions to compare
    against -> anything present now reads as rising (there's no baseline to
    call it flat against)."""
    if latest_n == 0:
        return "—"
    latest_rate = latest_count / latest_n
    if prior_n == 0:
        return "rising ↑" if latest_count > 0 else "flat →"
    prior_rate = prior_count / prior_n
    if prior_rate == 0:
        return "rising ↑" if latest_rate > 0 else "flat →"
    ratio = latest_rate / prior_rate
    if ratio > 1.2:
        return "rising ↑"
    if ratio < 0.8:
        return "falling ↓"
    return "flat →"


def _top_gaps(sessions: list, tagged: list) -> dict:
    """Bucket every tagged finding by class across ALL sessions. `sessions`
    is chronological (session ids are UTC timestamps); "latest 3" is the
    tail. NOVEL and any recurrence of a `fixed:` status sort first, then by
    count in the latest 3 sessions. Doctrine non-fires (slangur-intentional,
    valid-word-overlap) are excluded from the ranked rows and reported as a
    separate visible count."""
    ordered_sids = [s["sid"] for s in sessions]
    latest3 = set(ordered_sids[-3:])
    prior_sids = set(ordered_sids[:-3])

    by_class = defaultdict(list)
    for f in tagged:
        by_class[f["class"]].append(f)

    rows = []
    for cls, items in by_class.items():
        if cls in taxonomy.DOCTRINE_NONFIRE_CLASSES:
            continue
        status = items[0]["status"]
        total = len(items)
        latest_n = sum(1 for f in items if f["session"] in latest3)
        prior_n = total - latest_n
        example = items[0]
        rows.append({
            "class": cls, "status": status, "total": total,
            "latest3": latest_n, "prior": prior_n,
            "example": f"{example['typo']} → {example['intended']}",
            "trend": _trend_arrow(latest_n, len(latest3), prior_n, len(prior_sids)),
            "is_novel": cls == taxonomy.NOVEL_ID,
            "is_regression": taxonomy.is_regression_status(status),
        })

    rows.sort(key=lambda r: (
        0 if r["is_novel"] else 1,
        0 if r["is_regression"] else 1,
        -r["latest3"],
        -r["total"],
    ))

    nonfires = defaultdict(int)
    for f in tagged:
        if f["class"] in taxonomy.DOCTRINE_NONFIRE_CLASSES:
            nonfires[f["class"]] += 1

    return {"rows": rows, "nonfires": dict(nonfires),
           "latest3_sessions": sorted(latest3), "prior_sessions": sorted(prior_sids)}


def render_top_gaps(gaps: dict) -> list:
    L = []
    L.append("## Top gaps (next-wave queue)")
    L.append("")
    L.append(f"Latest 3 sessions: {', '.join(gaps['latest3_sessions']) or '_none_'}"
             f"  ·  prior: {len(gaps['prior_sessions'])} session(s)")
    L.append("")
    if gaps["rows"]:
        L.append("| class | status | total | latest-3 | trend | example |")
        L.append("|-------|--------|-------|----------|-------|---------|")
        for r in gaps["rows"]:
            flag = "  ⚠ REGRESSION" if r["is_regression"] else ""
            L.append(f"| `{r['class']}` | {r['status']}{flag} | {r['total']} | "
                     f"{r['latest3']} | {r['trend']} | `{r['example']}` |")
    else:
        L.append("_no tagged findings yet_")
    L.append("")
    nf = gaps["nonfires"]
    nf_str = "  ·  ".join(f"{cls}: {n}" for cls, n in nf.items()) if nf else "none"
    L.append(f"**Doctrine non-fires** (excluded from the ranking above, still "
             f"visible): {nf_str}")
    L.append("")
    return L


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

def _fmt_rate(x: float) -> str:
    return f"{x:.3f}"


def render_markdown(by_build: dict, overall: dict, offsets: dict, patterns: dict,
                    trend: list, corpus: dict, gaps: dict = None) -> str:
    L = []
    L.append("# Session aggregate")
    L.append("")
    L.append(f"- sessions: {overall['sessions']}  ·  committed words: "
             f"{overall['committed_words']}  ·  builds: {len(by_build)}")
    L.append(f"- personal eval corpus: {corpus['total']} rows "
             f"(+{len(corpus['added'])} this run)")
    L.append("")
    L.append("> This file lives in the gitignored `sessions/` dir because it "
             "quotes real typed text. See README.md for the workflow.")
    L.append("")

    if gaps is not None:
        L.extend(render_top_gaps(gaps))

    L.append("## Totals & rates by engine build")
    L.append("")
    for build in _sorted_builds(by_build, trend):
        t = by_build[build]
        r = t["rates"]
        L.append(f"### build `{build}` — {t['sessions']} session(s), "
                 f"{t['committed_words']} words")
        L.append("")
        L.append(f"- autocorrects fired: {t['autocorrects_fired']}  ·  undone "
                 f"(false positives): {t['autocorrect_undone']}  ·  "
                 f"**false-positive rate: {_fmt_rate(r['autocorrect_false_positive'])}**")
        L.append(f"- MISS_OFFERED: {t['miss_offered']} "
                 f"({_fmt_rate(r['miss_offered_per_word'])}/word)  ·  "
                 f"MISS_ABSENT: {t['miss_absent']} "
                 f"({_fmt_rate(r['miss_absent_per_word'])}/word)")
        L.append(f"- INFLECTION_MISS: {t['inflection_miss']} "
                 f"({_fmt_rate(r['inflection_miss_per_word'])}/word)  ·  "
                 f"SILENT_MISS: {t['silent_miss']} "
                 f"({_fmt_rate(r['silent_miss_per_word'])}/word)  ·  "
                 f"UNRESOLVABLE: {t['unresolvable']}")
        L.append(f"- suggestion taps: {t['taps_used']}  ·  taps/session: "
                 f"{r['taps_per_session']}")
        L.append("")

    L.append("## Build-over-build trend (anti-overcorrection instrument)")
    L.append("")
    L.append("| build | sessions | words | FP rate | MISS_OFF/w | MISS_ABS/w | "
             "INFL/w | SILENT/w |")
    L.append("|-------|----------|-------|---------|-----------|-----------|"
             "--------|----------|")
    for build in trend:
        t = by_build[build]
        r = t["rates"]
        L.append(f"| `{build}` | {t['sessions']} | {t['committed_words']} | "
                 f"{_fmt_rate(r['autocorrect_false_positive'])} | "
                 f"{_fmt_rate(r['miss_offered_per_word'])} | "
                 f"{_fmt_rate(r['miss_absent_per_word'])} | "
                 f"{_fmt_rate(r['inflection_miss_per_word'])} | "
                 f"{_fmt_rate(r['silent_miss_per_word'])} |")
    L.append("")
    L.append("_Read down a column: a newer build that raises FP rate or the "
             "MISS rates on real typing is overcorrecting — regression signal._")
    L.append("")

    L.append("## Patterns (tuning candidates)")
    L.append("")
    if patterns["tuning"]:
        L.append("Same `typo → intended` pair seen in >= 2 sessions/occurrences "
                 "— highest-value fixes:")
        L.append("")
        L.append("| typo | intended | category | count | classes | sessions |")
        L.append("|------|----------|----------|-------|---------|----------|")
        for p in patterns["tuning"]:
            L.append(f"| `{p['typo']}` | `{p['intended']}` | {p['category']} | "
                     f"{p['count']} | {', '.join(p['classes'])} | "
                     f"{len(p['sessions'])} |")
    else:
        L.append("_No pair recurred yet — everything is on the watch list below._")
    L.append("")
    L.append("### Category histogram (same-class signal)")
    L.append("")
    if patterns["category_hist"]:
        for cat, n in patterns["category_hist"].items():
            flag = "  ← tuning class" if n >= 2 else ""
            L.append(f"- {cat}: {n}{flag}")
    else:
        L.append("_none_")
    L.append("")
    L.append("### Watch list (single occurrences)")
    L.append("")
    if patterns["watch"]:
        for p in patterns["watch"]:
            L.append(f"- `{p['typo']}` → `{p['intended']}` ({p['category']}, "
                     f"{', '.join(p['classes'])})")
    else:
        L.append("_none_")
    L.append("")

    L.append("## Personal eval corpus")
    L.append("")
    L.append(f"`personal-eval.jsonl` now holds **{corpus['total']}** confirmed, "
             f"unambiguous rows (append-only, deduped). Added this run: "
             f"{len(corpus['added'])}.")
    if corpus["added"]:
        L.append("")
        for r in corpus["added"]:
            L.append(f"- `{r['typo']}` → `{r['intended']}` "
                     f"({r['category']}, {r['class']}, {r['session']})")
    L.append("")
    L.append("This corpus is a first-class tuning GATE: a build change must not "
             "regress these confirmed cases.")
    L.append("")

    L.append("## PENDING-REVIEW (ambiguous — not in the corpus)")
    L.append("")
    if corpus["pending"]:
        L.append("These need Jökull's confirmation before they can gate tuning:")
        L.append("")
        for p in corpus["pending"]:
            L.append(f"- `{p['typo']}` → `{p['intended']}` — {p['reason']} "
                     f"({p['session']})")
    else:
        L.append("_none_")
    L.append("")

    L.append("## Weighted per-key tap offsets (all sessions)")
    L.append("")
    if offsets:
        L.append("| key | count | mean dx | mean dy |")
        L.append("|-----|-------|---------|---------|")
        for c in sorted(offsets):
            o = offsets[c]
            L.append(f"| `{c}` | {o['count']} | {o['mean_dx']:+.3f} | "
                     f"{o['mean_dy']:+.3f} |")
    else:
        L.append("_no tap samples_")
    L.append("")
    return "\n".join(L)


def _sorted_builds(by_build: dict, trend: list) -> list:
    return trend if trend else sorted(by_build)


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------

def build(sessions_dir: str, corpus_path: str = None) -> dict:
    """Aggregate every session in `sessions_dir`; write AGGREGATE.md,
    aggregate.json (both in `sessions_dir`) and personal-eval.jsonl (in this
    tool's dir by default). Returns the machine-readable summary dict."""
    repo_root = analyze._repo_root()
    if corpus_path is None:
        corpus_path = os.path.join(os.path.dirname(__file__), "personal-eval.jsonl")
    ids = analyze.discover_sessions(sessions_dir)
    confirmed_intents = taxonomy.load_confirmed_intents()
    sessions = [analyze_session(sessions_dir, sid, repo_root, confirmed_intents)
               for sid in ids]

    by_build_sessions = defaultdict(list)
    for s in sessions:
        by_build_sessions[s["build"]].append(s)
    by_build = {b: _build_totals(sl) for b, sl in by_build_sessions.items()}
    overall = _build_totals(sessions) if sessions else _build_totals([])

    # Trend order: builds sorted by the earliest session id they contain (session
    # ids are UTC timestamps, so lexical sort == chronological).
    trend = sorted(by_build_sessions,
                   key=lambda b: min(s["sid"] for s in by_build_sessions[b]))

    offsets = _merge_offsets(sessions)
    candidates = _collect_candidates(sessions)
    patterns = _patterns(candidates)
    corpus = update_personal_eval(corpus_path, sessions, confirmed_intents)

    tagged = _collect_tagged_findings(sessions, confirmed_intents)
    gaps = _top_gaps(sessions, tagged)

    summary = {
        "overall": {k: v for k, v in overall.items()},
        "by_build": by_build,
        "trend": trend,
        "patterns": patterns,
        "tap_offsets": offsets,
        "top_gaps": gaps,
        "personal_eval": {
            "path": os.path.relpath(corpus_path, repo_root),
            "total": corpus["total"],
            "added": corpus["added"],
            "pending": corpus["pending"],
        },
        "session_ids": ids,
        "sessions": [
            {"sid": s["sid"], "build": s["build"], "whiplash": s["whiplash"],
             "lane_source": s["lane_source"], "stale_applies": len(s["stale_applies"])}
            for s in sessions
        ],
    }

    md = render_markdown(by_build, overall, offsets, patterns, trend, corpus, gaps)
    with open(os.path.join(sessions_dir, "AGGREGATE.md"), "w", encoding="utf-8") as fh:
        fh.write(md)
    with open(os.path.join(sessions_dir, "aggregate.json"), "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=2)
    return summary


def main(argv: list) -> int:
    sessions_dir = argv[1] if len(argv) > 1 else os.path.join(
        os.path.dirname(__file__), "sessions")
    if not os.path.isdir(sessions_dir):
        print(f"No such sessions dir: {sessions_dir}", file=sys.stderr)
        return 1
    summary = build(sessions_dir)
    o = summary["overall"]
    print(f"Aggregated {o['sessions']} session(s) across {len(summary['by_build'])} "
          f"build(s) → AGGREGATE.md, aggregate.json")
    print(f"Personal eval corpus: {summary['personal_eval']['total']} rows "
          f"(+{len(summary['personal_eval']['added'])}), "
          f"{len(summary['personal_eval']['pending'])} pending review")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
