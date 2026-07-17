# Contributing to Lyklaborð

Takk fyrir áhugann! Issues and PRs are welcome in Icelandic or English.

## Building

Build steps (xcodegen, Xcode 26+, per-package tests) live in the
[README's Building section](../README.md#building) — they are not duplicated
here.

## The wave/scenario discipline

Engine work in this repo moves in *waves*, and behavioral changes need
receipts: any change to typing behavior (autocorrect, suggestions,
prediction, learning) must come with scenario coverage in
`Packages/TypeEngine/Scenarios/*.scenarios` demonstrating the new behavior
and guarding the old, and should be argued against the wave ledger in
[docs/WAVES.md](../docs/WAVES.md) — read it first so decisions compound
instead of thrashing. Standing doctrine listed at the top of that file
(conservatism invariant, surface-forms-as-ground-truth, extension privacy,
eval discipline) is not up for casual reversal; violating it needs an ADR,
not just a PR.

## Privacy constraints

The privacy claims are the product. Two hard rules for contributors:

- **The keyboard extension ships zero networking code** and zero
  network-capable entitlements. PRs that add any network path to
  `KeyboardExt/` or its dependency packages will be declined regardless of
  intent.
- **Never commit personal typing data.** Real typing recordings, personal
  eval corpora, and learned-word dumps are gitignored on purpose
  (`scores/` personal data, dev-mode session recordings). Test fixtures must
  be invented text, never harvested from anyone's actual typing.

## Security

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md).
