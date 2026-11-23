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

What needs the paid Apple Developer Program, in order:

**1. Enroll.** $99/year. Everything below is blocked until this clears, which
takes 24–48 hours and sometimes longer for an organization rather than an
individual. This is the long-lead item: start it before anything else on this
list.

**2. Register the bundle identifier and create the App Store Connect record.**
The identifier has to match the project's `PRODUCT_BUNDLE_IDENTIFIER` exactly.

**3. Create the subscription products.** `configuredSubscriptionService()` in
`Sources/VoxScriptaUI/Paywall/SubscriptionConfiguration.swift` returns `nil`
today, which means the paywall renders but cannot sell anything. StoreKit
products have to exist in App Store Connect before that function can return a
real service, so the product definitions come first and the code change second.
Guideline 3.1.2 governs what a subscription may be sold as; 5.1.1(v) governs
what may be required to use the app at all.

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
publishes `privacy@example.com`. App Review reads the privacy policy, and a
policy with a non-functional address on it is a rejection. `Docs/PRIVACY.md`
lists this as the first of its outstanding items.

### Android

`Docs/PORTING.md` holds the plan of record: the Flutter interface over
`libVoxScriptaFFI.so`, with the Swift engine built by the Swift SDK for Android.
No Android build exists yet, and the manifest deliberately declares **no
permissions at all** — including no `INTERNET`. That stays until billing
requires it, because an app that cannot reach the network is a privacy claim a
user can verify from the Play listing without trusting us.

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
