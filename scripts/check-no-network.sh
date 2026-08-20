#!/bin/bash
#
# Enforces the hard security rule from CLAUDE.md: this app has no network code.
#
# Entitlements cannot enforce it. Entitlements only constrain sandboxed apps, and
# this one cannot be sandboxed (a sandboxed app cannot read chat.db), so
# "no network entitlement" is documentation, not a mechanism. This script is the
# mechanism.
#
# Two checks:
#   1. Source: no networking API is referenced anywhere.
#   2. Binary: the linked product imports no networking symbol.
#
# Plain URL *values* are allowed. Handing a URL to NSWorkspace so the browser
# opens it is not a network request by this process, and that is how
# "Check for Updates" works.

set -uo pipefail
cd "$(dirname "$0")/.."

STATUS=0

FORBIDDEN='URLSession|NSURLConnection|URLRequest|dataTask|downloadTask|uploadTask|import Network|import CFNetwork|CFSocket|NWConnection|NWListener|getaddrinfo|socket\(|connect\(|SCNetwork'

echo "==> Source scan"
if MATCHES="$(grep -rnE "$FORBIDDEN" Sources/ 2>/dev/null)"; then
	echo "FAIL: networking API referenced in Sources/" >&2
	echo "$MATCHES" >&2
	STATUS=1
else
	echo "ok: no networking API in Sources/"
fi

# Analytics and crash reporting are banned by the same rule.
echo "==> Telemetry scan"
if MATCHES="$(grep -rniE 'analytics|crashlytics|sentry|telemetry|mixpanel|amplitude|posthog' Sources/ 2>/dev/null)"; then
	echo "FAIL: telemetry reference in Sources/" >&2
	echo "$MATCHES" >&2
	STATUS=1
else
	echo "ok: no telemetry references"
fi

BINARY="build/OTPSnatcher.app/Contents/MacOS/OTPSnatcher"
if [[ -x "$BINARY" ]]; then
	echo "==> Binary symbol scan"
	if SYMS="$(nm -u "$BINARY" 2>/dev/null | grep -iE 'URLSession|NSURLConnection|NWConnection|CFSocket')"; then
		echo "FAIL: networking symbols linked into the product" >&2
		echo "$SYMS" >&2
		STATUS=1
	else
		echo "ok: no networking symbols in $BINARY"
	fi
else
	echo "note: $BINARY not built, skipping the binary scan"
fi

exit $STATUS
