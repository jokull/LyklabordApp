# Lyklaborð+ — subscription infrastructure

Commercial model (locked): the base keyboard is **free forever and open
source (MIT)** — the full Icelandic+English engine, autocorrect,
completions, inflection intelligence. **Lyklaborð+** (annual subscription)
unlocks the PERSONAL layer:

- **Personal vocabulary** — on-device learned words, the dictionary editor
  (Orðasafn) with explicit adds, SwiftKey import, iCloud sync of the
  personal model.
- **Coordinate adjustment** — PersonalTouch per-key Gaussians ("learning
  your personal typos"). TSI-seeded defaults remain free.

## Architecture (how entitlement flows)

```
App (StoreKit 2)                          App Group                  Keyboard extension
────────────────                          ─────────                  ──────────────────
SubscriptionManager                       UserDefaults suite         BetterKeyboardAutocompleteService
  Transaction.currentEntitlements  ──►    plus.entitled (Bool)  ──►    isPlusEntitled(appGroupId:)
  (verified on-device, no server)         plus.expiry (epoch s)        at bootstrap + every viewWillAppear
  refreshed: launch, foreground,                                       entitled → load personal model
  Transaction.updates, purchase/restore                                unentitled → snapshots nil (free path)
```

- **StoreKit runs in the containing app only.** The extension has zero
  network entitlements, forever (standing doctrine). It reads a plain
  `UserDefaults` flag from the App Group — deliberately **no DRM, no
  signing**: this is honor-system client state in an open-source app.
  Shared state type: `Learning.PlusEntitlement` (keys, round-trip, expiry
  lenience — unit-tested).
- **Expiry lenience**: the extension honors the flag up to 30 days past the
  recorded expiry (`PlusEntitlement.expiryLenience`) — covers billing
  grace/retry and the structural fact that only the app can refresh the
  flag. After that it falls back to free until the app runs again.
- **DEBUG builds are always entitled** (app `SubscriptionManager.isEntitled`
  / `PlusGate`, extension `isPlusEntitled`) so dogfooding never fights the
  paywall. `swift test` never sees the override (it lives outside the
  Learning package).
- **Free tier keeps learning**: the extension writes learning events
  (`EventLog`) regardless of entitlement — subscribing later inherits the
  full on-device history instead of starting cold (deliberate goodwill).
  What the gate switches off is *consumption*: personal vocabulary
  boosts/surfaces and PersonalTouch Gaussians. With both nil the engine is
  byte-identical to today's empty-personal-model path.
- **Never paywalled**: data export ("Flytja út gögnin mín"), delete-all,
  delete-from-iCloud (`SyncEngine.deleteRemote` ignores the gate).

## App Store Connect setup (to do before submission)

1. **Subscription group**: reference name `Lyklaborð+` (one group, one
   product).
2. **Product**: auto-renewable subscription
   - Product ID: `is.solberg.lyklabord.plus.annual`
     (must match `SubscriptionManager.productID` and
     `App/Subscription/Lyklabord.storekit`)
   - Duration: 1 year
   - Price: pick the ~USD 19.99/year price point (the "$19/year" decision;
     ASC auto-derives other storefronts — review the ISK price point
     manually, Iceland is the home market). The app NEVER hardcodes price;
     it always renders `Product.displayPrice`.
   - Localizations: Icelandic + English display name "Lyklaborð+";
     descriptions matching the paywall's three features (personal
     vocabulary · typo learning · iCloud sync).
   - Family Sharing: OFF for now (owner decision below).
3. **App metadata requirements for subscription apps** (App Review 3.1.2):
   - Privacy Policy URL: `https://github.com/jokull/LyklabordApp/blob/main/docs/PRIVACY.md`
     (PRIVACY.md notes a stable hosted URL should replace this before
     submission).
   - Terms of Use (EULA): we use **Apple's standard EULA** — link it in the
     App Description metadata field
     (`https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`).
     The in-app paywall already links both (SubscriptionView legal footer).
   - The paywall shows: price + period from StoreKit, feature list, restore
     button, terms/privacy links. Manage/cancel deep link
     (`itms-apps://apps.apple.com/account/subscriptions`) lives in
     Settings → Áskrift.
4. **Paid Applications agreement** must be signed on the personal team
   (RDC8539AWM) with banking/tax filled in before the product can be
   created.
5. **Review notes** (paste into ASC review notes):
   - The app is open source; the subscription unlocks the personal
     dictionary layer. Gating is honest client-side state — the keyboard
     extension has no network capability at all (by design; see the
     privacy policy), so entitlement is propagated via the App Group from
     the containing app, which verifies with StoreKit 2 on-device.
   - The keyboard is fully functional without purchase (all typing,
     autocorrect, suggestions are free); the subscription only enables the
     personal-vocabulary features. No trial mechanics, no locked
     core functionality.
6. **Sandbox test**: create a sandbox tester; verify purchase → dictionary
   unlocks + extension loads the personal model on next keyboard
   presentation; verify restore on a fresh install; verify cancellation →
   sync pauses, editor locks, typing unaffected. (The StoreKit purchase
   flow is not unit-testable; `Lyklabord.storekit` + the scheme's
   `storeKitConfiguration` cover Simulator UI testing, and DEBUG builds
   are always entitled regardless.)

## Owner decisions still open

- **Intro offer / free trial** (e.g. 1 month free): none configured. If
  wanted, add in ASC + surface in the paywall (`product.subscription?
  .introductoryOffer`).
- **Family Sharing** for the subscription: currently off.
- **Grace behavior**: 30-day extension-side lenience past recorded expiry
  (plus whatever billing grace ASC is configured for — enable Billing
  Grace Period in ASC subscription settings, recommended). Tune
  `PlusEntitlement.expiryLenience` if desired.
- **Exact price points** per storefront (especially ISK).
- Whether the empty-dictionary FREE state should advertise Plus earlier
  (currently only Orðasafn's locked state, Settings, and the sync row do).
