# CLAUDE.md — OTP Snatcher (macOS)

Context file for Claude Code. Read this before touching the codebase.

## What this is

A tiny macOS menu-bar utility that watches SMS messages arriving from a specific
sender (via iPhone → Mac Continuity **Text Message Forwarding**), extracts the
one-time code, and puts it on the clipboard automatically.

Goal: never manually copy an OTP again. Phone buzzes → code is already in
`⌘V` on the Mac.

## How the data actually arrives (do not re-derive this)

- Handoff/Universal Clipboard have **no public API** for this. Irrelevant here.
- The real mechanism is **Text Message Forwarding**: iPhone relays SMS over the
  internet to Macs on the same Apple Account. Setup is user-side:
  iPhone → Settings → Apps → Messages → Text Message Forwarding → enable the Mac,
  enter the 6-digit code shown on the Mac.
- Forwarded SMS lands in Messages.app and is persisted to
  `~/Library/Messages/chat.db` (SQLite, WAL mode).
- Latency is push-speed (~1–2s). Works over iPhone Personal Hotspot too.
- **We read the DB. That is the whole ingestion strategy.** There is no
  notification API, no Messages plugin API, no supported alternative.

## Hard constraints

| Constraint | Consequence |
|---|---|
| Reading `chat.db` requires **Full Disk Access** (TCC) | App **cannot** be sandboxed |
| Not sandboxed | **No Mac App Store.** Ship a notarized, stapled DMG (Developer ID) |
| FDA cannot be requested programmatically | Detect the failure, then deep-link the user to the pane |
| DB is WAL | Open read-only, but **not** `immutable=1` (would miss `-wal` contents); read-only opens can still fail, so a snapshot fallback is required |
| TCC pins the grant to the code signature | **Never ship or develop ad-hoc/unsigned.** An unsigned binary is identified by cdhash, which changes every build, so FDA dies on every rebuild and every user update. Any real certificate fixes it; a paid account is not needed. See `docs/signing-and-tcc.md` |
| No paid Apple Developer account | No notarization. First launch is right-click then Open. Distribution follows the LaunchpadX playbook (dmgbuild, tag-triggered release), minus Sparkle |

Deep link for the permission prompt:
`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`

Also note: TCC grants are keyed to the code signature. During development,
re-signing changes identity and silently revokes access — if reads start
failing after a rebuild, re-add the binary in the Privacy pane. Don't spend an
hour debugging SQLite for this.

## Architecture

Swift, AppKit, no external dependencies beyond SQLite (system).
`LSUIElement = true` (menu-bar only, no Dock icon).

```
FSEvents/DispatchSource watch on ~/Library/Messages/
        │  (fires on chat.db, chat.db-wal, chat.db-shm)
        ▼
  debounce ~150ms
        ▼
  MessageStore.fetchNew(sinceRowID:)   ← read-only SQLite
        ▼
  filter: handle.id matches configured sender(s), is_from_me = 0
        ▼
  body = text ?? decode(attributedBody)
        ▼
  normalizeDigits(body)   ← Persian/Arabic-Indic → ASCII
        ▼
  CodeExtractor.match(body)  ← regex, configurable per-sender
        ▼
  Clipboard.set(code)  +  UNUserNotificationCenter  +  60s auto-clear
        ▼
  persist lastSeenROWID
```

Watch the **directory**, not the file — WAL means writes often hit `chat.db-wal`
first and a file-level watch will miss or misfire.

Poll only as a fallback if FSEvents proves flaky (some users report coalescing);
if so, 1s interval, and only while the app is "armed."

## chat.db notes (reverse-engineered; verified on macOS Tahoe 26.x)

Relevant tables: `message`, `handle`, `chat`, `chat_message_join`.

```sql
SELECT m.ROWID, m.text, m.attributedBody, m.date, h.id AS sender
FROM message m
JOIN handle h ON m.handle_id = h.ROWID
WHERE m.ROWID > :lastSeenROWID
  AND m.is_from_me = 0
ORDER BY m.ROWID ASC;
```

Landmines:

1. **`text` is frequently NULL on modern macOS.** Measured on a live database
   (macOS 26.5): 26,411 of 27,915 inbound SMS rows had a NULL `text`. This is
   the normal path, not an edge case. The body lives in `attributedBody`, which
   is a legacy **typedstream** (`NSArchiver`) blob, NOT an `NSKeyedArchiver`
   one: it begins `04 0B "streamtyped"`, and `NSKeyedUnarchiver` returns nil on
   it. `NSUnarchiver` still decodes it correctly on macOS 26.5, but is
   unavailable from Swift, hence the one-function ObjC shim in
   `Sources/OTPTypedStream`. `Sources/OTPMessages/TypedStreamScanner.swift` is
   the pure-Swift fallback for the day Apple removes it. Do not regex the raw
   blob bytes — it "works" until it doesn't.
2. **Dates are Apple epoch in nanoseconds** since 2001-01-01 UTC. Divide by
   1e9, then `Date(timeIntervalSinceReferenceDate:)`. Older rows may be in
   seconds — detect by magnitude if you ever need historical rows.
3. `handle.id` holds shortcodes fine (`20001`, `985000...`, alphanumeric sender
   IDs). This is why we read the DB instead of using iOS Shortcuts, whose
   Sender field only accepts real contacts/phone numbers.
   **iOS message filtering appends `(filtered)` to the handle id**, so one
   sender appears under two ids: a live database had 682 messages under
   `987007100` and another 442 under `987007100(filtered)`. Strip that suffix
   before matching or you silently miss a large share of a sender's messages.
   The same sender also appears in several numeric spellings (`+989999920000`,
   `989999920000`), so numeric matching compares digit tails.
4. `service` column distinguishes `SMS` vs `iMessage`. OTPs are `SMS`.
5. Use `ROWID` as the watermark, not timestamps. Monotonic, cheap, no clock
   issues.

6. **A read-only open of a WAL database can legitimately fail.** SQLite needs a
   readable `-shm` and no pending recovery; otherwise it answers
   `SQLITE_READONLY_RECOVERY` ("attempt to write a readonly database") or
   `SQLITE_BUSY`. The fallback is a private snapshot: copy `chat.db`, `-wal` and
   `-shm` into a 0700 temp directory, read the copy, delete it in a `defer`.
   Implemented and tested (`WALFallbackTests`) against a database whose rows
   exist only in the `-wal`, which is also what proves `immutable=1` would lose
   the newest messages.

Connection string:
`file:/Users/<me>/Library/Messages/chat.db?mode=ro`

## Persian handling (non-negotiable — primary use case is Iranian senders)

Before regex matching, normalize the body:

- Arabic-Indic `٠١٢٣٤٥٦٧٨٩` (U+0660–0669) → ASCII
- Extended Arabic-Indic / Persian `۰۱۲۳۴۵۶۷۸۹` (U+06F0–06F9) → ASCII
- Strip bidi control marks: U+200E, U+200F, U+202A–202E, U+2066–2069
- Strip ZWNJ U+200C (common in Persian text, can sit mid-number in bad senders)
- Fold Arabic letters to their Persian forms: `ي`→`ی` (U+064A→U+06CC),
  `ك`→`ک` (U+0643→U+06A9), `أإآ`→`ا`, `ة`→`ه`. Not cosmetic: Iranian bank
  gateways emit `ريال` and `خريد` with the Arabic letters, so without folding,
  keyword and currency matching misses those senders entirely.

Default extraction regex after normalization: `\b(\d{4,8})\b`, with a per-sender
override in config. Prefer a keyword-anchored match when the sender's format is
known (e.g. `رمز|کد|verification|code` nearby) to avoid grabbing an amount or
account number from the same SMS.

Write unit tests with **real Persian OTP SMS samples** — a fixture file of
anonymized bodies. This is where the bugs will be, not in SQLite.

## Configuration

JSON at `~/Library/Application Support/OTPSnatcher/config.json`:

```json
{
  "senders": [
    { "id": "20001", "pattern": "\\b(\\d{5,6})\\b", "label": "Bank" }
  ],
  "clearClipboardAfterSeconds": 60,
  "notify": true
}
```

Editable from the menu bar. No hardcoded sender IDs in source.

## Security rules

These are requirements, not suggestions. The app holds Full Disk Access; treat
it as such.

- **No network entitlement. No analytics. No crash reporting. Ever.** If a PR
  adds a URLSession call, that PR is wrong. Note that the *entitlement* is not
  the enforcement: entitlements only constrain sandboxed apps and this one
  cannot be sandboxed. `scripts/check-no-network.sh` is the enforcement, and it
  scans both the source and the linked binary in CI.
- **No in-app updater.** Sparkle is a URLSession-based updater running in
  process, which is incompatible with the rule above for an app holding Full
  Disk Access over the whole message history. "Check for Updates" opens the
  releases page in the browser instead.
- The capture notification names the sender, **not the code**. Notification
  Center persists banners, so a code shown there would outlive both the
  concealed pasteboard type and the auto-clear.
- Never log message bodies or extracted codes — not to stdout, not to
  `os_log`, not in debug builds. Log ROWIDs and match/no-match booleans only.
- Mark the pasteboard item `org.nspasteboard.ConcealedType` so clipboard
  managers (Alfred, Raycast, Maccy) don't persist the code to their history.
- Clear the clipboard after the configured TTL, but only if its contents are
  still the code we wrote (compare change count + value; don't stomp on
  something the user copied since).
- Read-only DB access. Never write to `chat.db`.

## Non-goals

- Sending messages. Reading only.
- Full message history browsing / search UI.
- iOS companion app.
- Autofilling the code into fields. macOS Tahoe already autofills OTPs in
  Safari, Chrome and Firefox natively — this tool exists for the cases that
  autofill doesn't cover (terminals, native apps, arbitrary text fields).
- Mac App Store distribution. Not possible; see constraints.

## Build / run

```bash
swift build                        # library + app
swift test                         # must pass offline, no permissions needed
scripts/build-signed-app.sh        # assemble + sign build/OTPSnatcher.app
scripts/check-no-network.sh        # audit: no networking or telemetry code
scripts/make-signing-identity.sh   # one-time: stable self-signed identity
./build/OTPSnatcher.app/Contents/MacOS/OTPSnatcher --check   # headless diagnostic
```

There is no `sign-and-notarize.sh`: notarization needs a paid account. There is
also no `.xcodeproj`. SwiftPM is the single build system, and
`scripts/build-signed-app.sh` assembles and signs the bundle, so `swift test`
stays the fast offline path and there is one source of truth for build settings.

Tests must not require `chat.db` access — use fixture SQLite DBs generated in
`Tests/Fixtures/`. Only integration tests touch the real database, and they skip
gracefully when FDA isn't granted.

## Current status

Phases 1 through 6 of `plan.md` are built, with 78 tests passing offline.

```
Sources/OTPCore        DigitNormalizer, CodeExtractor, SenderMatcher, Config,
                       ClipboardGuard, Log   (pure, fully unit-tested)
Sources/OTPTypedStream ObjC shim for the legacy typedstream decode
Sources/OTPMessages    MessageStore (+ WAL snapshot fallback),
                       AttributedBodyDecoder, TypedStreamScanner,
                       ConfigStore, WatermarkStore, AppSupport
Sources/OTPSnatcher    AppDelegate, MenuBarController, SnatcherEngine,
                       DirectoryWatcher + FallbackPoller, ClipboardSink,
                       Notifier, PermissionGate
```

Measured against a live database on 2026-08-21:

- Body decode: every one of the last 200 rows that carried text decoded.
- Extraction: **156 of 157** messages containing a real OTP cue yielded a code.
  The single holdout is `سرویس رمز یکبار مصرف شما فعال گردید` ("your one-time
  password service is now active"), which matches the cue and contains no digits.
- False positives: **0** on messages that were clearly marketing.
- Strategy split: 41 domain-bound, 109 keyword-anchored, 6 fallback.

Signing verified: rebuilding after a real code change moved the CDHash
(`c5a6458f…` to `815c9340…`) while the designated requirement stayed
byte-identical, which is the property the Full Disk Access grant depends on.

### What is left

1. **Grant Full Disk Access to `build/OTPSnatcher.app`** and confirm reads work
   from the app itself. Everything else has been verified; this step needs a
   human in System Settings. `--check` from a terminal is not proof, because a
   binary launched from a terminal inherits that terminal's permissions.
2. Decide distribution (personal tool, or the two-repo public release flow). The
   release workflow exists but its `RELEASE_REPO` is a guess and is marked as
   such.
3. DMG background art at 1320x896. Packaging falls back to a flat colour until
   it exists.
4. Phase 7 of `plan.md`: the adversarial security read of the whole tree.
