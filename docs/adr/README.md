# Architecture Decision Records

This directory records decisions that have been **made and implemented**
(or explicitly locked) for Lyklaborð — not in-flight or future work. Each
ADR is a lightweight, self-contained record: a contributor who has never
seen the project's private planning doc should be able to follow the
reasoning from the ADR alone.

| # | Title | Summary |
|---|---|---|
| [0001](0001-product-scope.md) | Product scope: privacy-first Icelandic+English keyboard | Free, open-source, zero-telemetry keyboard with a single blended IS/EN layout, no swipe, no monetization, extension ships zero network code |
| [0002](0002-ios-18-floor.md) | iOS 18 deployment floor, iPhone-first | Raised from 17.0 for free `Observation`/`NavigationStack` use in app code; iPad functional but unoptimized |
| [0003](0003-vendor-keyboardkit.md) | Vendor KeyboardKit 9.9.1 permanently | v10 went closed-source behind a license-validated SDK; 9.9.1 is the last full-MIT-source tag — vendored and forked, never tracking upstream again |
| [0004](0004-full-bin-binary-mmap.md) | Ship the full mmap-backed BÍN binary | Original 91MB mmap bench established demand-paged behavior; the 2026-07-18 refresh ships ~110MB / 3.70M forms, with tiered builds kept only as a download-size escape hatch |
| [0005](0005-two-lane-language-model.md) | Two-lane HMM language model | Sticky Icelandic/English lanes with calibrated per-word evidence absorb one-off *slettur* without hijacking the keyboard, unlike a flat EMA |
| [0006](0006-autocorrect-conservatism.md) | Autocorrect conservatism | Never auto-replace a valid word; verbatim escape hatch; URL/dotted-token protection layers; deliberately under-corrects vs. both incumbents |
| [0007](0007-learning-architecture.md) | Learning architecture | App-Group event log with enforced privacy invariants (single words, no secure/URL fields, day buckets); 2-distinct-days-or-explicit threshold; tombstones stick; surface forms are ground truth, lemma lift only when unambiguous |
| [0008](0008-personal-ranking-integration.md) | Personal ranking integration | Additive, capped score boost — not probability renormalization; personal words excluded from lane evidence; learning applies immediately within a session |
| [0009](0009-encrypted-icloud-sync.md) | Encrypted iCloud sync | CloudKit private DB + CryptoKit AES-GCM; key roams via iCloud Keychain; join-semilattice merge (max/union/OR) requires no server and no stored ancestor |
| [0010](0010-testing-strategy.md) | Testing strategy | Unit tests → headless `type-repl` harness simulating the real `UITextDocumentProxy` contract → planned device replay rig → dogfooding; disjoint dev/heldout eval corpus with hard gates |
| [0011](0011-naming-and-licensing.md) | Naming, identifiers, licensing | Renamed to Lyklaborð before user data accumulated; MIT code license with separately-stated BÍN/SymSpell/CC BY-SA data licenses |
| [0012](0012-bottom-row-design.md) | Bottom-row design | Period key with long-press cluster, spacebar cursor control, double-space period, and the explicit decision to keep KeyboardKit's stock emoji picker |

## Proposing a new ADR

ADRs here record decisions that are **already accepted and shipped** (or
explicitly locked, even if implementation is still in progress) — not
proposals or in-flight design discussion. To propose a new one:

1. Confirm the decision is actually settled — in-flight/future work (e.g.
   the beam decoder, lane relaxation profiles, inflection intelligence, or
   touch-coordinate plumbing) belongs in the project's internal planning
   doc until it ships, not here.
2. Use the existing files as the format template: `# Title`, `Status:
   Accepted`, `Date`, `Context`, `Decision`, `Consequences`. Keep it
   concise but self-contained — cite exact numbers/measurements where they
   exist, and link related ADRs rather than repeating their content.
3. Number it sequentially after the highest existing ADR.
4. Add a row to the index table above.
