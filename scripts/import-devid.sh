#!/usr/bin/env bash
# Imports the Developer ID Application certificate into the login keychain.
# Usage: scripts/import-devid.sh path/to/developerID_application.cer
# Pairs it with the private key from ~/Workspace/keys/developer-id/devid.key (the one devid.csr was made from).
set -euo pipefail
CER="${1:?usage: import-devid.sh <downloaded .cer>}"
D="$HOME/Workspace/keys/developer-id"
PASS="$(openssl rand -hex 16)"
openssl x509 -inform DER -in "$CER" -out "$D/devid.pem"
openssl pkcs12 -export -legacy -inkey "$D/devid.key" -in "$D/devid.pem" -out "$D/devid.p12" -passout "pass:$PASS" -name "Developer ID Application"
security import "$D/devid.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
rm "$D/devid.p12"
security find-identity -v -p codesigning | grep "Developer ID Application"
