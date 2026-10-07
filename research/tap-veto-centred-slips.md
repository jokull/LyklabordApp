# Clean hits on the wrong key — why "Hverbig" waited for space-backspace, and the two autocorrect carve-outs of 2026-10-06

*Investigated 2026-10-06/07. Sources: `type-repl` decision traces (`:why`, `:tap`), the engine code (`Corrector.swift`, `AutocorrectPolicy.swift`, `TypingSession.swift`, `PerTapCostProvider.swift`), ADR-0006, `docs/WAVES.md`, the recorded sessions under `tools/session-analyzer/sessions/`, and a throwaway touch-aware replay built for this question (not in the repo). Engine work was done by two subagents; the scenario suites, unit tests and bench were re-run afterwards on a quiet machine.*

Trigger: the owner typed "Hverbig" (B for N, neighbouring keys). It was not armed for autocorrect. After space then backspace, "Hvernig" was armed. Separately, a user reported that "ap" is never corrected to "að".

## Verdict up front

- **The difference is the touch model.** A clean, centred hit on B is treated as evidence that B was meant. Space then backspace discards the word's tap samples, so the re-opened word is judged without them and the correction fires.
- **Centred hits on the wrong key are rare in the data we have.** Of 64 confirmed adjacent-key slips in the recorded sessions, none was within ±0.15 of key centre on both axes, and only four leaned less than 0.25 toward the intended key. One typist, one phone.
- **A narrow rescue is implemented and on by default**, for an unknown word with exactly one single-adjacent-substitution reading. It fixes the report and changed nothing on any touch-aware check built for it. **It recovers none of the 178 recorded real-tap slips**, so the evidence for benefit is one report plus synthetic cases.
- **"ap" → "að" was blocked by the valid-word rule**, because "ap" is in both frequency tables (mainly the English abbreviation "AP"). A second narrow carve-out now lets it through in an Icelandic lane.
- **Both carve-outs cut against ADR-0006 rule 1 and are not yet recorded there.**
- **No shipped eval is touch-aware.** The corpus numbers below prove the changes are neutral on tapless input; they cannot show safety or benefit on touch input.

## 1. Why "Hverbig" behaved differently

With taps, before the change:

| Taps | Top candidate | "hvernig" | Outcome |
|---|---|---|---|
| all at (0, 0) | `hver íg` (split), score −4.881 | #3, cost 7.229, score −6.211 | `rule=split`, margin 1.126 < 2.5, no fire |
| ~(0.1, 0.1), b at (0.15, 0.1) | hvernig, cost 5.060 | margin +0.639 | needs 1.150 × tapVeto 3.96 = 4.556, no fire |
| b at (0.2, 0) | hvernig, cost 4.337 | no competitor in the top two | fires |
| no taps | hvernig, cost 1.020 | margin +inf | fires |

Two separate effects:

- **Per-tap cost.** A centred b prices b→n at the full Gaussian exponent for one key pitch (σx 0.263): 7.23 nats against 1.02 static. At dead centre the right word falls to third, behind a space-miss split.
- **Margin veto.** `tapVetoFactor` multiplies the required margin about four times. It is not the binding constraint near centre: 0.639 fails 1.150 even at factor 1.

The dead zone is narrow: somewhere between a lean of 0.15 and 0.20 toward N, the competing split drops out and the word fires.

**Space then backspace.** `reconcileTapRecord` in `TypingSession.swift` clears `pendingTapRecord` when the current word becomes empty. On backspace into the committed word, every character is appended with no tap. `Corrector.swift` only builds a `PerTapCostProvider` when at least one tap is present, so the re-opened word runs the tapless path. Confirmed by a scenario.

The mechanism is deliberate (see the doc comment above `tapVetoFactor`): believing a clean hit is what stops deliberately typed unknown words from being rewritten.

## 2. What touch data exists

- `tools/session-analyzer/sessions/`: 28 sessions, 2,406 taps, one typist, one iPhone, 16–23 July 2026. Five more sessions (5–6 August) sit in the iCloud mirror, not ingested.
- "Hverbig" is in none of them. That the owner's B tap was centred is inferred from reproduction, not observed.
- Confirmed adjacent-key slips with a tap: 64. Lean is how far the tap sat toward the intended key (0.5 is the shared edge).

| Subset | n | lean < 0.10 | 0.17–0.25 | 0.25–0.40 | ≥ 0.40 |
|---|---|---|---|---|---|
| All | 64 | 2 | 2 | 18 | 42 |
| Fired live (biased toward leaning) | 43 | 0 | 0 | 11 | 32 |
| Not fired live (biased the other way) | 21 | 2 | 2 | 7 | 10 |

- The four below 0.25: `habb→hann` (0.18), `punltir→punktur` (0.18), `þci→því` (0.08), `dlmk→dæmi` (−0.04). The true rate of non-leaning slips lies between 6% (4/64) and 19% (4/21).
- Ordinary taps for comparison: median confidence 0.99; 29% have |dx| ≥ 0.25.
- `EvalKit` and `type-eval` have no tap support. Dev, heldout, safety, compounds and personal are all tapless. Only scenarios and unit tests exercise the tap path. `ReplayRig/traces/tsi-distributions.json`, cited in code as the σ source, is not in the repo.

Throwaway replay sets built for this question:

- **p1:** 178 confirmed typo→intended pairs with their real taps.
- **n1:** 323 kept-as-typed commits with real taps.
- **n2:** 551 dev-corpus tokens unknown to every lexicon (mostly names and foreign words), in four variants: natural case with context or lowercased, dead-centre taps or taps resampled from real per-key offsets.
- **p2c:** 753 dev single-adjacent-substitution typos with dead-centre taps.

## 3. Options evaluated

| Option | Hverbig fires (centred) | New wrong fires on n2 (4 × 551) | Real taps (p1 / n1) | p2c correct (of 753) | Suites / tests |
|---|---|---|---|---|---|
| Baseline | no | — | 133 correct, 5 wrong / 14 armed | 0 | clean |
| Tapless reference | yes | +83 to +97 | 135 / 14 | 580 | — |
| (a) veto clamp only | no | 0 | unchanged | 0 | not run (no effect) |
| (b) cost cap only, +3 nats | yes | 3–4 (Mytton→Mutton, retour→detour, …) | unchanged | 283 | suites clean; tests not run |
| (b) cap at static | yes | 7–8 | loses 3 correct | 386 | not run |
| (c) cap + veto lifted | yes | 3–7 | unchanged | 384–451 | breaks a dogfood and a touch scenario |
| (b) +3 with typicality floor | yes | 0 | unchanged | 87 | breaks `PersonalTouchTests` |
| **Chosen: unique-reading rescue** | **yes** | **0** | **unchanged** | **52** | **suites clean; `swift test` passes** |

Option (a) cannot work: hvernig's z is +1.71, under the 2.0 the existing common-winner clamp needs, and the margin fails without any veto.

## 4. What was implemented

### Centred-slip rescue ("Hverbig")

For a typed token attested nowhere (not valid, not compound-protected, no long-press): if exactly one attested candidate is the typed word with a single substitution, that substitution is to a physically adjacent key, and the candidate's typicality is z ≥ 1.0, it is repriced at static cost + 3.0 nats and the margin veto is lifted for that candidate only. A second single-substitution reading of any kind stands the rule down. Splits do not count as rivals.

Flags in `LanguageModel.swift`: `tapCentredSlipCapEnabled` (true), `tapCentredSlipMaxUplift` (3.0), `tapCentredSlipWinnerMinZ` (1.0).

Files: `Corrector.swift` (`centredSlipRescue`, `singleSubstitutionIndex`), `PerTapCostProvider.swift`, `CandidateProvider.swift` (`CandidateAdmissionPool.reprice`), `AutocorrectPolicy.swift`, `EvalKit/ConfigOverrides.swift`, and five scenarios in `Scenarios/dogfood.scenarios` (two positives; guards for centred "Mytton", "retour" and "thwn").

Also added, to make scenario A/B possible: `type-repl --config <overrides.json>` and `--deterministic` (`Sources/type-repl/main.swift`). Keep or drop is an open decision.

### Edge-undershoot yield ("ap" → "að")

Root cause: `:word ap` shows is.lex f=5939, en.lex f=568466 (the abbreviation "AP"), BÍN unknown. So `typedIsValid=true` and the trace ends `rule=valid-word (no auto-apply path)`, although "að" would clear every ordinary gate (margin 2.701 ≥ 1.150, z +3.553 ≥ +1.500).

The yield removes the valid-word veto only when all of these hold: the token is two letters or fewer; it is valid by frequency table alone (no BÍN reading, not personal, not tombstoned); there is no long-press or deliberate capital; the winner is BÍN-known and exactly one `SpatialModel.edgeUndershootPairs` substitution away (p→ð, l→æ, æ→ö, m→þ); P(IS) ≥ `edgeUndershootYieldMinPosterior`; and the existing restoration triple gate passes. Margin and the short-token typicality floor still decide.

The lane floor was first 0.8 and was lowered to 0.7 by owner decision so that "Ég held ap" fires (the lane starts at 0.50 in every field; "Ég" lifts it to 0.75 and the both-language "held" lets it drift to 0.71). Accepted cost, pinned as scenarios: "Ég ap" and "Hello Jón ap" (both 0.75) fire too.

Not fixed on purpose: "vip" → "við" (a three-letter cap also rewrote lips, burp and sips in testing), and a sentence-initial autocapitalised "Ap" after a truncated sentence.

## 5. Results

Re-run on a quiet machine after both changes:

| Check | Result |
|---|---|
| dogfood | 78/78 |
| core | 161/161 |
| folded / inflect / touch | 9/9, 13/13, 11/11 |
| compounds | 21/22 — `stokklei` at line 121, already recorded as failing in `docs/WAVES.md` |
| `swift test` | 81 tests, 0 failures |
| `type-repl bench` | p50 1.33 ms, p95 4.12 ms, max 6.10 ms; beam worst case 8.91 ms (gate 30 ms) |

Reported by the subagents, not re-run by me:

- Dev corpus A/B, flags off vs on: identical (top-1 78.43%, top-3 85.03%, false autocorrect 3.70%).
- Full scorecard with `--no-history`: exits 1 before and after, on the `stokklei` scenario only. Its summary line reads "scorecard FAIL — bench worst …", which looks like a bench failure and is not.
- `type-eval personal` exits 1 with two regressions (`juni|muni`, `þripjudagin|þripjudaginn`) against a July baseline. It is tapless, so the centred-slip change cannot reach it; whether the "ap" change or something older caused them was not chased.
- Heldout was not run.

## 6. Believed but not verified

- That the owner's B tap was centred. Reproduction only says its lean toward N was under about 0.17.
- That the rescue helps real typing. It recovers none of the 178 recorded real-tap pairs, including the four non-leaning slips (`habb` and `punltir` are two substitutions, `þci` has a rival reading or is too short, `dlmk` is a mash).
- That the lean distribution generalises beyond one typist and one device.
- That n2 is a fair proxy for deliberately typed names and slang. It is Wikipedia tokens with synthetic or resampled taps.
- The 3.0-nat uplift. It is a rough odds argument (4 of 64 is about 2.7 nats) and the value that fit the scenarios; 2.0 tested equally clean.
- That the intended word always reaches the candidate pool via `edits1-residue` when the per-tap beam prices it out. It held for "Hverbig"; it was not tested broadly.
- Neither change has been tried on a device.
