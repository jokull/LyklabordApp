#!/usr/bin/env python3
"""Fail when new eager work lands on the keyboard extension's launch path.

The extension's time-to-first-key is decided by what runs synchronously in a
handful of entry points. This lint extracts their bodies from the Swift
sources, strips comments and string literals, and rejects patterns that mean
"blocking I/O, decode, or cross-queue wait on this thread":

  KeyboardViewController.swift   viewDidLoad, viewWillAppear,
                                 viewWillSetupKeyboardView, forwardTextContextChange
  LyklabordAutocompleteService.swift   init(appGroupId:activationStartedAt:)
                                 (runs inside viewDidLoad)

It also asserts the ordering invariant inside `bootstrapIfNeeded`: the
session must be published (`coldStartTracker.engineReady()`) before the
inflection or emoji-suggester loads are scheduled or decoded inline, so
neither can sit in front of the first keystroke.

Exemptions are explicit (EXEMPT below) and must say why. Run:

  python3 tools/cold-start/launch_path_lint.py            # lint repo
  python3 tools/cold-start/test_launch_path_lint.py       # self-test
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# Pattern → why it is forbidden on a launch-path thread.
FORBIDDEN = {
    r"\bData\(contentsOf": "file read on the launch thread",
    r"\bString\(contentsOf": "file read on the launch thread",
    r"\bJSONDecoder\(\)": "JSON decode on the launch thread",
    r"\bJSONSerialization\.": "JSON parse on the launch thread",
    r"\bPropertyListDecoder\(\)": "plist decode on the launch thread",
    r"\.sync\s*[\{(]": "synchronous hop onto another queue (blocks until it drains)",
    r"\bDispatchSemaphore\b": "blocking wait",
    r"\bcontainerURL\(forSecurityApplicationGroupIdentifier": "App Group container resolution (XPC) on the launch thread",
    r"\bFileManager\.default\.(attributesOfItem|contentsOfDirectory|fileExists)": "file metadata on the launch thread",
    r"\bFrequencyLexicon\(": "artifact open belongs on the engine queue",
    r"\bBinaryLemmatizer\(": "artifact open belongs on the engine queue",
    r"\bParadigmsReader\(": "artifact open belongs on the engine queue",
    r"\bGovernorsModel\(": "gunzip+parse belongs off the engine queue",
    r"\bEmojiCatalog\.shared\b": "catalog decode on the launch thread (warm it off-main, read it later)",
    r"\bEmojiCatalog\(data": "catalog decode on the launch thread",
    r"\bIcelandicEmojiSearchIndex\.bundled\b": "search index decode on the launch thread",
    r"\bPersonalModel\(contentsOf": "personal model decode on the launch thread",
    r"\bThread\.sleep\b": "sleep",
    r"\busleep\(": "sleep",
}

# (file, function, pattern) triples that are allowed, with the reason. An
# exemption is FUNCTION-WIDE: it silences that pattern anywhere in that
# body, so keep each exempted function small and review it by hand.
EXEMPT = {
    # viewDidLoad warms the catalog inside
    # `DispatchQueue.global(...).async { _ = EmojiCatalog.shared }`. The lint
    # does not prove the call is inside the `.async` block; the same pattern
    # in any OTHER entry point (e.g. viewWillAppear) still fails.
    ("KeyboardViewController.swift", "viewDidLoad", r"\bEmojiCatalog\.shared\b"):
        "off-main warm-up, reviewed by hand",
}

ENTRY_POINTS = {
    "KeyboardViewController.swift": [
        "viewDidLoad",
        "viewWillAppear",
        "viewWillSetupKeyboardView",
        "forwardTextContextChange",
    ],
    "LyklabordAutocompleteService.swift": [
        "init",
    ],
}


def strip_comments_and_strings(source: str) -> str:
    """Remove // and /* */ comments and the contents of string literals.

    Keeps newlines so that line numbers in findings stay meaningful. String
    literal contents become empty quotes, which is enough to stop a pattern
    inside a log message from matching.
    """
    out = []
    i = 0
    n = len(source)
    while i < n:
        c = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and source[i] != "\n":
                i += 1
            continue
        if c == "/" and nxt == "*":
            i += 2
            while i < n and not (source[i] == "*" and i + 1 < n and source[i + 1] == "/"):
                if source[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
            continue
        if c == '"':
            # Multi-line """ or single-line " literal; keep interpolations out.
            if source.startswith('"""', i):
                end = source.find('"""', i + 3)
                end = n if end == -1 else end
                out.append('""')
                out.append("\n" * source[i:end].count("\n"))
                i = end + 3
                continue
            out.append('"')
            i += 1
            while i < n and source[i] != '"':
                if source[i] == "\\":
                    i += 1
                if source[i] == "\n":
                    out.append("\n")
                i += 1
            out.append('"')
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def extract_body(source: str, function: str):
    """Return (body, start_line) for the first `func <function>(` / `init(`.

    `source` must already be comment/string-stripped. Matches braces to find
    the end; nested closures stay inside the body (that is the point: an
    `.async { }` wrapper is still part of the entry point and is judged by
    the EXEMPT table, not hidden).
    """
    if function == "init":
        match = re.search(r"\binit\s*\(", source)
    else:
        match = re.search(r"\bfunc\s+" + re.escape(function) + r"\s*[(<]", source)
    if not match:
        return None, None
    brace = source.find("{", match.end())
    if brace == -1:
        return None, None
    depth = 0
    i = brace
    while i < len(source):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    body = source[brace : i + 1]
    start_line = source.count("\n", 0, brace) + 1
    return body, start_line


def lint_body(file_name: str, function: str, body: str, start_line: int):
    findings = []
    for pattern, reason in FORBIDDEN.items():
        for m in re.finditer(pattern, body):
            if (file_name, function, pattern) in EXEMPT:
                continue
            line = start_line + body.count("\n", 0, m.start())
            findings.append(f"{file_name}:{line} {function}: `{m.group(0)}` — {reason}")
    return findings


def lint_bootstrap_order(source: str):
    """`coldStartTracker.engineReady()` must precede every deferred-load
    scheduling call inside bootstrapIfNeeded."""
    body, start = extract_body(source, "bootstrapIfNeeded")
    if body is None:
        return ["LyklabordAutocompleteService.swift: bootstrapIfNeeded not found"]
    ready = body.find("coldStartTracker.engineReady()")
    if ready == -1:
        return ["bootstrapIfNeeded: coldStartTracker.engineReady() not found"]
    findings = []
    for call in ("scheduleInflectionLoad(", "scheduleEmojiSuggesterLoad(", "ParadigmsReader(",
                 "GovernorsModel(", "IcelandicEmojiSuggester(", "IcelandicEmojiSearchIndex"):
        pos = body.find(call)
        if pos != -1 and pos < ready:
            line = start + body.count("\n", 0, pos)
            findings.append(
                f"LyklabordAutocompleteService.swift:{line} bootstrapIfNeeded: `{call}` runs before "
                "coldStartTracker.engineReady() — it sits in front of the first keystroke")
    return findings


def lint_sources(sources: dict):
    """sources: {file_name: raw swift source}. Returns a list of findings."""
    findings = []
    for file_name, functions in ENTRY_POINTS.items():
        if file_name not in sources:
            findings.append(f"{file_name}: missing")
            continue
        stripped = strip_comments_and_strings(sources[file_name])
        for function in functions:
            body, start = extract_body(stripped, function)
            if body is None:
                findings.append(f"{file_name}: {function} not found")
                continue
            findings.extend(lint_body(file_name, function, body, start))
    if "LyklabordAutocompleteService.swift" in sources:
        findings.extend(
            lint_bootstrap_order(strip_comments_and_strings(sources["LyklabordAutocompleteService.swift"])))
    return findings


def main() -> int:
    ext = REPO / "KeyboardExt"
    sources = {name: (ext / name).read_text(encoding="utf-8") for name in ENTRY_POINTS}
    findings = lint_sources(sources)
    for finding in findings:
        print(f"LAUNCH PATH: {finding}", file=sys.stderr)
    print("launch-path lint: " + ("pass" if not findings else f"FAIL ({len(findings)})"))
    return 0 if not findings else 1


if __name__ == "__main__":
    sys.exit(main())
