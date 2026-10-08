#!/usr/bin/env bash
# Import a Developer ID Application identity for signing, when one is provided.
#
# Environment (all optional; GitHub secrets of the same names):
#   MACOS_CERTIFICATE_P12_BASE64  the identity (certificate + key) as a base64 .p12
#   MACOS_CERTIFICATE_PASSWORD    the .p12's password
#   MACOS_SIGNING_IDENTITY        the identity's name, "Developer ID Application: <Name> (<TEAM>)"
#
# With all three present the identity goes into a temporary keychain that is
# added to the search list, and `identity=<name>` is written to GITHUB_OUTPUT
# for macos-dmg.sh. With any missing, nothing is imported, `identity=` is
# empty, and the dmg is signed ad hoc. Never prints the certificate, the key or
# the password.
#
# This path has not run: the project has no Apple credentials yet (TASK-69).
set -euo pipefail

out="${GITHUB_OUTPUT:-/dev/null}"
if [ -z "${MACOS_CERTIFICATE_P12_BASE64:-}" ] || [ -z "${MACOS_CERTIFICATE_PASSWORD:-}" ] || [ -z "${MACOS_SIGNING_IDENTITY:-}" ]; then
  echo "INFO: no Developer ID secrets; the app will be signed ad hoc (not trusted by Gatekeeper)"
  echo "identity=" >> "$out"
  exit 0
fi

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cid.XXXXXX")"
keychain="$work/signing.keychain-db"
keychain_password="$(uuidgen)"
printf '%s' "$MACOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$work/identity.p12"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$work/identity.p12" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign > /dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" > /dev/null
# Keep the login keychain searchable, and put the signing one first.
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
rm -f "$work/identity.p12"
security find-identity -v -p codesigning "$keychain" | grep -F "$MACOS_SIGNING_IDENTITY" > /dev/null || {
  echo "FAIL: the imported keychain has no identity named by MACOS_SIGNING_IDENTITY" >&2
  exit 1
}
echo "identity=$MACOS_SIGNING_IDENTITY" >> "$out"
echo "PASS: imported the Developer ID identity into a temporary keychain"
