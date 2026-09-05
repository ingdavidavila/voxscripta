# Releasing VoxVerba

The build produces an ad-hoc signed, hardened-runtime app that runs on this Mac.
Distributing it to anyone else needs a Developer ID and a notarization round trip
with Apple, which requires credentials this repository does not and should not
contain.

This document is what remains to be done, and by whom.

## What the build already does

```
./Tools/make-app-bundle.sh release
```

- Assembles `build/VoxVerba.app` with a real `Info.plist` and the generated icon.
- Signs with **hardened runtime enabled** (`--options runtime`), which
  notarization requires.
- Applies `build/VoxVerba.entitlements`.
- **Fails the build** if a network entitlement ever appears. The §26 privacy
  claim is only meaningful if something checks it, so the check is in the build
  rather than in a checklist.

Verify any build:

```
codesign -d -v build/VoxVerba.app            # expect flags=...(runtime)
codesign -d --entitlements - build/VoxVerba.app
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
    --entitlements build/VoxVerba.entitlements \
    build/VoxVerba.app
```

The `--timestamp` flag is required for notarization and is absent from the
ad-hoc path because a timestamp server call would be the one network request in
an otherwise offline build.

**2. Store notarization credentials once**, in the keychain rather than in a
file:

```
xcrun notarytool store-credentials voxverba-notary \
    --apple-id "you@example.com" \
    --team-id TEAMID \
    --password "app-specific-password"
```

Use an app-specific password from appleid.apple.com, never your Apple ID
password.

**3. Submit and staple:**

```
ditto -c -k --keepParent build/VoxVerba.app build/VoxVerba.zip
xcrun notarytool submit build/VoxVerba.zip --keychain-profile voxverba-notary --wait
xcrun stapler staple build/VoxVerba.app
spctl -a -vv build/VoxVerba.app        # now: accepted
```

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
