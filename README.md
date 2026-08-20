# OTP Snatcher

A macOS menu-bar utility that watches SMS messages forwarded from your iPhone,
pulls out the one-time code, and puts it on the clipboard. Phone buzzes, the code
is already in `⌘V`.

Built for Iranian senders first: Persian and Arabic-Indic digits, bidi marks and
ZWNJ are normalized before matching, and the extractor knows the difference
between a bank OTP and the transaction amount printed two lines above it.

## What it needs

1. **Text Message Forwarding.** On the iPhone: Settings, Apps, Messages, Text
   Message Forwarding, enable this Mac, enter the code shown.
2. **Full Disk Access** for the app. Forwarded SMS land in the Messages database,
   which macOS protects. There is no supported alternative and no way to request
   the permission programmatically, so the app detects the failure and links you
   to the right settings pane.

## Install

Not notarized, because there is no paid Apple Developer account behind it. First
launch needs **right-click, then Open**. It is signed with a stable identity,
which is what lets the Full Disk Access grant survive updates.

## Configure

`~/Library/Application Support/OTPSnatcher/config.json`:

```json
{
  "senders": [
    { "id": "20001", "pattern": "\\b(\\d{5,6})\\b", "label": "Bank" }
  ],
  "clearClipboardAfterSeconds": 60,
  "notify": true
}
```

- `id` is the sender as Messages stores it: a shortcode (`20001`), a long number
  (`+989999920000`), or an alphanumeric sender id (`DIGIKALA`). Matching is
  case-insensitive, tolerates the `(filtered)` marker iOS adds to junk-filtered
  senders, and matches numeric senders across country-code spellings.
- `pattern` is optional and **authoritative**: if you set one and it does not
  match, nothing is copied. That is the point of writing one.
- Edits take effect without a relaunch.

Nothing is hardcoded: with no senders configured the app matches nothing.

## Build

```bash
swift build                        # library and app
swift test                         # 78 tests, offline, no permissions needed
scripts/build-signed-app.sh        # assemble and sign build/OTPSnatcher.app
scripts/check-no-network.sh        # audit: no networking or telemetry code
scripts/make-signing-identity.sh   # one-time, creates a stable signing identity
```

`OTPSnatcher --check` prints a headless report of permission, decode and config
state. Use it before debugging anything else.

To read the app's own log, note that `log` is a **zsh builtin**, so the absolute
path is required or the command silently does nothing:

```bash
/usr/bin/log show --last 5m --predicate 'subsystem == "com.pooya.otpsnatcher"' --style compact
```

The log carries row ids, counts and event names only, never message content.

Full Disk Access attaches to the **bundle**, not to `.build/release/OTPSnatcher`.
Testing DB access by running the raw binary tells you nothing useful, because a
binary launched from a terminal inherits the terminal's permissions.

## Privacy

- **No network code at all.** Not an entitlement claim: entitlements only
  constrain sandboxed apps, and this app cannot be sandboxed. It is enforced by
  `scripts/check-no-network.sh`, which scans the source and the linked binary and
  runs in CI. "Check for Updates" opens a browser rather than fetching anything.
- No analytics, no crash reporting.
- Message bodies and extracted codes are never logged, in any build. The logging
  API physically cannot accept free-form text: only row ids, counts and enum
  names.
- The clipboard entry is marked `org.nspasteboard.ConcealedType`, so Alfred,
  Raycast and Maccy skip it instead of storing your OTP in their history.
- The auto-clear only fires if the clipboard still holds exactly what was
  written, so it never overwrites something you copied since.
- The notification says which sender the code came from, deliberately not the
  code, because Notification Center would keep it long after the clipboard was
  wiped.
- Read-only database access. Nothing is ever written to `chat.db`.

## Documentation

- `CLAUDE.md`: the spec, plus reverse-engineered notes on the message database.
- `plan.md`: build order and the reasoning behind each decision.
- `docs/signing-and-tcc.md`: why signing matters here, and the symptom guide for
  when reads suddenly stop working.
