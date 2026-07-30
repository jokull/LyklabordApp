# Icelandic emoji labels

`is.json` is a deterministic extraction of the Icelandic emoji short names
and search keywords in Unicode CLDR 48.2, limited and ordered by the complete
Emoji 17.0 fully-qualified repertoire.

Three compact runtime artifacts are bundled with the keyboard extension:

- `catalog.json` is the authoritative 1,914-family / 3,944-sequence picker
  repertoire. Every exact sequence carries a release tier: Emoji 15.1 on iOS
  18.0+, Emoji 16.0 on iOS 18.4+, and Emoji 17.0 on iOS 26.4+;

- `is-suggestions.json` maps conservative, exact, single-token Icelandic
  labels to one unambiguous emoji for the ordinary suggestion bar;
- `is-search.json` contains all 1,914 base emoji with their
  Icelandic and English CLDR names and keywords for explicit browse search.
  It records both pinned source locales, catalog schema and corpus counts, is
  capped below 300 KB, and loads only when search opens. Result labels and
  accessibility names remain Icelandic; either language can find them.

The full label corpus stays available for auditing and generation without being
parsed on keyboard activation. Browse, search, ordinary suggestions, recents,
and variant menus all use the same release-tier boundary, so an unsupported
sequence can never leak from one surface after being hidden on another.

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

The builder pins every upstream URL and SHA-256, verifies the exact 15.1, 16.0,
and 17.0 release totals, and fails if any searchable emoji lacks an Icelandic or
English name. Variation selectors are removed only for release/CLDR identity
joins, as required by LDML; emitted picker and insertion sequences retain them.

This is the authoritative base layer. Product-specific colloquial aliases or
inflection expansion should live in a small reviewed overlay, not as edits to
the CLDR-derived records. The data is licensed under Unicode-3.0; see
[`../ATTRIBUTION.md`](../ATTRIBUTION.md).
