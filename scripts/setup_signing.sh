#!/bin/zsh
# One-time: creates a self-signed "TinyMacro Local Signing" certificate in your login keychain
# so macOS remembers TinyMacro's permissions across rebuilds. Remove it any time in Keychain Access.
set -euo pipefail
NAME="TinyMacro Local Signing"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "Already set up."; exit 0; fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cfg.cnf" 2>/dev/null
LEGACY=""; openssl version | grep -q "^OpenSSL 3" && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout pass:tm
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P tm -T /usr/bin/codesign
echo "Done. Rebuild with ./build.sh, then grant permissions one last time."
