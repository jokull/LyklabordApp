# App Store Connect automation tooling — 2026 state

*Researched 2026-07-17. Goal: minimize clicks in the App Store Connect web UI for
Lyklaborð (personal team `RDC8539AWM`, bundle `is.solberg.lyklabord`). Owner is a
solo dev on a local Mac — no CI, no org account, API key auth strongly preferred
over interactive Apple ID sessions.*

## Recommendation (TL;DR)

**One tool covers four of five tasks: [`tddworks/asc-cli`](https://github.com/tddworks/asc-cli)
("asc"), authenticated once with the ASC `.p8` API key.** For the fifth
(CloudKit), use Apple's own **`cktool`** (bundled with Xcode) with a separate
CloudKit Management Token. **fastlane and EAS are not needed for this project** —
both are strictly worse fits than `asc-cli` here (see below). App record
creation is the one step still best done by hand in the web UI, even though
`asc-cli` has an unofficial path that avoids it.

| # | Task | Tool | Auth |
|---|---|---|---|
| 1 | Upload build to TestFlight | `asc-cli` (`asc builds archive` / `asc builds upload`) | ASC API key (.p8) |
| 2 | Metadata, keywords, description, screenshots, privacy labels | `asc-cli` (`app-info-localizations`, `version-localizations`, `screenshot-sets`/`screenshots upload`, `age-rating`) | ASC API key (.p8) |
| 3 | **Create the app record** | **Web UI** (recommended) — or `asc-cli`'s `iris apps create` (unofficial, cookie auth) if scripting is worth the risk | Web UI: none extra (just the browser session already used to check ASC). `iris`: browser cookies, no password/2FA typed into a CLI |
| 4 | Subscription group + auto-renewable product + price + intro offer | `asc-cli` (`subscription-groups create`, `subscriptions create`, `subscriptions price-points list` + `prices set`, `subscription-offers create`) | ASC API key (.p8) — official API, GA |
| 5 | CloudKit production schema deploy | `cktool` (Apple, ships with Xcode) — `export-schema --environment development` → `import-schema --environment production` | CloudKit **Management Token** (separate from ASC API key, one-time web-UI generation) |

Net result: **one CLI + one Apple-bundled tool**, one interactive web-UI visit
for app creation (plus the unavoidable Paid Apps Agreement/banking step), and
one one-time token-generation click for CloudKit. Everything else — every
build upload, every metadata edit, every screenshot, every subscription field
— is scriptable from the terminal with the `.p8` key already sitting in
`store/README.md`'s plan.

---

## What surprised me

1. **App creation genuinely still has no official API in 2026.** The brief's
   suspicion was right and doesn't need re-verifying every year: Apple has
   never shipped `POST /v1/apps`. What changed is *how bad the workaround is*.
   fastlane's `produce`/`spaceship` route requires a real Apple ID
   username+password login with a 2FA code typed in at least once (app-specific
   passwords only cover the TestFlight-artifact upload, not app creation —
   confirmed still true via fastlane's own GitHub discussions/issues). By
   contrast, `asc-cli`'s `iris` subcommand (a from-scratch 2026 reimplementation
   of the private API that powers the ASC web UI) just reads cookies out of a
   browser you're already logged into (`ASC_IRIS_COOKIES` for headless use) —
   no password or 2FA prompt in the CLI at all. It's still an **unofficial,
   unsupported, ToS-grey-area private endpoint** (same one fastlane's
   `spaceship` has always scraped), so I'd still default to the one-time web-UI
   click per `store/README.md`'s migration plan — but it's worth knowing the
   automation exists if the name-race window in that doc ever needs to be
   collapsed to seconds.

2. **`cktool` can fully script the CloudKit production deploy** — I expected
   it to be console-button-only. `xcrun cktool import-schema` takes a mandatory
   `--environment development|production` flag, so `export-schema
   --environment development --file dev.ckdb` followed by `import-schema
   --environment production --file dev.ckdb` reproduces exactly what the
   Console's "Deploy Schema Changes" button does, with the same non-destructive
   constraint (you still can't promote destructive changes — Apple enforces
   that at the schema-diff level, not just in the button UI). The catch:
   `cktool` **does not accept the ASC API key at all** — it needs its own
   CloudKit Management Token, generated once via CloudKit Console → Settings
   (team-and-user-scoped, 1-year lifespan, savable to Keychain via `xcrun cktool
   save-token`). So this is a second, separate one-time credential, not reuse
   of the `.p8` already in the TestFlight/metadata plan.

3. **Two credible community CLIs appeared in 2026 that didn't exist when this
   category was last surveyed**, and both leapfrog the older ones:
   - **`tddworks/asc-cli`** (Swift, MIT, 293 stars, latest release
     2026-07-16) — genuinely comprehensive: builds/TestFlight, metadata,
     screenshots + AI-assisted screenshot generation, full IAP/subscription
     lifecycle including per-territory pricing and intro/promotional/win-back
     offers, Xcode Cloud, Game Center, customer reviews, sales/finance
     reports, *and* the `iris` private-API bridge for app creation — all
     behind one `.p8` key with named multi-account credential storage.
   - **`rorkai/App-Store-Connect-CLI`** (Go, MIT, 5,098 stars, pushed hours
     before this research) — similarly broad (TestFlight feedback/crashes,
     builds, releases, metadata, keyword ASO auditing, "asc skills" agent
     integration), but its subscription support is thinner in what the README
     surfaces (mostly StoreKit retention-messaging/analytics, not full
     subscription-group/price-point CRUD) and it has no app-creation path at
     all (official API only).
   Both **eclipse the older `ittybittyapps/appstoreconnect-cli`** (Swift,
   last pushed 2022-11-01 — dead) and **`cidertool/cider`** (Go, last pushed
   2023-04-12 — dead, GPL-3.0). Neither dead tool should be considered.

4. **fastlane is alive (41.8k stars, pushed yesterday) but is the wrong shape
   for this project specifically.** `deliver`/`pilot` do accept
   `api_key`/`api_key_path` now, so build upload and metadata/screenshot sync
   *can* be API-key-only — but `produce` (app creation) cannot, and mixing
   "some actions use the key, one action needs a password+2FA session" is
   exactly the complexity the owner is trying to avoid. fastlane is Ruby +
   gem/bundler + a Fastfile DSL; `asc-cli` is a single Homebrew binary with a
   flatter command surface that maps 1:1 onto "task 1, task 2, task 4" with no
   DSL to learn. There's no reason to add fastlane on top.

5. **EAS/`eas submit` is a dead end here, confirming the owner's tool suspicion
   was misplaced.** It does accept an arbitrary `.ipa` from a non-Expo build
   and does prefer ASC-API-key auth (`ascApiKeyPath`) over Apple ID — so the
   upload step itself would technically work. But: (a) it still requires the
   app record to exist in ASC first (same as everything else — it's not an
   app-creation shortcut), (b) it requires an Expo account + `eas.json` +
   project registration purely to wrap a step `asc-cli`/`xcodebuild` already
   do natively, and (c) it does **nothing** for metadata, screenshots,
   subscriptions, or CloudKit — it is scoped to upload only. Adding an Expo
   account dependency for a bare Swift/xcodegen project to get a single upload
   command that a native tool already provides is pure overhead. Skip it.

6. **The official REST API's subscription coverage is fully GA and directly
   usable** — subscription groups, subscriptions, per-territory price points
   (`GET .../subscriptions/{id}/pricePoints`), and introductory offers
   (`.../subscriptions/{id}/introductoryOffers`, create/list/delete) are all
   real, documented, working endpoints, not a 2026 addition still in beta.
   `asc-cli` is a thin, honest wrapper over exactly this — nothing here needs
   fastlane's `deliver`/`spaceship` internals or a private API.

---

## Tool-by-tool

### `tddworks/asc-cli` ("asc") — recommended primary tool
- Swift 6.2, macOS 13+, MIT license, Homebrew (`brew install asccli`).
- Auth: `asc auth login --key-id <id> --issuer-id <id> --private-key-path
  ~/.asc/AuthKey_XXXXXX.p8 [--name personal]` — stores multiple named
  credential sets in `~/.asc/credentials.json`, or env vars
  (`ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_PRIVATE_KEY_PATH`).
- Covers tasks 1, 2, 4 entirely on the official API key. Task 3 only via the
  optional, separately-authenticated `iris` cookie bridge (see below). No
  CloudKit coverage (task 5 is out of scope for any ASC-API tool — it's a
  different Apple service with its own token).
- JSON output by default, built for agent/CI use (`asc web-server` even
  exposes every command as a REST endpoint); `--pretty`/`--output table` for
  human reading.
- 293 stars, actively developed (latest tag 2026-07-16, the day before this
  research), CI+codecov on the repo.

### `rorkai/App-Store-Connect-CLI` ("asc", Go) — strong alternative, not chosen
- Go 1.26, MIT, Homebrew (`brew install asc`) — name-collides with tddworks'
  binary, so only install one.
- Covers builds/TestFlight/releases/metadata/keyword-ASO auditing well; ships
  an "agent skills" pack (`asc install-skills`) for Claude/Codex-style
  integration and a public "Wall of Apps" registry.
- Monetization surface as documented in its README is narrower — mostly
  StoreKit retention-messaging analytics rather than full
  subscription-group/subscription/price-point CRUD — and it has no
  app-creation escape hatch at all.
- 5,098 stars in ~6 months (created 2026-01-20) — real traction, but for this
  project's specific task list `asc-cli` (tddworks) covers strictly more
  (subscriptions + the iris bridge) with less risk of collision.

### Official ASC REST API via curl + JWT
- Fully covers: builds (upload/list/expire), app info & version localizations,
  screenshot sets/screenshots, age rating, subscription groups/subscriptions/
  price points/introductory offers, beta groups/testers, review submissions.
- Does **not** cover: creating the app record itself (confirmed no `POST
  /v1/apps` exists in 2026).
- No reason to hand-roll curl+JWT here — `asc-cli` already is this, with
  ergonomics, retries, and JSON shaping done.

### `xcrun altool` / Transporter
- `altool --upload-app` is deprecated in favor of `--upload-package`
  (Xcode 26-era fastlane issues confirm `--upload-app` still triggers
  deprecation warnings/breakage); Apple's other supported path is the
  Transporter CLI/GUI, both accepting API-key JWT auth.
- Redundant here: `asc-cli builds upload`/`builds archive` already wraps
  `xcodebuild` + upload in one step with the same API key. No need to reach
  for `altool` directly.

### `cktool` (Apple, bundled with Xcode) — required for task 5, no substitute
- Auth is a **CloudKit Management Token**, distinct from the ASC `.p8` key:
  generate once at CloudKit Console → (your team) → Settings → Management
  Tokens (1-year lifespan), then `xcrun cktool save-token` to put it in
  Keychain, or export `CLOUDKIT_MANAGEMENT_TOKEN`.
- Deploy flow (fully scriptable, no Console button click needed):
  ```bash
  xcrun cktool export-schema \
    --team-id RDC8539AWM \
    --container-id iCloud.is.solberg.lyklabord \
    --environment development \
    --file dev-schema.ckdb

  xcrun cktool import-schema \
    --team-id RDC8539AWM \
    --container-id iCloud.is.solberg.lyklabord \
    --environment production \
    --file dev-schema.ckdb
  ```
  Same non-destructive constraints as the web Console deploy button apply
  (adding fields/indexes: fine; removing/retyping: blocked either way).
- No community tool wraps this better than the official binary; not worth
  adding a dependency for one command pair.

### fastlane (`deliver`/`pilot`/`produce`/`spaceship`) — not recommended here
- Alive and maintained (41.8k★, commits daily) but the wrong shape for a
  single-owner, no-CI project: API-key auth is real for `deliver`/`pilot`,
  but `produce` still needs an interactive Apple-ID + 2FA session
  (app-specific passwords only cover the artifact-upload half of `pilot`, not
  `produce`'s account-level actions) — reintroducing exactly the
  interactive-session pain the brief wants to avoid, for zero capability gain
  over `asc-cli`.

### EAS / `eas submit` — not recommended here
- Accepts arbitrary `.ipa`, prefers ASC API key — technically works as an
  upload step. But needs an Expo account + `eas.json`/project registration,
  requires the app record to pre-exist (no app-creation help), and has zero
  coverage of metadata/screenshots/subscriptions/CloudKit. Pure overhead for
  a bare Swift project that already has a better single-binary tool.

---

## Web-UI-only residue (can't be automated away)

- **Creating the app record** (task 3) — recommended to keep doing by hand,
  per `store/README.md`'s already-written migration order-of-operations
  (stage everything first, delete old record, immediately recreate on the
  personal team to avoid the name-race window). `asc-cli iris apps create`
  exists as an unofficial escape hatch if that window ever needs to shrink to
  seconds, but it rides on the same private API fastlane's `spaceship` has
  always used — no official support, could break on an Apple-side change with
  no notice.
- **Paid Apps Agreement + banking/tax info** (blocks any subscription from
  saving) — this is explicitly a contract-acceptance/identity flow; no ASC
  API or community CLI exposes it, and none claim to.
- **CloudKit Management Token generation** — one-time click in CloudKit
  Console Settings; after that, fully scriptable via `cktool` as above.
- **ASC API key generation itself** (Users and Access → Integrations → App
  Store Connect API) — the seed step everything else depends on; self-serve
  and immediate on a personal team per `store/README.md`'s section D, but
  still a web-UI click by necessity (Apple doesn't let you mint your first
  key from the CLI).

---

## Concrete commands for the five tasks

```bash
# --- one-time setup ---
brew install asccli   # tddworks/asc-cli
asc auth login \
  --key-id <ASC_KEY_ID> \
  --issuer-id <ASC_ISSUER_ID> \
  --private-key-path ~/.asc/AuthKey_<ASC_KEY_ID>.p8
asc init --app-id <APP_ID>     # after task 3 exists; pins app context

# --- 1. Upload a build to TestFlight ---
asc builds archive --scheme BetterKeyboard --platform ios \
  --export-method app-store \
  --upload --app-id <APP_ID> --version 1.0.0 --build-number 1
# or, from an already-exported ipa:
asc builds upload --app-id <APP_ID> --file build/export/BetterKeyboard.ipa \
  --version 1.0.0 --build-number 1
asc builds set-encryption-compliance --build-id <BUILD_ID> --uses-non-exempt-encryption false

# --- 2. Metadata + screenshots + privacy ---
asc app-info-localizations update --localization-id <LOC_ID> \
  --name "Lyklaborð" --subtitle "..."
asc version-localizations update --localization-id <VLOC_ID> \
  --whats-new "..." --description "$(cat store/metadata/en.md)"
asc screenshot-sets create --localization-id <VLOC_ID> --display-type APP_IPHONE_67
asc screenshots upload --set-id <SET_ID> --file store/screenshots/export/en-US/01_hero.png
# repeat screenshots upload for all 6 en-US PNGs, in order
asc age-rating update --declaration-id <DECL_ID> ...   # per app-review.md worksheet

# --- 3. Create the app record — do this in the web UI (see store/README.md
#     "Personal team migration" for exact order-of-operations). If scripting
#     is ever worth the unofficial-API risk:
asc iris auth login --apple-id you@example.com --interactive   # one-time, 2FA, ~30-day session
asc iris apps create --name "Lyklaborð" --bundle-id is.solberg.lyklabord \
  --sku lyklabord-ios --platforms IOS

# --- 4. Subscription group + product + price + intro offer ---
asc subscription-groups create --app-id <APP_ID> --reference-name "Lyklaborð+"
asc subscriptions create --group-id <GROUP_ID> --name "Lyklaborð+ Annual" \
  --product-id is.solberg.lyklabord.plus.annual --period ONE_YEAR
asc subscriptions price-points list --subscription-id <SUB_ID> --territory USA
asc subscriptions prices set --subscription-id <SUB_ID> --territory USA \
  --price-point-id <PP_ID_NEAREST_19_00>
asc subscription-offers create --subscription-id <SUB_ID> --territory USA \
  --price-point-id <INTRO_PP_ID> --duration ONE_MONTH --offer-mode PAY_AS_YOU_GO
# (run `asc subscription-offers create --help` to confirm exact flags — the
# lifecycle docs confirm the affordance exists as `createIntroductoryOffer`
# but the README doesn't spell out every flag)

# --- 5. CloudKit production schema deploy ---
xcrun cktool save-token --team-id RDC8539AWM   # one-time, paste Management Token
xcrun cktool export-schema --team-id RDC8539AWM \
  --container-id iCloud.is.solberg.lyklabord --environment development \
  --file /tmp/lyklabord-dev-schema.ckdb
xcrun cktool import-schema --team-id RDC8539AWM \
  --container-id iCloud.is.solberg.lyklabord --environment production \
  --file /tmp/lyklabord-dev-schema.ckdb
```
