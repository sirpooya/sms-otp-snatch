# Signing and TCC

Why this app is fussier about code signing than a normal Mac app, and what to do
when message reads suddenly stop working.

## The problem in one paragraph

OTP Snatcher does nothing without Full Disk Access. FDA is granted by the user in
System Settings, and macOS remembers that grant by **code signature**, not by
file path. For a properly signed app, the recorded identity is the *designated
requirement*: the bundle identifier plus a pin to the signing certificate. That
requirement does not change when you rebuild, so the grant survives. For an
**unsigned or ad-hoc signed** binary there is no certificate to pin, so macOS
falls back to the code directory hash, which changes on every build. The grant
then evaporates every time you compile, and for users every time they update.

That is why this project signs even debug builds, and why `build-signed-app.sh`
refuses to ad-hoc sign unless you explicitly ask it to.

## What we verified, on this machine

macOS 26.5.1, Xcode 26.6, signing with the free `Apple Development` identity:

```
$ codesign -d -r- build/OTPSnatcher.app
designated => identifier "com.pooya.otpsnatcher"
    and anchor apple generic
    and certificate leaf[subject.CN] = "Apple Development: pooyak@live.com (FTQDQPMU3H)"
    and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
```

Rebuilt after a real code change:

| | build 1 | build 3 |
|---|---|---|
| CDHash | `c5a6458f5904…` | `815c93404637…` |
| Designated requirement | as above | **byte-identical** |

The hash moved, the requirement did not. That is the property the FDA grant
depends on, and it holds.

One caveat worth knowing: a comment-only edit produces a byte-identical binary
and therefore an identical CDHash, so use a real code change if you ever want to
repeat this check.

## Which identity to use

Preference order, and `build-signed-app.sh` picks automatically in this order:

1. **Developer ID Application.** Not available (no paid account) and not
   required. It would additionally allow notarization.
2. **A self-signed code-signing certificate.** Create it once with
   `scripts/make-signing-identity.sh`. No Apple account, no annual expiry, works
   for local builds and CI alike. This is the recommended setup for releases.
3. **`Apple Development`.** Already present in the login keychain and perfectly
   stable, so it is the right choice for day-to-day development. It expires
   annually; when it renews, the certificate changes and FDA must be granted
   once more.

Whatever you choose, **back the private key up** (Apple Passwords, next to the
Sparkle key). Losing it means every existing install has to re-grant FDA.

Gatekeeper is a separate question and is unchanged by any of this: none of these
options is notarized, so first launch is right-click then Open, exactly as with
LaunchpadX.

## Symptom guide

**Reads worked, then stopped after a rebuild.**
The signing identity changed. Check `codesign -d -r- build/OTPSnatcher.app` and
compare the designated requirement to the last known-good one. Re-add the app
under Full Disk Access. Do not go looking at SQLite.

**The app says it needs Full Disk Access even though it is switched on.**
The entry in the list refers to a different signature (a previous ad-hoc build,
or a build from a different certificate). Remove the entry with the minus button,
then add `build/OTPSnatcher.app` again.

**Reads work from Terminal but not from the app.**
Expected. FDA is granted per binary. Terminal having it says nothing about the
app. Grant it to `OTPSnatcher.app` specifically, and note that the grant belongs
to the **bundle**, never to `.build/release/OTPSnatcher`.

**The menu bar icon never appears, though the process is running.**
Not a signing problem. On macOS 26, Control Center can blacklist a bundle id
(the log line is "Moving host to blocked list"). Fix Control Center's tracked
applications list rather than debugging `NSStatusItem`.

## Rules

- The bundle identifier `com.pooya.otpsnatcher` is chosen once and never changed.
  TCC keys the grant to it, and Control Center tracks menu-bar items by it, so a
  rename orphans both.
- Never commit key material. `.gitignore` excludes `*.p12`, `*.pem` and friends.
- FDA cannot be requested programmatically. The app detects the failure and deep
  links to `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
