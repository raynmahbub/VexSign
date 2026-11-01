#!/bin/sh
#
# fetch-release-identity.sh — download the published TLS identity for the local
# install server and write it in the layout `deps/` uses (VX-12).
#
# The caller is responsible for verifying the digest afterwards:
#   make deps-release   fetch, verify against Scripts/local-tls/pinned-pack.sha256, install
#   make deps-pin       fetch, print the digest, rewrite the pin file for review
#
# Nothing is ever half-written: the pack goes to a temporary directory first, and
# the caller only copies it into `deps/` once it has been verified. A build must
# never end up with no identity at all — that silently disables HTTPS installs.
#
# Usage: CERT_PACK_URL=<url> Scripts/local-tls/fetch-release-identity.sh <directory>
set -eu

OUT_DIR="${1:?usage: fetch-release-identity.sh <directory>}"
URL="${CERT_PACK_URL:-https://vexsign-install.vexsign.workers.dev/pack.json}"
SCRIPT_DIR="$(dirname "$0")"

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required to fetch the release TLS identity"
command -v jq >/dev/null 2>&1 || fail "jq is required to unpack the release TLS identity"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to compute the identity digest"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vexsign-tls-pack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

curl -fsSL --retry 2 --max-time 60 "$URL" -o "$WORK/pack.json" || fail \
	"could not download $URL (no network, or the endpoint is down).
       Refusing to continue: a build without a TLS identity cannot serve HTTPS installs.
       For an offline development build use 'make deps' (a locally generated identity)."

jq -e '.cert and .ca and .key1 and .key2 and .info.domains.commonName' "$WORK/pack.json" >/dev/null 2>&1 || fail \
	"$URL did not return cert, ca, key1, key2 and info.domains.commonName"

jq -r '.cert, .ca' "$WORK/pack.json" > "$OUT_DIR/server.crt" || fail "could not unpack the certificate chain"
jq -rj '.key1, .key2' "$WORK/pack.json" > "$OUT_DIR/server.pem" || fail "could not unpack the private key"
jq -r '.info.domains.commonName' "$WORK/pack.json" > "$OUT_DIR/commonName.txt" || fail "could not unpack the common name"
chmod 600 "$OUT_DIR/server.pem"

[ -s "$OUT_DIR/server.crt" ] || fail "the certificate chain in the pack is empty"
[ -s "$OUT_DIR/server.pem" ] || fail "the private key in the pack is empty"
grep -q 'BEGIN CERTIFICATE' "$OUT_DIR/server.crt" || fail "the certificate in the pack is not PEM"
grep -q 'PRIVATE KEY' "$OUT_DIR/server.pem" || fail "the private key in the pack is not PEM"

# Structural checks before the digest: a pack can be byte-identical to what was
# pinned and still be unusable if it expired, or if the key is not the leaf's.
if command -v openssl >/dev/null 2>&1; then
	crt_pub="$(openssl x509 -in "$OUT_DIR/server.crt" -noout -pubkey 2>/dev/null || true)"
	key_pub="$(openssl pkey -in "$OUT_DIR/server.pem" -pubout 2>/dev/null || true)"
	[ -n "$crt_pub" ] && [ "$crt_pub" = "$key_pub" ] || fail \
		"the private key in the pack does not match its certificate"
	openssl x509 -in "$OUT_DIR/server.crt" -noout -checkend 0 >/dev/null 2>&1 || fail \
		"the certificate in the pack has already expired"
	openssl x509 -in "$OUT_DIR/server.crt" -noout -checkend 172800 >/dev/null 2>&1 || \
		say "warning: the certificate in the pack expires within two days"
fi

digest="$(python3 "$SCRIPT_DIR/pack_digest.py" "$OUT_DIR")" || fail "could not compute the identity digest"
common_name="$(cat "$OUT_DIR/commonName.txt")"

{
	printf 'mode=release\n'
	printf 'cn=%s\n' "$common_name"
	printf 'digest=sha256:%s\n' "$digest"
} > "$OUT_DIR/tls-identity.txt"

if command -v openssl >/dev/null 2>&1; then
	expires="$(openssl x509 -in "$OUT_DIR/server.crt" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
	[ -n "$expires" ] && say "  leaf expires: $expires"
fi

say "TLS identity: release pack from $URL"
say "  common name : $common_name"
say "  digest      : sha256:$digest"
