# plan.md: OTP Snatcher build plan

Companion to `CLAUDE.md`. That file is the *spec*; this is the *order of work*,
with acceptance criteria per phase and a recommended model + thinking level for
each.

Verified environment: Swift 6.3.3, Xcode 26.6, macOS 26.5.1 (Tahoe), Apple
Silicon. Repo is currently empty except `CLAUDE.md`.

Conventions and tooling are inherited from `osx-launchpad` (LaunchpadX), whose
`docs/update-ops.md` is explicitly written as a reusable playbook for future Mac
apps. Where this project must deviate from that playbook, the deviation is
called out and justified below. Nothing here needs a paid Apple Developer
account, because there isn't one.

---

## What the existing setup gives us for free

From `osx-launchpad`, reusable almost verbatim:

- **Xcode project + `xcodebuild archive`** as the build path (`CODE_SIGN_STYLE = Automatic`,
  no `DEVELOPMENT_TEAM` pinned).
- **`packaging/dmg/`**: `dmgbuild` driven by a `.py` settings file that reads a
  `dmg-settings.json` single source of truth, plus an `@2x` background PNG.
  `create-dmg` was already rejected (its Finder AppleScript silently fails to
  set the background on Tahoe). Do not re-evaluate that.
- **`.github/workflows/release.yml`**: tag-triggered (`v*`), `runs-on: macos-26`,
  `sudo xcode-select -s /Applications/Xcode.app`, archive, package dmg + zip,
  publish a Release to a separate public release repo, upload artifacts.
- **`CHANGELOG.md`** with `## [x.y.z]` sections; the workflow parses that section
  into release notes and stops at the next `## ` or `<!-- Template -->`.
- **Two-repo split**: private dev repo (source, packaging, workflow), public
  release repo (README, downloads).
- **`.gitignore`** shape: ignore `build/`, `*.dmg`, `*.zip`, key material.

What we deliberately do **not** inherit: Sparkle. See decision 3.

---

## Decisions made up front

**1. Build system: Xcode project primary, plus an optional `Package.swift` over
the same core sources.**
The CI playbook is built around `xcodebuild -project ... archive`, and a
menu-bar app needs a real bundle with an `Info.plist` anyway, so `.xcodeproj` is
the primary. `CLAUDE.md` also requires `swift test` to run offline with no
permissions; satisfy that by adding a dependency-free `Package.swift` whose
target `path` points at the *same* `OTPCore` source directory the Xcode target
compiles. One file set, two build systems, no duplicated build settings, because
the core is pure Swift with no settings to duplicate. If that dual setup ever
causes friction, drop `Package.swift` and use
`xcodebuild test -only-testing:OTPCoreTests` instead; the offline requirement is
about not needing `chat.db` or a network, not about SwiftPM specifically.

**2. Signing: create a long-lived self-signed code-signing certificate, and sign
every build with it, including dev builds. This is the most important decision in
the project.**

Why it matters: TCC keys the Full Disk Access grant to the code signature.
- LaunchpadX ships unsigned / ad-hoc (`CODE_SIGN_IDENTITY="-"`), which is fine
  for LaunchpadX because it needs no TCC grant.
- For an ad-hoc or unsigned binary, TCC has no certificate to pin to, so it
  identifies the app by cdhash. Every rebuild changes the cdhash, so **FDA dies
  on every single build during development, and on every update for users.**
  An app whose whole function requires FDA cannot ship that way.
- A real certificate gives a stable designated requirement (`identifier` +
  pinned leaf), so the grant survives rebuilds and version updates.

There is no Developer ID available, but TCC does not require Developer ID, only a
stable signature. So:
- Create a self-signed code-signing cert **once** in Keychain Access
  (Certificate Assistant, "Code Signing" type, ~10 year validity). Name it
  something stable, e.g. `Pooya Self-Signed Code Signing`.
- Export it as a `.p12` and back it up in the Apple Passwords app, right next to
  the Sparkle key that is already backed up there. If it is lost, every user
  (including you) must re-grant FDA.
- Sign local builds and CI release builds with the same cert. In CI, the `.p12`
  goes in as a base64 secret plus a password secret, imported into a temporary
  keychain (the standard `security create-keychain` / `import` / `list-keychains`
  dance).
- The existing free `Apple Development: pooyak@live.com (FTQDQPMU3H)` identity is
  an acceptable stopgap for local dev only. It is also a stable cert, so it also
  preserves FDA across rebuilds, but it expires annually and does not belong in
  CI. Use it on day one if you want to start before setting up the self-signed
  cert.
- Gatekeeper is unchanged by any of this: a self-signed app is still not
  notarized, so first launch is still right-click > Open, exactly as with
  LaunchpadX. That is already the documented, accepted posture.

**Verify, do not assume.** Phase 0 ends with an empirical test: grant FDA to the
signed bundle, rebuild twice, confirm DB reads still work. If TCC still revokes
the grant, the entire dev loop changes shape and every later phase needs to know
that immediately, not in week three.

**3. No Sparkle in this app. No network code at all.**
`CLAUDE.md`'s security rules say no network entitlement, no analytics, ever, and
that a PR adding a `URLSession` call is wrong. Sparkle is a `URLSession`-based
updater that runs in-process. An app holding Full Disk Access over your entire
message history should not be making network requests, and "we only talk to
GitHub" is not a meaningful distinction once the code path exists.

So: **Check for Updates opens the release page in the browser** (`NSWorkspace.open`,
no in-process networking). Consequences:
- No `SUFeedURL` / `SUPublicEDKey` in `Info.plist`, no Sparkle framework embed,
  no `appcast.xml` to maintain, no `SPARKLE_PRIVATE_KEY` secret needed.
- The rest of the release pipeline (tag > archive > dmg + zip > GitHub Release >
  changelog notes) is inherited unchanged. Only the appcast and Sparkle-signing
  steps get deleted from the workflow.

Also note: "no network **entitlement**" is not actually an enforcement mechanism
here, because entitlements only constrain sandboxed apps and this app cannot be
sandboxed. The rule has to be enforced by review and by a CI grep. Phase 5
adds that grep.

**4. FDA attaches to the `.app` bundle, not to `build/Debug/OTPSnatcher`.**
Never validate DB access by running the bare binary. Any test that touches the
real `chat.db` runs from the assembled, signed bundle. Corollary: signing and
bundling land in Phase 0, not Phase 6, because Phase 2 cannot be verified
without them.

**5. Notifications use `UNUserNotificationCenter`, not `NSUserNotification`.**
`CLAUDE.md` names the latter; it is long deprecated and does not work on Tahoe.
`UNUserNotificationCenter` needs a bundled app with a real bundle identifier and
an explicit authorization request. Update `CLAUDE.md` when this lands.

**6. Read-only WAL access can legitimately fail.**
Opening a WAL database `mode=ro` needs a readable `-shm` and no pending
recovery. If recovery is needed, SQLite returns `SQLITE_READONLY_RECOVERY`
("attempt to write a readonly database"). Fallback: copy `chat.db`, `chat.db-wal`
and `chat.db-shm` into a `0700` temp directory, read the copy, delete it in a
`defer`. Design `MessageStore` around this from the start.

**7. Distribution scope is an open question, and it is cheap to defer.**
If this stays a personal tool, skip the public release repo entirely and Phase 6
collapses to "one script that builds a signed `.app` and a local DMG". The
two-repo pipeline is worth it only if other people are meant to install this.
Build Phases 0 through 5 identically either way, and decide at Phase 6.

---

## Target layout

Mirrors `osx-launchpad` structure so the CI workflow and packaging files port
across with minimal editing.

```
OTPSnatcher.xcodeproj
Package.swift                     # optional, compiles OTPSnatcher/Core only
OTPSnatcher/
  Core/                           # pure, no permissions, fully unit-tested
    DigitNormalizer.swift
    CodeExtractor.swift
    SenderRule.swift
    Config.swift
  Messages/
    MessageStore.swift
    AttributedBodyDecoder.swift
    TypedStreamShim.h / .m        # only if Phase 2a says it is needed
    Watermark.swift
  App/
    AppDelegate.swift
    MenuBarController.swift
    DirectoryWatcher.swift
    ClipboardSink.swift
    Notifier.swift
    PermissionGate.swift
  Resources/Info.plist            # LSUIElement = true
Tests/
  CoreTests/
    DigitNormalizerTests.swift
    CodeExtractorTests.swift
    Fixtures/persian-otp-samples.json
  MessagesTests/
    MessageStoreTests.swift
    FixtureDB.swift
packaging/
  dmg/dmg-settings.json           # ported from osx-launchpad
  dmg/dmgbuild-settings.py
  dmg/dmg-background@2x.png
scripts/
  build-signed-app.sh             # archive + codesign with the stable cert
.github/workflows/release.yml     # ported, Sparkle steps removed
CHANGELOG.md
docs/signing-and-tcc.md           # why self-signed, how to re-grant FDA
```

---

## Phase 0: Scaffold, stable signing, and the TCC survival test

**Goal:** a launchable, menu-bar-only `OTPSnatcher.app`, signed with a stable
identity, that has been *proven* to keep its FDA grant across rebuilds.

**Work**
- Xcode project, macOS 26 deployment target, `LSUIElement = true`, a bundle
  identifier chosen once and never changed (TCC and Control Center both key off
  it). Link `libsqlite3.tbd`.
- Placeholder `NSStatusItem` with a stub menu, so launch is verifiable.
- Create the self-signed cert per decision 2; export and back up the `.p12`.
- `scripts/build-signed-app.sh`: archive, copy the `.app` out of the archive
  (the LaunchpadX trick, since `-exportArchive` insists on a signing identity),
  then `codesign --force --options runtime --timestamp --sign "$IDENTITY"`.
  Identity from an env var with a clear error when unset.
- Write `docs/signing-and-tcc.md` while the reasoning is fresh: which cert,
  where the backup is, and the exact symptom + fix when FDA silently dies.
- **The survival test**: grant the signed bundle FDA, read one row from
  `chat.db`, rebuild, read again, rebuild again, read again. Record the result in
  `docs/signing-and-tcc.md`.

**Acceptance:** menu-bar icon appears, no Dock icon, `codesign -dv --verbose=4`
shows the stable cert, and the survival test passes three builds in a row.

**Risk:** on Tahoe, Control Center can blacklist a bundle id so the status item
never appears even though the process is running (log: "Moving host to blocked
list"). Use the `menubar-fix` skill rather than debugging `NSStatusItem`.

**Model:** Sonnet 5, thinking **medium**. Mostly boilerplate, but the signing
script and the TCC experiment carry the project's biggest risk, so not low.
Escalate to Opus 5 / high if the survival test fails, because that result
invalidates decision 2 and needs a real rethink.

---

## Phase 1: DigitNormalizer + CodeExtractor (+ tests)

**Goal:** the part where the actual bugs live, built first, with no permissions
and no I/O.

**Work**
- `DigitNormalizer.normalize(_:)`: map U+0660 to U+0669 and U+06F0 to U+06F9 to
  ASCII; strip U+200E, U+200F, U+202A to U+202E, U+2066 to U+2069, U+200C. Work
  over unicode scalars, not chained `String` replacements.
- `SenderRule`: id, optional regex override, optional keyword anchors, label.
- `CodeExtractor.match(body:rule:)`:
  1. normalize
  2. rule pattern if present
  3. otherwise keyword-anchored search (`رمز`, `کد`, `کد تایید`, `verification`,
     `code`, `OTP`), taking the digit run nearest the keyword
  4. fall back to `\b(\d{4,8})\b`
  5. reject candidates that look like amounts (thousands separators, adjacent
     `ریال` / `تومان`) or account/card numbers (10+ digits, or four groups of
     four)
  Return the code plus which strategy matched, so tests and logs can record the
  strategy label. Never the code itself.
- `Tests/CoreTests/Fixtures/persian-otp-samples.json`: anonymized bodies with
  expected code or expected nil. Seed with the shapes Iranian senders actually
  use: bank OTP with the balance in the same SMS, ride-hailing, Shaparak, a
  two-code message, a code with ZWNJ inside the digits, and a message with an
  amount but no code. Grow this file every time a real miss appears.

**Acceptance:** tests green offline, including one proving the "amount in the
same SMS" case does not return the amount.

**Model:** Opus 5, thinking **medium**. The regex / keyword / rejection interplay
is where the product succeeds or fails, and it is cheap to get subtly wrong.
Sonnet 5 / low for mechanical fixture additions afterwards, Haiku 4.5 if you are
only reformatting samples you paste in.

---

## Phase 2: MessageStore against a fixture DB

**Goal:** given a `chat.db`-shaped SQLite file and a watermark, return new
inbound messages with bodies resolved, plus sender, service, date.

**Step 2a, probe the real blob format first (10 minutes).**
With FDA granted to the Phase 0 bundle (or to Terminal), dump the first bytes of
a few `attributedBody` values. A `streamtyped` prefix means a legacy NSArchiver
typedstream; `bplist00` means a keyed archive. Do not write a decoder before
knowing which. This decides whether the ObjC shim exists at all.

**Step 2b, decoder.**
- Typedstream case: `NSKeyedUnarchiver` cannot read it and `NSUnarchiver` is
  unavailable from Swift. Hence the tiny ObjC shim taking `NSData` and returning
  `NSString`. `NSUnarchiver` is deprecated and may be removed, so put it behind
  a protocol and document a hand-rolled typedstream reader as the fallback (only
  the subset needed to pull the string out of an archived
  `NSMutableAttributedString`).
- Keyed archive case:
  `NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from:)`,
  take `.string`, delete the shim from the project.
- Never regex the raw blob bytes. `CLAUDE.md` is right about this.
- Body resolution: `text` if non-empty, else decoded `attributedBody`, else skip
  the row and count it, logging the ROWID only.

**Step 2c, store.**
- Open `file:<path>?mode=ro` with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`. No
  `immutable=1`.
- The query from `CLAUDE.md`, plus `m.service`, ROWID ascending, parameterized
  watermark, and a `LIMIT` (say 200) so a first run after a long sleep cannot
  stall.
- Apple epoch nanoseconds since 2001-01-01: divide by 1e9; detect
  seconds-vs-nanoseconds by magnitude for old rows.
- The copy-to-temp fallback from decision 6, on `SQLITE_READONLY_RECOVERY`,
  `SQLITE_BUSY`, `SQLITE_CANTOPEN`.
- Return an error type that reliably distinguishes "no FDA" from "DB busy" from
  "malformed" from "wrong path". Phase 4's onboarding depends on that.

**Step 2d, fixture DB.**
`Tests/MessagesTests/FixtureDB.swift` writes a real SQLite file in a temp dir
with the `message` / `handle` / `chat` / `chat_message_join` subset, including
rows with NULL `text` and a genuine archived blob. Generate that blob once from a
real sample and check it in base64, so the test does not depend on the archiver
staying writable in future macOS versions. Cover: watermark advance, `is_from_me`
filtering, shortcode senders, NULL text, undecodable blob, seconds vs
nanoseconds.

**Acceptance:** tests green offline with nothing touching `~/Library/Messages`.
One separate integration test, skipped gracefully without FDA, reads the real DB
and asserts only that it can count rows. CI runs the fixture tests only, since
GitHub's runner has neither a `chat.db` nor a TCC grant.

**Model:** Opus 5, thinking **high**. Binary archive formats, SQLite WAL
read-only edge cases, and an error taxonomy a later phase depends on. This is
where a cheaper model writes code that works on your Mac and fails on someone
else's. If 2a reveals a keyed archive (the easy path), drop to Opus 5 / medium
for 2b through 2d.

---

## Phase 3: Directory watcher and watermark persistence

**Goal:** DB writes trigger a debounced fetch, exactly once per burst, with a
watermark that survives relaunch and never replays or skips.

**Work**
- `DirectoryWatcher` on `~/Library/Messages` via `FSEventStreamCreate` with
  `kFSEventStreamCreateFlagFileEvents`, ~0.1s latency, on a dedicated serial
  queue. Watch the directory, not the file.
- Coalesce to one `fetchNew` per ~150ms window. Exactly one fetch in flight, with
  a "dirty again" flag for events that arrive mid-fetch.
- Watermark in `~/Library/Application Support/OTPSnatcher/state.json`, written
  atomically (temp file then `replaceItemAt`), advanced only after a batch is
  fully processed. On first launch, initialize to current `MAX(ROWID)` so the app
  does not fire notifications for message history.
- Fallback poller: 1s `DispatchSourceTimer`, only while armed, enabled by config
  flag or automatically after N seconds of "DB mtime moved but no FSEvent".
- Note: enumerating the watched directory also needs FDA, so a watcher that never
  fires is a plausible permission symptom, not necessarily an FSEvents bug.

**Acceptance:** a harness that inserts a row into a *fixture* DB inside a watched
temp directory and asserts exactly one fetch; plus a live smoke test where a real
forwarded SMS produces exactly one match within ~2s.

**Model:** Sonnet 5, thinking **high**. Ordinary APIs, but the
debounce plus in-flight plus dirty-flag plus watermark-commit ordering is exactly
the kind of detail that quietly duplicates or drops events. Opus 5 / medium if
you would rather not review it line by line.

---

## Phase 4: Menu bar UI, config, FDA onboarding

**Goal:** the app is usable by someone who is not you.

**Work**
- Config at `~/Library/Application Support/OTPSnatcher/config.json`, exactly the
  schema in `CLAUDE.md`. Defaults written on first launch, reloaded on file
  change or menu action, no hardcoded sender ids anywhere in source.
- Menu: armed toggle, last-match time (never the code), sender list editor,
  clipboard TTL, notify toggle, "Open config file", "Grant Full Disk Access",
  "Check for Updates" (opens the releases page, per decision 3), Quit.
- The sender editor can be an AppKit sheet, or for v1 just "Open config file" in
  `$EDITOR` plus a validation error surfaced in the menu. The JSON path is
  defensible for v1; decide by how much time is left.
- `PermissionGate`: probe read at launch and on arm. On the "no FDA" error from
  Phase 2, show a plain-language window (why FDA is needed, that nothing ever
  leaves the machine) with a button opening
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
  Re-probe on app activation, since granting FDA usually means the app must be
  relaunched or toggled.
- `UNUserNotificationCenter` authorization requested lazily on the first
  would-be notification, not at launch.

**Acceptance:** a fresh user account with no FDA reaches working state using only
in-app guidance. Config edits take effect without relaunch.

**Model:** Sonnet 5, thinking **medium** for UI, config codec and menu plumbing.
One targeted Opus 5 / high pass on `PermissionGate` alone, because correctly
telling "no permission" from "DB busy" from "wrong path" is the difference
between a useful prompt and a mystery.

---

## Phase 5: Clipboard sink and auto-clear

**Goal:** the code lands in `⌘V`, never reaches clipboard-manager history, and
disappears on schedule without stomping anything the user copied since.

**Work**
- `NSPasteboard.general.clearContents()`, then one `NSPasteboardItem` carrying
  the code as `.string` **and** a value for `org.nspasteboard.ConcealedType`
  (the UTI Alfred, Raycast and Maccy honor). Record the returned `changeCount`
  and the exact string written.
- Auto-clear timer at `clearClipboardAfterSeconds`. On fire, clear only if
  `changeCount` still matches **and** the current string still equals what was
  written. Otherwise do nothing.
- Cancel and replace the pending clear when a newer code arrives.
- CI guard: a script step that greps `OTPSnatcher/` for
  `URLSession|NSURLConnection|https?://|CFNetwork` and fails the build on a hit.
  This is the actual enforcement of the no-network rule, since entitlements do
  not constrain an unsandboxed app.
- No `print` / `os_log` of bodies or codes in any configuration.

**Acceptance:** unit tests over the "should I clear" predicate with a faked
pasteboard; a manual test that copying something else during the TTL leaves it
alone; Maccy or Raycast shows no entry for the code.

**Model:** Sonnet 5, thinking **high**. Small surface, but the change-count race
and the concealed-type detail are easy to write plausibly and wrongly, and the
failure mode is a leaked OTP sitting in a third-party history database.

---

## Phase 6: Packaging and release

**Goal:** a DMG someone can install, built by pushing a tag, with FDA that
survives updates.

Port from `osx-launchpad`, adapting rather than reinventing:

- `packaging/dmg/*`: copy the `.py` + JSON + background, change the volume name,
  app name and output path. Regenerate the background art at
  `imagePixels = windowPoints x 2` or `dmgbuild` stretches it.
- `.github/workflows/release.yml`: copy, then
  - change `APP_NAME`, `SCHEME`, `PROJECT`, `RELEASE_REPO`
  - **replace** the ad-hoc `CODE_SIGN_IDENTITY="-"` archive step with an import
    of the self-signed `.p12` from secrets into a temp keychain, and sign with
    it. This is the one substantive change from LaunchpadX, and decision 2
    explains why it is not optional here.
  - **delete** the Sparkle steps (fetch tools, `sign_update`, appcast update)
    per decision 3. Keep the zip if you want, or ship the DMG alone.
  - keep the tag trigger, `macos-26` runner, `xcode-select`, the
    CHANGELOG-to-release-notes extraction, and the artifact upload.
- `CHANGELOG.md` seeded in the LaunchpadX format, since the workflow parses it.
- README section stating plainly: not notarized, first launch is right-click >
  Open, and the app needs Full Disk Access with a one-paragraph explanation of
  why an SMS-reading tool asks for that.
- Per decision 7: if this stays personal, do all of the above except the release
  repo and the workflow, and keep `scripts/build-signed-app.sh` plus a local
  `dmgbuild` invocation.

**Acceptance:** `git tag v0.1.0 && git push origin v0.1.0` produces a Release
with a DMG that installs on a second Mac, is granted FDA once, and keeps that
grant after installing the next tagged version.

**Model:** Sonnet 5, thinking **medium**. Almost entirely porting a playbook that
already works. The keychain-import-in-CI step is the only genuinely new part, and
it is well-trodden.

---

## Phase 7: Security and privacy audit pass

**Goal:** confirm the app deserves the Full Disk Access it holds.

**Work**
- Read every file asking: does anything log a body or a code on any path,
  including error paths and `debugDescription`? Does anything write to
  `chat.db`? Any file written outside Application Support? Any network symbol?
- Audit the temp-copy fallback specifically. It materializes the user's entire
  message database on disk: unique directory, `0700`, removed in a `defer` on
  every exit path including throws, never inside a synced or user-visible folder.
- Verify the concealed-type behavior against at least two real clipboard
  managers.
- Confirm the CI grep from Phase 5 actually fails a build when you plant a
  `URLSession` call in a scratch branch. An untested guard is not a guard.
- Then update `CLAUDE.md`: the notification API correction, whatever 2a found
  about `attributedBody`, the WAL fallback, the signing decision, and the fact
  that Sparkle is intentionally absent.

**Model:** Opus 5, thinking **xhigh**. Adversarial reading of the whole tree at
once, on a codebase holding FDA over your message history. Cheap insurance
relative to what a miss costs. Run `/security-review` first and treat its output
as input to the audit, not as the audit.

---

## Model and thinking summary

| Phase | Work | Model | Thinking |
|---|---|---|---|
| 0 | Scaffold, self-signed cert, TCC survival test | Sonnet 5 | medium |
| 1 | DigitNormalizer, CodeExtractor, fixtures | **Opus 5** | medium |
| 2 | MessageStore, attributedBody, WAL fallback | **Opus 5** | **high** |
| 3 | FSEvents watcher, debounce, watermark | Sonnet 5 | high |
| 4 | Menu bar, config, onboarding | Sonnet 5 | medium |
| 4b | `PermissionGate` error taxonomy only | **Opus 5** | high |
| 5 | Clipboard, concealed type, auto-clear, CI grep | Sonnet 5 | high |
| 6 | Port dmgbuild + release workflow, CI signing | Sonnet 5 | medium |
| 7 | Security and privacy audit | **Opus 5** | **xhigh** |

Side rules:
- Fixture expansion, sample formatting, README and CHANGELOG prose: Haiku 4.5,
  low. Keep it away from the extractor logic and the pasteboard code.
- Fast mode (`/fast`, Opus 5 with faster output) suits Phases 0, 4 and 6, where
  the work is mechanical but Opus judgment is still worth having.
- Debugging "reads suddenly fail after a rebuild": Opus 5, high, and read
  `docs/signing-and-tcc.md` before touching SQLite. Decision 2 should prevent
  this class of bug entirely; if it recurs, the cause is a changed signature, not
  the database.
- `max` thinking is not warranted anywhere in this project. Phase 2 and Phase 7
  are the only places where reasoning depth changes the outcome, and `high` /
  `xhigh` cover them.

---

## Remaining unknowns, all resolved by doing rather than asking

1. **Does a self-signed cert actually preserve the FDA grant across rebuilds?**
   Answered by the Phase 0 survival test. If no, Phase 0 escalates to Opus 5 /
   high and the dev loop gets redesigned around re-granting.
2. **Is `attributedBody` on Tahoe 26.5 a typedstream or a keyed archive?**
   Answered by step 2a, which decides whether the ObjC shim exists.
3. **Public release repo, or personal tool only?** Decided at Phase 6. Phases 0
   through 5 are identical either way, so it blocks nothing.
