#!/bin/bash
# Creates a self-signed code signing certificate for local builds of this fork, so that the app's
# identity is stable between rebuilds.
#
# Why this matters. An ad-hoc signature (`codesign -s -`) carries no identity: its designated
# requirement is the hash of the binary itself —
#
#     designated => cdhash H"b74ae3bd157cde91a0f86e15e57521a740fcf663"
#
# — so every rebuild looks like a *different* app to macOS. Permissions that macOS stores as a
# requirement and re-evaluates against the app (TCC: Accessibility, Input Monitoring, Apple Events;
# also keychain access control lists) stop matching, and the app is asked again — or silently
# denied. With a certificate the requirement instead names the certificate:
#
#     designated => identifier "org.p0deje.Maccy" and certificate root = H"5ae9dfa7…"
#
# which is the same for every build signed with that certificate. Nothing here is signed for
# distribution: the certificate is self-signed, unknown to anyone else, and only this machine trusts
# it (and only in the user trust domain, if you ask for --trust). See docs/installing.md.
#
# Usage: scripts/create-signing-identity.sh [--name "Maccy Local Signing"] [--trust]
#
#   --trust   also mark the certificate trusted for code signing *for this user*, which makes
#             `security find-identity -v` list it. Signing and verification work without it, so it
#             is off by default; it may ask for your password, and it is a trust setting you would
#             want to remove if you ever delete the certificate.
set -euo pipefail

NAME="Maccy Local Signing"
TRUST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="${2:?--name needs a value}"; shift 2 ;;
    --trust) TRUST=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

step() { echo; echo "=== $*"; }

# The identity hash in `find-identity` output *is* the certificate's SHA-1, which is also what the
# designated requirement names (`certificate root = H"…"`). Note -p without -v: an untrusted
# certificate is exactly what this script creates, and it still signs.
identity_hash() {
  security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | awk -v n="$NAME" '$0 ~ "\"" n "\"" { print tolower($2); exit }'
}

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  step "Certificate already exists"
  echo "  \"$NAME\" is already in $KEYCHAIN — nothing to create."
  echo "  The signing requirement it produces:"
  echo "    identifier \"org.p0deje.Maccy\" and certificate root = H\"$(identity_hash)\""
  exit 0
fi

step "Creating a self-signed code signing certificate"
# LibreSSL (the openssl macOS ships) has no `-addext` on `req`, so the extensions go in a config.
WORK=$(mktemp -d -t maccy-identity)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[ dn ]
CN = $NAME
O = Maccy fork local build
C = US
[ codesign ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$WORK/openssl.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
echo "  certificate: $(openssl x509 -in "$WORK/cert.pem" -noout -subject -enddate | tr '\n' ' ')"

# The private key never leaves the keychain afterwards: the p12 and the PEM files live in a
# temporary directory that is removed on exit.
PASSPHRASE=$(openssl rand -hex 16)
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" \
  -name "$NAME" -passout "pass:$PASSPHRASE" 2>/dev/null

step "Importing it into your login keychain"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSPHRASE" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# -T is what keeps codesign from prompting for keychain access on every build.

if [ "$TRUST" = 1 ]; then
  step "Marking it trusted for code signing (user trust settings)"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" || true
fi

HASH=$(identity_hash)

step "Done"
echo "  identity:      $NAME"
echo "  keychain:      $KEYCHAIN"
echo "  fingerprint:   $HASH"
if [ "$TRUST" = 1 ]; then
  echo "  find-identity: $(security find-identity -v -p codesigning | sed -n 's/.*\"'"$NAME"'\".*/listed as valid/p' | head -1)"
else
  echo "  find-identity: not trusted for code signing — signing works anyway, this is cosmetic"
fi
echo
echo "  scripts/install.sh will now sign with it automatically:"
echo "    designated => identifier \"org.p0deje.Maccy\" and certificate root = H\"$HASH\""
echo
echo "  Keep this certificate. Deleting it (or recreating it under a new name) changes the app's"
echo "  identity again and resets the permissions macOS has granted to Maccy."
