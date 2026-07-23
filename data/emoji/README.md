# Icelandic emoji labels

`is.json` is a deterministic extraction of the Icelandic emoji short names
and search keywords in Unicode CLDR 48.2, limited and ordered by the complete
Emoji 17.0 fully-qualified repertoire.

`is-suggestions.json` is the compact runtime artifact bundled with the
keyboard extension. It maps conservative, exact, single-token Icelandic
labels to one unambiguous emoji from the bundled picker. The full corpus stays
available for auditing and future search/ranking without being parsed on each
keyboard process launch.

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

The builder pins every upstream URL and SHA-256 and fails if any emoji lacks
an Icelandic name. Variation selectors are removed only when joining Emoji 17
sequences to CLDR annotation keys, as required by LDML; the emitted emoji
sequences retain them.

This is the authoritative base layer. Product-specific colloquial aliases or
inflection expansion should live in a small reviewed overlay, not as edits to
the CLDR-derived records. The data is licensed under Unicode-3.0; see
[`../ATTRIBUTION.md`](../ATTRIBUTION.md).
