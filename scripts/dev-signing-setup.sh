#!/bin/sh
# Create and trust a local self-signed code signing certificate so Debug
# builds carry a STABLE code identity across rebuilds.
#
# Why: ad-hoc signatures (CODE_SIGN_IDENTITY "-") have no identity — every
# rebuild looks like a brand-new app to the Keychain ACL system, so each
# build re-prompts for the login keychain password when it reads the
# stored API keys. Signing with one persistent certificate means a single
# "Always Allow" sticks forever.
#
# Run once per machine (idempotent; safe to re-run):
#   scripts/dev-signing-setup.sh
# The final trust step calls sudo — you'll be asked for your password.
set -eu

CERT_NAME="Pigeon Dev"

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "certificate '$CERT_NAME' already in keychain — nothing to do"
    exit 0
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Explicit config instead of -addext: works on both LibreSSL (system
# /usr/bin/openssl) and OpenSSL.
cat > "$WORK_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = codesign_ext
prompt = no

[dn]
CN = $CERT_NAME

[codesign_ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
    -config "$WORK_DIR/openssl.cnf"

# Bundle and import into the login keychain. -T lets codesign use the
# private key without a per-build prompt.
openssl pkcs12 -export -legacy \
    -out "$WORK_DIR/identity.p12" \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -passout pass:pigeon-dev 2>/dev/null \
|| openssl pkcs12 -export \
    -out "$WORK_DIR/identity.p12" \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -passout pass:pigeon-dev

security import "$WORK_DIR/identity.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P pigeon-dev \
    -T /usr/bin/codesign

# Trust the cert for code signing (admin trust domain — needs sudo).
echo "==> trusting '$CERT_NAME' for code signing (sudo will ask for your password)"
sudo security add-trusted-cert -d -r trustRoot -p codeSign "$WORK_DIR/cert.pem"

# Let Apple's tools (codesign runs with partition ID apple-tool:) use the
# private key without a per-build SecurityAgent dialog. Asks for the login
# keychain password once.
echo "==> authorizing codesign to use the key (enter your login password)"
security set-key-partition-list -S "apple-tool:,apple:" -s -l "$CERT_NAME" \
    "$HOME/Library/Keychains/login.keychain-db"

echo "==> done. verify with: security find-identity -v -p codesigning"
