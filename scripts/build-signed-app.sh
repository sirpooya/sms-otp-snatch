#!/bin/bash
#
# Builds OTPSnatcher.app and signs it with a STABLE code-signing identity.
#
# Why the identity matters more here than in a normal app: TCC keys the Full
# Disk Access grant to the code signature. An ad-hoc or unsigned binary has no
# certificate to pin to, so TCC falls back to the cdhash, which changes on every
# build. The grant would then die on every rebuild during development and on
# every update for users, and this app does nothing at all without it.
#
# Any real certificate fixes that, including a self-signed one. A paid Apple
# Developer account is NOT required. See docs/signing-and-tcc.md.
#
# Usage:
#   scripts/build-signed-app.sh                 # auto-detect an identity
#   OTP_SIGN_IDENTITY="Some Identity" ...       # force one
#   OTP_ALLOW_ADHOC=1 ...                       # explicitly accept the bad case

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="OTPSnatcher"
CONFIGURATION="${OTP_CONFIGURATION:-release}"
OUT_DIR="build"
APP="${OUT_DIR}/${APP_NAME}.app"

# ---------------------------------------------------------------- identity

pick_identity() {
	if [[ -n "${OTP_SIGN_IDENTITY:-}" ]]; then
		printf '%s' "$OTP_SIGN_IDENTITY"
		return
	fi
	local identities
	identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

	# Preference order: Developer ID (if one ever exists), then a self-signed
	# code-signing identity, then the free Apple Development cert.
	for pattern in "Developer ID Application" "Self-Signed Code Signing" "Apple Development"; do
		local match
		match="$(printf '%s\n' "$identities" | grep -o "\"${pattern}[^\"]*\"" | head -1 | tr -d '"')"
		if [[ -n "$match" ]]; then
			printf '%s' "$match"
			return
		fi
	done
	printf ''
}

IDENTITY="$(pick_identity)"

if [[ -z "$IDENTITY" ]]; then
	if [[ "${OTP_ALLOW_ADHOC:-0}" != "1" ]]; then
		cat >&2 <<'MSG'
error: no code-signing identity found.

This app cannot be usefully ad-hoc signed: TCC would revoke Full Disk Access on
every rebuild, so the app would stop reading messages after each build.

Create a self-signed code-signing certificate once (no Apple account needed):
    scripts/make-signing-identity.sh
then re-run this script. See docs/signing-and-tcc.md for the reasoning.

To build anyway, knowing the grant will not persist:
    OTP_ALLOW_ADHOC=1 scripts/build-signed-app.sh
MSG
		exit 1
	fi
	IDENTITY="-"
	echo "warning: ad-hoc signing. Full Disk Access will NOT survive a rebuild." >&2
fi

echo "==> Identity: ${IDENTITY}"

# ---------------------------------------------------------------- build

echo "==> swift build -c ${CONFIGURATION}"
swift build -c "$CONFIGURATION" --product "$APP_NAME"
BINARY="$(swift build -c "$CONFIGURATION" --product "$APP_NAME" --show-bin-path)/${APP_NAME}"
[[ -x "$BINARY" ]] || { echo "error: built binary not found at ${BINARY}" >&2; exit 1; }

# ---------------------------------------------------------------- assemble

echo "==> Assembling ${APP}"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BINARY" "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# ---------------------------------------------------------------- sign

echo "==> Signing"
# Hardened runtime, timestamped, no entitlements file: this app is deliberately
# not sandboxed (it could not read chat.db if it were) and asks for nothing.
codesign --force --deep \
	--options runtime \
	--timestamp \
	--sign "$IDENTITY" \
	"$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

echo
echo "==> Signature"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|CDHash)' || true

echo
echo "Built ${APP}"
echo "Full Disk Access must be granted to this bundle, not to the raw binary in .build."
