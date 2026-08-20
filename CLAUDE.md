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
| DB is WAL | Open read-only, but **not** `immutable=1` (would miss `-wal` contents) |

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
  Clipboard.set(code)  +  NSUserNotification  +  60s auto-clear
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

1. **`text` is frequently NULL on modern macOS.** The body lives in
   `attributedBody`, an `NSKeyedArchiver` blob. Decode with
   `NSAttributedString` / `NSUnarchiver` and take `.string`. Do not regex the
   raw blob bytes — it "works" until it doesn't.
2. **Dates are Apple epoch in nanoseconds** since 2001-01-01 UTC. Divide by
   1e9, then `Date(timeIntervalSinceReferenceDate:)`. Older rows may be in
   seconds — detect by magnitude if you ever need historical rows.
3. `handle.id` holds shortcodes fine (`20001`, `985000...`, alphanumeric sender
   IDs). This is why we read the DB instead of using iOS Shortcuts, whose
   Sender field only accepts real contacts/phone numbers.
4. `service` column distinguishes `SMS` vs `iMessage`. OTPs are `SMS`.
5. Use `ROWID` as the watermark, not timestamps. Monotonic, cheap, no clock
   issues.

Connection string:
`file:/Users/<me>/Library/Messages/chat.db?mode=ro`

## Persian handling (non-negotiable — primary use case is Iranian senders)

Before regex matching, normalize the body:

- Arabic-Indic `٠١٢٣٤٥٦٧٨٩` (U+0660–0669) → ASCII
- Extended Arabic-Indic / Persian `۰۱۲۳۴۵۶۷۸۹` (U+06F0–06F9) → ASCII
- Strip bidi control marks: U+200E, U+200F, U+202A–202E, U+2066–2069
- Strip ZWNJ U+200C (common in Persian text, can sit mid-number in bad senders)

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
  adds a URLSession call, that PR is wrong.
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
swift build                 # or xcodebuild -scheme OTPSnatcher
swift test                  # extractor + normalizer tests must pass offline
scripts/sign-and-notarize.sh   # Developer ID, then staple
```

Tests must not require `chat.db` access — use fixture SQLite DBs generated in
`Tests/Fixtures/`. Only integration tests touch the real database, and they skip
gracefully when FDA isn't granted.

## Current status

Nothing built yet. Suggested order:

1. `DigitNormalizer` + `CodeExtractor` + tests (pure, no permissions needed)
2. `MessageStore` against a fixture DB, including `attributedBody` decoding
3. FSEvents watcher + watermark persistence
4. Menu bar UI, config, FDA onboarding flow
5. Clipboard handling + auto-clear
6. Signing/notarization script
