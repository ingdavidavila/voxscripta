# Releasing Vox Scripta

The build produces an ad-hoc signed, hardened-runtime app that runs on this Mac.
Distributing it to anyone else needs a Developer ID and a notarization round trip
with Apple, which requires credentials this repository does not and should not
contain.

This document is what remains to be done, and by whom.

## What the build already does

```
./Tools/make-app-bundle.sh release
```

- Assembles `build/VoxScripta.app` with a real `Info.plist` and the generated icon.
- Signs with **hardened runtime enabled** (`--options runtime`), which
  notarization requires.
- Applies `build/VoxScripta.entitlements`.
- **Fails the build** if a network entitlement ever appears. The §26 privacy
  claim is only meaningful if something checks it, so the check is in the build
  rather than in a checklist.

Verify any build:

```
codesign -d -v build/VoxScripta.app            # expect flags=...(runtime)
codesign -d --entitlements - build/VoxScripta.app
```

`spctl -a -vv` will report **rejected** on an ad-hoc build. That is correct and
expected — Gatekeeper is asking for notarization, not reporting a defect.

## What requires your Apple Developer account

These steps need a paid Apple Developer Program membership. Nobody but the
account holder can perform them.

**1. Sign with a Developer ID certificate** instead of ad-hoc:

```
codesign --force --options runtime --timestamp \
    --sign "Developer ID Application: YOUR NAME (TEAMID)" \
    --entitlements build/VoxScripta.entitlements \
    build/VoxScripta.app
```

The `--timestamp` flag is required for notarization and is absent from the
ad-hoc path because a timestamp server call would be the one network request in
an otherwise offline build.

**2. Store notarization credentials once**, in the keychain rather than in a
file:

```
xcrun notarytool store-credentials voxscripta-notary \
    --apple-id "you@example.com" \
    --team-id TEAMID \
    --password "app-specific-password"
```

Use an app-specific password from appleid.apple.com, never your Apple ID
password.

**3. Submit and staple:**

```
ditto -c -k --keepParent build/VoxScripta.app build/VoxScripta.zip
xcrun notarytool submit build/VoxScripta.zip --keychain-profile voxscripta-notary --wait
xcrun stapler staple build/VoxScripta.app
spctl -a -vv build/VoxScripta.app        # now: accepted
```

## iOS and iPadOS

The Mac path above is notarization. iOS has no notarization — it has App Store
Connect, and nothing else. There is no ad-hoc equivalent of a shippable build:
every route to another person's device goes through an Apple account.

What already works:

- `ios/VoxScripta.xcodeproj` builds and runs on a physical iPhone and iPad with
  a free personal team, which is how the app has been tested so far. A free-team
  build expires after 7 days and cannot be given to anyone else.
- `ITSAppUsesNonExemptEncryption` is already `false` in
  `ios/VoxScripta/Info.plist`. This is correct and deliberate: the app performs
  no encryption of its own and makes no network connection, so the annual
  self-classification report does not apply. Getting this wrong is the single
  most common cause of a build being held at submission, so it is set in the
  plist rather than answered by hand in the web form each time.
- Device and simulator are different *platforms*, not architectures, so their
  slices cannot be combined with `lipo`. `VOXSCRIPTA_IOS_SLICE` selects which
  one the engine dependencies are built for; a mismatch shows up as a link
  error naming the missing architecture, not as a runtime failure.

### Building for the simulator, and the trap in it

```
VOXSCRIPTA_IOS_SLICE=sim xcodebuild -project ios/VoxScripta.xcodeproj \
    -scheme VoxScripta -configuration Debug \
    -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Without that variable the link fails with:

```
ld: building for 'iOS-simulator', but linking in object file
    (build/ffmpeg/ios/prefix/lib/libavformat.a) built for 'iOS'
```

`build/ffmpeg/ios/` and `build/engines/ios/` hold the **device** slices;
`ios-sim` holds the simulator's. Both are built by `Tools/build-ffmpeg.sh` and
`Tools/build-engines.sh`, and both already exist in a working checkout.

**The trap: setting the variable is not enough on its own.** It is read while
the package manifest is evaluated, but Xcode bakes the resulting linker flags
into its cached build description, and an environment variable does not
invalidate that cache. So the second build quietly reuses the first build's
slice and fails with the identical error, which reads as though the variable
were being ignored — it is not; it was never consulted.

Two things invalidate the cache: editing `Package.swift`, or removing derived
data. The second is the reliable one:

```
rm -rf ~/Library/Developer/Xcode/DerivedData/VoxScripta-*
```

Clearing `~/Library/Caches/org.swift.swiftpm/manifests` does **not** help; the
stale value is in the build description, not in the manifest cache. If you have
already built for the device in the same derived data, assume the cache is
poisoned and clear it before the first simulator build rather than after the
first confusing failure. Switching back to the device is the same problem in
reverse.

A StoreKit configuration file is also not applied by a build run this way — see
step 3a above. `simctl` has no equivalent of it, so a simulator run launched
from the command line always reports no plans.

What needs the paid Apple Developer Program, in order:

**1. Enroll.** $99/year. Everything below is blocked until this clears, which
takes 24–48 hours and sometimes longer for an organization rather than an
individual. This is the long-lead item: start it before anything else on this
list.

**2. Register the bundle identifier and create the App Store Connect record.**
The identifier has to match the project's `PRODUCT_BUNDLE_IDENTIFIER` exactly.

**3. Create the subscription products.** Two of them, with these exact
identifiers, both auto-renewing and both **in the same subscription group** so
that holding one replaces the other rather than stacking:

| Identifier | Duration |
| --- | --- |
| `voxscripta.monthly` | 1 month |
| `voxscripta.yearly` | 1 year |

They are compiled into `SubscriptionProducts` and the store is asked for those
two strings and nothing else, so a typo here is a paywall that silently offers
nothing. Set **no introductory offer**: the three-day trial is the engine's,
enforced from `firstSeen` in `JobRunner` on every platform including the ones
with no store, and a StoreKit free trial would hand a second free period on top
of it. Price tiers are set per territory; the prices are never formatted in
code, so nothing needs changing here when they move.

Guideline 3.1.2 governs what a subscription may be sold as; 5.1.1(v) governs
what may be required to use the app at all.

Selling also needs the **Paid Applications Agreement** active, with banking and
tax details on file. That is a separate step from enrollment and usually the
slower one, because it waits on bank verification rather than on Apple. The
products can be drafted without it but nothing can be sold, so start it in the
same sitting as enrollment.

**3a. Before any of that: run the purchase flow against the local
configuration.** `ios/VoxScripta.storekit` defines both products with
test prices, so a debug build launched **from Xcode** sells them without App
Store Connect having anything in it. The scheme already references the file, so
it is active on ⌘R with no setup; the purchases are local, cost nothing and can
be cleared from Xcode's **Debug ▸ StoreKit ▸ Manage Transactions**.

The prices in that file are for the simulator only and are not a pricing
decision — the real ones come from App Store Connect per territory.

What to check while it is running: both plans appear with prices, the yearly row
shows its computed saving, a purchase completes and the trial banner stops
offering, **Restore Purchase** finds the subscription afterwards, and the Terms
of Use and Privacy Policy links open. Pair it with
`VOXSCRIPTA_ENTITLEMENT=expired` in the scheme's environment to see the wall
and the purchase that clears it, without waiting three days.

`Tests/VoxScriptaAppTests/StoreKitConfigurationTests.swift` holds that file to
the code — identifiers, periods, one group, no introductory offer, the
advertised saving — and runs in the ordinary suite. What it cannot do is run a
purchase: `SKTestSession` needs a host application with a container, and a
SwiftPM test bundle runs inside `swiftpm-testing-helper`, which has neither. So
the checks above are a manual pass done once from Xcode, not a test that guards
them.

**4. Archive and upload:**

```
xcodebuild -project ios/VoxScripta.xcodeproj -scheme VoxScripta \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath build/VoxScripta.xcarchive archive
xcodebuild -exportArchive -archivePath build/VoxScripta.xcarchive \
    -exportOptionsPlist ios/ExportOptions.plist -exportPath build/ios-export
xcrun altool --upload-app -f build/ios-export/VoxScripta.ipa \
    -t ios --apiKey KEYID --apiIssuer ISSUERID
```

`ios/ExportOptions.plist` does not exist yet and has to name the real team ID,
so it is written once enrollment completes rather than committed with a
placeholder.

**5. Screenshots.** Required per device class, and the iPad set has never been
captured. 6.7" iPhone and 13" iPad are the two mandatory sizes; the simulator
can produce both.

**6. Replace the placeholder contact address.** `Docs/privacy-policy.md` still
publishes `privacy@example.com`, and so do the two pages actually served from
the `gh-pages` branch — `privacy.html` and `terms.html`, which are the ones App
Review reads and which are public now. App Review reads the privacy policy, and a
policy with a non-functional address on it is a rejection. `Docs/PRIVACY.md`
lists this as the first of its outstanding items.

### Android

`Docs/PORTING.md` holds the plan of record: the Flutter interface over
`libVoxScriptaFFI.so`, with the Swift engine built by the Swift SDK for Android.

**Where it stands (checked 2026-11-24).** An x86_64 debug build runs on the
emulator: it opens the engine, imports a file, runs the pipeline up to
transcription, asks for the microphone and records. Nothing has run on a real
phone, and transcription does not work on Android at all yet (see "Not ready"
below).

**Permissions.** The release manifest declares `RECORD_AUDIO` and nothing else —
**no `INTERNET`**. Recording is the one permission the app needs, and it is
requested at the moment someone starts recording, never at launch. The no-network
position stays until billing requires `INTERNET`, because an app that cannot
reach the network is a privacy claim a user can verify from the Play listing
without trusting us. Debug builds add `INTERNET` for the Flutter tooling; release
builds do not. This was read from the merged manifest of a real
`flutter build appbundle --release`, and no build step asserts it yet — one
should, on the release variant only.

**Not ready to submit.** `flutter build appbundle --release` does produce an AAB
(106 MB), but it cannot be uploaded:

- **Signed with the debug key.** `build.gradle.kts` still says "Signing with the
  debug keys for now". Play rejects that. An upload keystore and a signing
  config are needed, and the keystore is David's to create and keep.
- **The engine is present for x86_64 only.** The bundle's `arm64-v8a` and
  `armeabi-v7a` folders hold Flutter's libraries but no `libVoxScriptaFFI.so`
  and no FFmpeg libraries, so on a phone the engine would fail to load. Phones
  are arm64; x86_64 is only the emulator. The arm64 build route is the same
  (`Tools/stage-android.sh arm64-v8a`) but has not been run, and the engine
  libraries are git-ignored under `jniLibs/`, so CI cannot build the app until
  that step is part of it.
- **The x86_64 engine is a debug build** (73 MB). Release engine sizes have not
  been measured, and the size of a `small` model on top of them is the
  deciding number for how it is delivered.
- **No Whisper model, and no way to give the engine one.** The engine looks for
  `build/models/ggml-base.bin` relative to the build tree, so every Android
  transcription fails with "a required model asset is missing". It needs a
  settable model location and a delivery decision (Play Asset Delivery or a
  download). Both are open, and the second is David's.
- **Not yet checked:** that the native libraries meet Play's 16 KB page-size
  requirement (from memory, required for new targets-Android-15 submissions;
  verify against current Play policy), and that the application id
  `dev.voxscripta.voxscripta` is the one to keep, since it cannot change once
  published.
- **Needs David:** a Google Play developer account, the keystore above, and the
  billing decision (one subscription with two base plans is the Play equivalent
  of an Apple group).

## Sandboxing

The app currently ships **unsandboxed** with
`com.apple.security.files.user-selected.read-only`.

Direct distribution does not require the sandbox. The Mac App Store does, and
enabling it would need:

- `com.apple.security.app-sandbox` set to `true`
- security-scoped bookmarks to be created *with* the entitlement, which the code
  already attempts and falls back from — see `ProjectStore.makeBookmark`
- a review of where projects are written, since the container path changes

None of that affects the privacy guarantee either way: the absence of a network
entitlement is what makes the claim, and it holds sandboxed or not.

## What is deliberately absent

- **No network entitlement.** The build refuses to produce one.
- **No analytics, crash reporter, or first-run phone-home.**
- **No accounts and no credentials**, so nothing to store in the keychain on a
  user's behalf.
