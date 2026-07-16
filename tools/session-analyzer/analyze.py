#!/usr/bin/env python3
"""
analyze.py — merge a DEV-MODE typing session's app + keyboard timelines and
classify autocorrect-quality events into eval-ready candidates.

Stdlib only. Run:

    python3 analyze.py [SESSIONS_DIR]     # default: ./sessions

For every `<id>-app.jsonl` (+ optional `<id>-kb.jsonl`) pair it writes, next
to the inputs:

    <id>-report.md         human-readable: counts, event list w/ context,
                           per-key tap-offset stats
    <id>-candidates.jsonl  one {typo,intended,context,lang,class} per line,
                           shaped like data/eval/dev.jsonl so events drop
                           straight into the eval corpus / scenarios.

Event classes
-------------
AUTOCORRECT_UNDONE  keyboard auto-applied a correction, user backspaced to
                    restore the word they originally typed (a false autocorrect).
MISS_OFFERED        user backspace-retyped to a word that WAS in the bar at
                    typing time — the correction was available but not applied
                    (gating too conservative).
MISS_ABSENT         user backspace-retyped to a word the bar never offered
                    (a ranking / candidate-generation miss).
TAP_USED            user tapped a suggestion in the bar.
CLEAN               a word committed with no correction, retype, or tap.

The app timeline (full pad text snapshots with timestamps) is authoritative;
the kb log supplies what the engine offered/applied and the touch samples.
"""

import json
import os
import sys
from dataclasses import dataclass, field
from typing import Optional


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------

@dataclass
class AppRecord:
    t: float
    sid: str
    kind: str   # start | snapshot | stop
    text: str


@dataclass
class KBRecord:
    t: float
    sid: str
    window: str
    field: str
    bar: list          # [{text, ac, vb, rs, conf}]
    applied: dict       # {kind: none|autocorrect|tap, text}
    taps: list          # [{c, dx, dy}]
    backspaces: int


def _read_jsonl(path: str) -> list:
    out = []
    if not os.path.exists(path):
        return out
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def load_session(app_path: str, kb_path: str):
    app = [
        AppRecord(t=r.get("t", 0.0), sid=r.get("sid", ""),
                  kind=r.get("kind", "snapshot"), text=r.get("text", ""))
        for r in _read_jsonl(app_path)
    ]
    kb = [
        KBRecord(
            t=r.get("t", 0.0), sid=r.get("sid", ""),
            window=r.get("window", ""), field=r.get("field", "standard"),
            bar=r.get("bar", []), applied=r.get("applied", {"kind": "none"}),
            taps=r.get("taps", []), backspaces=r.get("backspaces", 0))
        for r in _read_jsonl(kb_path)
    ]
    app.sort(key=lambda r: r.t)
    kb.sort(key=lambda r: r.t)
    return app, kb


# --------------------------------------------------------------------------
# Text helpers
# --------------------------------------------------------------------------

def common_prefix_len(a: str, b: str) -> int:
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


def first_word(s: str) -> str:
    """First whitespace-delimited word of `s` (leading space tolerated)."""
    return s.strip().split(" ", 1)[0].split("\n", 1)[0] if s.strip() else ""


def words(s: str) -> list:
    return [w for w in s.replace("\n", " ").split(" ") if w]


IS_LETTERS = set("áéíóúýðþæöÁÉÍÓÚÝÐÞÆÖ")


def guess_lang(word: str) -> str:
    return "is" if any(ch in IS_LETTERS for ch in word) else "en"


# --------------------------------------------------------------------------
# Episode detection (erase-then-retype on the app timeline)
# --------------------------------------------------------------------------

@dataclass
class Episode:
    t: float        # time of the peak (before backspacing began)
    end_t: float    # time the retyped text settled
    peak: str       # text right before backspacing began
    trough: str     # shortest text during the episode
    end: str        # text after retyping settled


def find_episodes(states: list) -> list:
    """`states` is the ordered list of AppRecord. An episode is a maximal
    run where the text length first strictly decreases (backspacing) then
    non-decreases (retyping), ending when growth settles."""
    episodes = []
    texts = [s.text for s in states]
    i = 1
    n = len(texts)
    while i < n:
        if len(texts[i]) < len(texts[i - 1]):
            peak = texts[i - 1]
            peak_t = states[i - 1].t
            # descend to the trough (through consecutive non-increases)
            j = i
            while j + 1 < n and len(texts[j + 1]) <= len(texts[j]):
                j += 1
            trough = texts[j]
            # ascend through retyping (consecutive non-decreases)
            k = j
            while k + 1 < n and len(texts[k + 1]) >= len(texts[k]):
                k += 1
            end = texts[k]
            if end != peak and trough != peak:
                episodes.append(
                    Episode(t=peak_t, end_t=states[k].t, peak=peak, trough=trough, end=end))
            i = k + 1
        else:
            i += 1
    return episodes


# --------------------------------------------------------------------------
# Classification
# --------------------------------------------------------------------------

@dataclass
class Event:
    cls: str
    t: float
    typo: str
    intended: str
    context: list = field(default_factory=list)
    offered_bar: list = field(default_factory=list)

    def to_candidate(self) -> dict:
        return {
            "typo": self.typo,
            "intended": self.intended,
            "context": self.context,
            "lang": guess_lang(self.intended or self.typo),
            "class": self.cls,
        }


def _autocorrect_for(kb: list, word: str, before_t: float, after_t: float) -> bool:
    """Was `word` auto-applied by the keyboard between after_t and before_t?"""
    for r in kb:
        if after_t <= r.t <= before_t and r.applied.get("kind") == "autocorrect":
            if r.applied.get("text") == word:
                return True
    return False


def _committed_part(window: str) -> str:
    """The window minus its trailing partial word (keeps the trailing space)."""
    return window[: len(window) - len(last_word(window))]


def _pass_is_typing(r: KBRecord, typo: str, prefix: str) -> bool:
    """Whether kb pass `r` happened while the user was typing the word `typo`
    at the position whose committed text is `prefix` (`ep.peak[:ws]`). Its
    window tail must be a prefix of typo AND its committed part must be a suffix
    of `prefix` — the latter pins the word POSITION so a same-prefix earlier
    word (e.g. "k…" of "kaffi") isn't mistaken for a later one (e.g. "kvld").
    Suffix comparison is used (not word counts) so it survives the kb log's
    40-char window truncation."""
    tail = last_word(r.window).lower()
    if not tail:
        return False
    typo_l = typo.lower()
    if not (typo_l.startswith(tail) or tail.startswith(typo_l)):
        return False
    wc = _committed_part(r.window)
    if prefix == "":
        return wc.strip() == ""
    return wc.strip() != "" and prefix.endswith(wc)


def _bar_offered(kb: list, typo: str, intended: str, before_t: float, prefix: str) -> bool:
    """Did any bar shown while typing `typo` contain `intended`?"""
    for r in kb:
        if r.t > before_t:
            continue
        if _pass_is_typing(r, typo, prefix):
            for b in r.bar:
                if b.get("text") == intended:
                    return True
    return False


def last_word(window: str) -> str:
    ws = words(window)
    return ws[-1] if ws else ""


def classify(app: list, kb: list) -> list:
    """Return the ordered list of Events for a session."""
    events: list = []

    # Only text-bearing states (start has empty text but is a valid anchor).
    states = [r for r in app if r.kind in ("start", "snapshot", "stop")]
    episodes = find_episodes(states)

    prev_t = states[0].t if states else 0.0
    for ep in episodes:
        pl = common_prefix_len(ep.peak, ep.end)
        # Expand the divergence point back to the start of the word it lands
        # in, so typo/intended are whole words (a shared stem like "kaff" in
        # kaffo/kaffi must not be split off).
        ws = pl
        while ws > 0 and ep.peak[ws - 1] not in (" ", "\n"):
            ws -= 1
        prefix = ep.peak[:ws]
        typo = first_word(ep.peak[ws:])
        intended = first_word(ep.end[ws:])
        if not typo or not intended or typo == intended:
            prev_t = ep.t
            continue
        context = words(prefix)[-4:]

        if _autocorrect_for(kb, typo, before_t=ep.end_t, after_t=prev_t):
            # The wrong correction is `typo`; the restored original is `intended`.
            events.append(Event("AUTOCORRECT_UNDONE", ep.t, typo, intended, context))
        else:
            offered = _bar_offered(kb, typo, intended, before_t=ep.t, prefix=prefix)
            cls = "MISS_OFFERED" if offered else "MISS_ABSENT"
            bar_texts = _bar_texts_while_typing(kb, typo, ep.t, prefix)
            events.append(Event(cls, ep.t, typo, intended, context, bar_texts))
        prev_t = ep.t

    # Suggestion taps (from the kb log directly).
    for idx, r in enumerate(kb):
        if r.applied.get("kind") == "tap":
            tapped = r.applied.get("text", "")
            typed = last_word(r.window)
            # This pass's window is post-insertion (already ends with the
            # tapped word). Recover what the user had actually typed from the
            # most recent earlier pass whose tail is a partial of `tapped`.
            if typed == tapped:
                for pr in reversed(kb[:idx]):
                    frag = last_word(pr.window)
                    if frag and frag != tapped and tapped.lower().startswith(frag.lower()):
                        typed = frag
                        break
            events.append(Event("TAP_USED", r.t, typed, tapped,
                                 context=words(r.window)[-5:-1]))

    events.sort(key=lambda e: e.t)
    return events


def _bar_texts_while_typing(kb: list, typo: str, before_t: float, prefix: str) -> list:
    seen = []
    for r in kb:
        if r.t > before_t:
            continue
        if _pass_is_typing(r, typo, prefix):
            for b in r.bar:
                txt = b.get("text", "")
                if txt and txt not in seen:
                    seen.append(txt)
    return seen


def committed_word_count(app: list) -> int:
    final = ""
    for r in app:
        if r.kind in ("snapshot", "stop") and r.text:
            final = r.text
    return len(words(final))


def tap_offset_stats(kb: list) -> dict:
    acc: dict = {}
    for r in kb:
        for tap in r.taps:
            c = tap.get("c", "")
            dx = tap.get("dx", 0.0)
            dy = tap.get("dy", 0.0)
            s = acc.setdefault(c, {"n": 0, "sx": 0.0, "sy": 0.0})
            s["n"] += 1
            s["sx"] += dx
            s["sy"] += dy
    out = {}
    for c, s in acc.items():
        n = s["n"]
        out[c] = {"count": n, "mean_dx": s["sx"] / n, "mean_dy": s["sy"] / n}
    return out


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def render_report(sid: str, app: list, kb: list, events: list) -> str:
    counts: dict = {}
    for e in events:
        counts[e.cls] = counts.get(e.cls, 0) + 1
    committed = committed_word_count(app)
    flagged = sum(1 for e in events if e.cls != "CLEAN")
    clean = max(committed - flagged, 0)

    lines = []
    lines.append(f"# Session report — {sid}")
    lines.append("")
    lines.append(f"- app records: {len(app)}  ·  kb passes: {len(kb)}")
    lines.append(f"- committed words (final text): {committed}")
    lines.append("")
    lines.append("## Event counts")
    lines.append("")
    for cls in ["AUTOCORRECT_UNDONE", "MISS_OFFERED", "MISS_ABSENT", "TAP_USED"]:
        lines.append(f"- {cls}: {counts.get(cls, 0)}")
    lines.append(f"- CLEAN (approx): {clean}")
    lines.append("")

    lines.append("## Events")
    lines.append("")
    if not events:
        lines.append("_none_")
    for e in events:
        ctx = " ".join(e.context)
        lines.append(f"### {e.cls}")
        lines.append(f"- typed: `{e.typo}`  →  intended: `{e.intended}`")
        if ctx:
            lines.append(f"- context: …{ctx}")
        if e.offered_bar:
            lines.append(f"- bar offered: {', '.join('`'+b+'`' for b in e.offered_bar)}")
        lines.append("")

    lines.append("## Per-key tap offsets")
    lines.append("")
    stats = tap_offset_stats(kb)
    if not stats:
        lines.append("_no tap samples_")
    else:
        lines.append("| key | count | mean dx | mean dy |")
        lines.append("|-----|-------|---------|---------|")
        for c in sorted(stats):
            s = stats[c]
            lines.append(f"| `{c}` | {s['count']} | {s['mean_dx']:+.3f} | {s['mean_dy']:+.3f} |")
    lines.append("")
    return "\n".join(lines)


def candidates_jsonl(events: list) -> str:
    out = []
    for e in events:
        if e.cls in ("AUTOCORRECT_UNDONE", "MISS_OFFERED", "MISS_ABSENT"):
            out.append(json.dumps(e.to_candidate(), ensure_ascii=False))
    return "\n".join(out) + ("\n" if out else "")


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------

def discover_sessions(directory: str) -> list:
    ids = set()
    for name in os.listdir(directory):
        if name.endswith("-app.jsonl"):
            ids.add(name[: -len("-app.jsonl")])
    return sorted(ids)


def analyze_dir(directory: str) -> int:
    ids = discover_sessions(directory)
    if not ids:
        print(f"No sessions (<id>-app.jsonl) found in {directory}", file=sys.stderr)
        return 1
    for sid in ids:
        app_path = os.path.join(directory, f"{sid}-app.jsonl")
        kb_path = os.path.join(directory, f"{sid}-kb.jsonl")
        app, kb = load_session(app_path, kb_path)
        events = classify(app, kb)
        report = render_report(sid, app, kb, events)
        with open(os.path.join(directory, f"{sid}-report.md"), "w", encoding="utf-8") as fh:
            fh.write(report)
        with open(os.path.join(directory, f"{sid}-candidates.jsonl"), "w", encoding="utf-8") as fh:
            fh.write(candidates_jsonl(events))
        print(f"{sid}: {len(events)} events → {sid}-report.md, {sid}-candidates.jsonl")
    return 0


def main(argv: list) -> int:
    directory = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(__file__), "sessions")
    return analyze_dir(directory)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
