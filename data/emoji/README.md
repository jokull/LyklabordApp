# Icelandic emoji labels

`is.json` is a deterministic extraction of the Icelandic emoji short names
and search keywords in Unicode CLDR 48.2, limited and ordered by the complete
Emoji 17.0 fully-qualified repertoire.

Two compact runtime artifacts are bundled with the keyboard extension:

- `is-suggestions.json` maps conservative, exact, single-token Icelandic
  labels to one unambiguous emoji for the ordinary suggestion bar;
- `is-search.json` contains the 1,586 picker-supported base emoji with their
  Icelandic and English CLDR names and keywords for explicit browse search.
  It records both pinned source locales, the picker SHA-256 and corpus counts,
  is capped below 250 KB, and loads only when search opens. Result labels and
  accessibility names remain Icelandic; either language can find them.

The full corpus stays available for auditing and generation without being
parsed on keyboard activation.

Each of the 3,944 records contains:

- `emoji`: the exact fully-qualified Unicode sequence, including VS16 where
  Emoji 17 specifies it;
- `name`: CLDR's Icelandic short/TTS name;
- `keywords`: CLDR's Icelandic search annotations.

Examples include `❤️ → rautt hjarta` with keyword `hjarta`, and
`☕ → heitur drykkur` with keyword `kaffi`.

Regenerate or verify the checked-in corpus from the repository root:

```bash
python3 scripts/build-emoji-labels.py
python3 scripts/build-emoji-labels.py --check
```

The builder pins every upstream URL and SHA-256 and fails if any searchable
emoji lacks an Icelandic or English name. Variation selectors are removed only
when joining Emoji 17 sequences to CLDR annotation keys, as required by LDML;
the emitted emoji sequences retain them.

This is the authoritative base layer. Product-specific colloquial aliases or
inflection expansion should live in a small reviewed overlay, not as edits to
the CLDR-derived records. The data is licensed under Unicode-3.0; see
[`../ATTRIBUTION.md`](../ATTRIBUTION.md).
