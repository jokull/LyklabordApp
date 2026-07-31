# Headless TestFlight release

Lyklaborð can be archived, cloud-signed, exported, and uploaded without an
active Xcode GUI login. `xcodebuild` authenticates directly with the App Store
Connect API key; `asccli` handles the App Store Connect operations.

Run the build in a detached scratch worktree. The archive phase stamps
`App/BuildInfo.swift`, and isolating that write keeps the main checkout clean
and ensures the stamp describes the exact commit being shipped.

## Fixed App Store Connect identifiers

| Item | Value |
| --- | --- |
| App | Lyklaborð (`6792012916`) |
| Bundle ID | `is.solberg.lyklabord` |
| Team ID | `RDC8539AWM` |
| API account | `lyklabord` |
| API key ID | `H8RC4UN83P` |
| API issuer ID | `bf2219f6-0d8f-4415-8449-1bef292d2146` |
| Internal group | Innri prófun (`6dc2522d-7486-4787-b8b9-2b7b221fd845`) |
| External group | Vinir (`12ddcc4e-e5d1-4224-9ac7-484d7739b655`) |

The private key is expected at
`/Users/jokull/.appstoreconnect/private_keys/AuthKey_H8RC4UN83P.p8`. Never
commit the `.p8` file. The identifiers above are configuration, not the
private credential.

## 1. Preflight and choose the build number

Start in a clean main checkout at the commit to release:

```bash
asccli auth use lyklabord
asccli auth check --output table
git status --short
RELEASE_VERSION=1.1

asccli builds next-number \
  --app-id 6792012916 \
  --version "$RELEASE_VERSION" \
  --platform ios \
  --output table
```

Use the returned number as `RELEASE_BUILD` below. Do not reuse an uploaded
build number, even if an earlier upload failed processing.

## 2. Create the isolated build checkout

```bash
RELEASE_ROOT="$(git rev-parse --show-toplevel)"
RELEASE_COMMIT="$(git rev-parse HEAD)"
RELEASE_PARENT="$(mktemp -d /tmp/lyklabord-release.XXXXXX)"
RELEASE_WORKTREE="$RELEASE_PARENT/checkout"
RELEASE_VERSION=1.1
RELEASE_BUILD=7

git worktree add --detach "$RELEASE_WORKTREE" "$RELEASE_COMMIT"
cd "$RELEASE_WORKTREE"
xcodegen generate
```

`RELEASE_BUILD=7` is an example; substitute the number from the preflight.
The generated `.xcodeproj`, archive, logs, export, and stamped source all stay
inside the scratch worktree.

## 3. Archive with API-key authentication

```bash
ASC_KEY_PATH="/Users/jokull/.appstoreconnect/private_keys/AuthKey_H8RC4UN83P.p8"
ASC_KEY_ID="H8RC4UN83P"
ASC_ISSUER_ID="bf2219f6-0d8f-4415-8449-1bef292d2146"
mkdir -p build
set -o pipefail

xcodebuild \
  -project Lyklabord.xcodeproj \
  -scheme Lyklabord \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/Lyklabord.xcarchive \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  MARKETING_VERSION="$RELEASE_VERSION" \
  CURRENT_PROJECT_VERSION="$RELEASE_BUILD" \
  archive 2>&1 | tee build/archive.log
```

Before export, verify both embedded bundles match the App Store version. A
TestFlight build for 1.0 can process as `VALID` but becomes `Invalid Binary`
when attached to an App Store 1.1 record.

```bash
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  build/Lyklabord.xcarchive/Products/Applications/Lyklabord.app/Info.plist)" = "$RELEASE_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  build/Lyklabord.xcarchive/Products/Applications/Lyklabord.app/PlugIns/LyklabordKeyboard.appex/Info.plist)" = "$RELEASE_VERSION"
```

An Apple Development signature on the intermediate archive is normal. The
export step replaces it with cloud-managed Apple Distribution signing.

## 4. Export the App Store IPA

```bash
xcodebuild \
  -exportArchive \
  -archivePath build/Lyklabord.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist docs/TestFlightExportOptions.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  2>&1 | tee build/export.log
```

`docs/TestFlightExportOptions.plist` requests App Store Connect export,
automatic cloud signing, Production iCloud entitlements, and symbol export.
Confirm `build/export/DistributionSummary.plist` says
`Cloud Managed Apple Distribution` for both the app and keyboard extension.

The `asccli builds archive` convenience command currently does not forward
the three `-authenticationKey…` options to `xcodebuild`. With a lapsed Xcode
account session it therefore fails with “No Accounts” or a missing
distribution certificate. Use raw `xcodebuild` for archive/export as above;
an Xcode GUI login and a locally installed distribution certificate are not
required.

Do not create a local distribution certificate as a fallback for that error.
It is neither required nor used by this flow; the authenticated export creates
or selects Apple's cloud-managed signing asset.

## 5. Preserve and upload the IPA

```bash
mkdir -p "$RELEASE_ROOT/.build/testflight-$RELEASE_VERSION-$RELEASE_BUILD"
cp build/export/*.ipa \
  "$RELEASE_ROOT/.build/testflight-$RELEASE_VERSION-$RELEASE_BUILD/Lyklaborð-$RELEASE_VERSION-$RELEASE_BUILD.ipa"

asccli builds upload \
  --app-id 6792012916 \
  --file "$RELEASE_ROOT/.build/testflight-$RELEASE_VERSION-$RELEASE_BUILD/Lyklaborð-$RELEASE_VERSION-$RELEASE_BUILD.ipa" \
  --version "$RELEASE_VERSION" \
  --build-number "$RELEASE_BUILD" \
  --platform ios \
  --wait \
  --output table
```

The `--wait` command is quiet while Apple processes the upload. To distinguish
normal processing from a stalled local command, inspect the upload record in a
second terminal:

```bash
asccli builds uploads list \
  --app-id 6792012916 \
  --output table
```

`PROCESSING` means Apple has the binary. The build appears in `builds list`
after that record becomes `COMPLETE`.

The app declares `ITSAppUsesNonExemptEncryption = false`, so processing should
resolve export compliance automatically. Verify it rather than assuming:

```bash
asccli builds list \
  --app-id 6792012916 \
  --platform ios \
  --version "$RELEASE_VERSION" \
  --limit 20 \
  --output table
```

If App Store Connect still asks, use the build ID from that listing:

```bash
asccli builds set-encryption-compliance \
  --build-id "$ASC_BUILD_ID" \
  --uses-non-exempt-encryption false \
  --output table
```

## 6. Release to TestFlight groups

Set the beta notes, then add the internal and external groups:

```bash
asccli builds update-beta-notes \
  --build-id "$ASC_BUILD_ID" \
  --locale en-US \
  --notes "$BETA_NOTES" \
  --output table

asccli builds add-beta-group \
  --build-id "$ASC_BUILD_ID" \
  --beta-group-id 6dc2522d-7486-4787-b8b9-2b7b221fd845 \
  --output table

asccli builds add-beta-group \
  --build-id "$ASC_BUILD_ID" \
  --beta-group-id 12ddcc4e-e5d1-4224-9ac7-484d7739b655 \
  --output table
```

Innri prófun is internal and becomes available without Beta App Review. Vinir
is external. Check its review state after assigning it:

```bash
asccli beta-review submissions list \
  --build-id "$ASC_BUILD_ID" \
  --output table
```

If no submission exists, submit the build using the app's saved beta-review
contact details:

```bash
asccli beta-review submissions create \
  --build-id "$ASC_BUILD_ID" \
  --output table
```

The external group becomes usable when the submission reaches `APPROVED`.

## 7. Verify and clean up

Record the released commit, version/build, IPA checksum, processing state, and
group results. Then remove the scratch checkout only after the IPA and any
needed logs have been copied out:

```bash
cd "$RELEASE_ROOT"
git -C "$RELEASE_WORKTREE" restore App/BuildInfo.swift
git worktree remove "$RELEASE_WORKTREE"
rmdir "$RELEASE_PARENT"
git status --short
```

The restored file is the build-generated stamp in the disposable checkout,
not a source change. The final `git status` should match the preflight.
`.build/` is ignored; the IPA is retained locally without entering the
source-control history.
