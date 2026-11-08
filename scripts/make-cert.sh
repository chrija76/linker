#!/bin/zsh
# One-time: creates the "Linker Self-Signed" code-signing identity in the login keychain.
set -euo pipefail
if security find-identity -p codesigning | grep -q "Linker Self-Signed"; then echo "Already exists"; exit 0; fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/ext.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Linker Self-Signed
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -config "$D/ext.cnf" 2>/dev/null
P=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey "$D/key.pem" -in "$D/cert.pem" -name "Linker Self-Signed" -out "$D/id.p12" -passout "pass:$P" 2>/dev/null
security import "$D/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$P" -T /usr/bin/codesign
