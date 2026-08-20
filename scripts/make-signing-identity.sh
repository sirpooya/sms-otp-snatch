#!/bin/bash
#
# Creates a long-lived self-signed code-signing identity in the login keychain.
#
# Read docs/signing-and-tcc.md first. The short version: TCC pins the Full Disk
# Access grant to the code signature, so this app needs a *stable* signing
# identity or the grant dies on every build. Any real certificate does the job;
# a paid Apple Developer account is not required.
#
# This script is idempotent: if the identity already exists it does nothing.
#
# It does NOT run automatically as part of the build, because it writes to your
# keychain and macOS will prompt for permission.

set -euo pipefail

CN="${OTP_IDENTITY_CN:-Pooya Self-Signed Code Signing}"
DAYS="${OTP_IDENTITY_DAYS:-3650}"
KEYCHAIN="${OTP_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
	echo "Identity already present: $CN"
	exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a $DAYS-day self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
	-keyout "$WORK/key.pem" \
	-out "$WORK/cert.pem" \
	-days "$DAYS" \
	-subj "/CN=$CN" \
	-addext "basicConstraints=critical,CA:FALSE" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=critical,codeSigning" \
	2>/dev/null

echo "==> Packaging as PKCS#12"
openssl pkcs12 -export \
	-inkey "$WORK/key.pem" \
	-in "$WORK/cert.pem" \
	-out "$WORK/identity.p12" \
	-name "$CN" \
	-passout pass: \
	2>/dev/null

echo "==> Importing into $KEYCHAIN (macOS may ask for permission)"
security import "$WORK/identity.p12" \
	-k "$KEYCHAIN" \
	-P "" \
	-T /usr/bin/codesign

cat <<MSG

Done. Identity: $CN

Two things to do now, both important:

1. BACK UP the identity. Export it from Keychain Access as a .p12 and store it
   in the Apple Passwords app, next to the Sparkle key. If this certificate is
   ever lost, every install of the app (including yours) must re-grant Full
   Disk Access, because the designated requirement changes.

2. Do NOT commit the .p12. .gitignore already excludes *.p12, and for CI it
   belongs in a repository secret, not in the tree.

Then build with:
    scripts/build-signed-app.sh

Note on Gatekeeper: a self-signed app is not notarized, so first launch still
needs right-click then Open. That is the same posture as LaunchpadX and is
unrelated to the Full Disk Access question this identity solves.
MSG
