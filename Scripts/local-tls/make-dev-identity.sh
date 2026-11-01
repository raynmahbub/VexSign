#!/bin/sh
#
# make-dev-identity.sh — build the local install server a TLS identity, offline.
#
# `make deps` used to curl a mutable endpoint for the private key that ends
# up in every build. That is gone. The default build now mints its own identity
# here, with openssl and no network: a development Root CA plus a leaf, in the
# shape the app expects (leaf first, CA last in server.crt; key in server.pem;
# the host the local server binds to in commonName.txt).
#
# This is a *development* identity. The device has to trust the CA it exports
# (Settings → Installation → Server & SSL → Export Root CA Profile) before
# itms-services will accept an HTTPS manifest from it. A release build uses
# `make deps-release` instead, which fetches the project's published identity and
# refuses it unless it matches the pinned digest (see docs/RELEASING.md).
#
# Written against the openssl that macOS actually ships (LibreSSL), so it uses a
# config file rather than `-addext`, which LibreSSL does not have everywhere.
#
# Usage:  Scripts/local-tls/make-dev-identity.sh [output-directory]
#         DEV_CN=<host> Scripts/local-tls/make-dev-identity.sh
#
# Exit status is non-zero if anything fails: a build must not continue without an
# identity and quietly ship an installer that cannot serve HTTPS.
set -eu

OUT_DIR="${1:-deps}"
DEV_CN="${DEV_CN:-127.0.0.1}"

CRT="$OUT_DIR/server.crt"
PEM="$OUT_DIR/server.pem"
CN_FILE="$OUT_DIR/commonName.txt"
MARKER="$OUT_DIR/tls-identity.txt"

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || fail "openssl is required to generate the development TLS identity"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to compute the identity digest"

mkdir -p "$OUT_DIR"

# Reuse an identity that is still good. Rotating it every build would silently
# invalidate the CA profile a tester already trusted on their device.
if [ -f "$CRT" ] && [ -f "$PEM" ] && [ -f "$CN_FILE" ] && [ -f "$MARKER" ]; then
	if openssl x509 -in "$CRT" -noout -checkend 604800 >/dev/null 2>&1; then
		crt_pub="$(openssl x509 -in "$CRT" -noout -pubkey 2>/dev/null || true)"
		key_pub="$(openssl pkey -in "$PEM" -pubout 2>/dev/null || true)"
		if [ -n "$crt_pub" ] && [ "$crt_pub" = "$key_pub" ]; then
			say "TLS identity: reusing development identity in $OUT_DIR (leaf valid for more than 7 days)"
			exit 0
		fi
	fi
	say "TLS identity: existing files in $OUT_DIR are expired or do not match the key; regenerating"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vexsign-dev-tls.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

CA_CONF="$WORK/ca.cnf"
LEAF_CONF="$WORK/leaf.cnf"
LEAF_EXT="$WORK/leaf.ext"

if printf '%s' "$DEV_CN" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
	# Loopback-only: the device fetches its own manifest, so nothing has to resolve.
	SAN="IP:$DEV_CN,DNS:localhost"
	[ "$DEV_CN" = "127.0.0.1" ] || SAN="$SAN,IP:127.0.0.1"
else
	SAN="DNS:$DEV_CN,DNS:localhost,DNS:*.local,IP:127.0.0.1"
fi

cat > "$CA_CONF" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca

[dn]
O = VexSign Development
OU = Local Install Server
CN = VexSign Development Root CA

[v3_ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

cat > "$LEAF_CONF" <<EOF
[req]
distinguished_name = dn
prompt = no

[dn]
O = VexSign Development
OU = Local Install Server
CN = $DEV_CN
EOF

cat > "$LEAF_EXT" <<EOF
[v3_leaf]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = $SAN
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid, issuer
EOF

openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
	-keyout "$WORK/ca.key" -out "$WORK/ca.crt" -days 3650 \
	-config "$CA_CONF" >/dev/null 2>&1 \
	|| fail "could not generate the development Root CA"

openssl req -newkey rsa:2048 -nodes -sha256 \
	-keyout "$WORK/leaf.key" -out "$WORK/leaf.csr" \
	-config "$LEAF_CONF" >/dev/null 2>&1 \
	|| fail "could not generate the leaf key"

openssl x509 -req -in "$WORK/leaf.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
	-CAcreateserial -days 825 -sha256 \
	-extfile "$LEAF_EXT" -extensions v3_leaf -out "$WORK/leaf.crt" >/dev/null 2>&1 \
	|| fail "could not sign the leaf certificate"

# Leaf first, CA last: LocalCAProfile.exportProfile() treats the last certificate
# in server.crt as the root the user installs.
cat "$WORK/leaf.crt" "$WORK/ca.crt" > "$CRT.tmp" || fail "could not write $CRT"
cp "$WORK/leaf.key" "$PEM.tmp" || fail "could not write $PEM"
mv "$CRT.tmp" "$CRT"
mv "$PEM.tmp" "$PEM"
printf '%s\n' "$DEV_CN" > "$CN_FILE"
chmod 600 "$PEM"

openssl verify -CAfile "$WORK/ca.crt" "$WORK/leaf.crt" >/dev/null 2>&1 \
	|| fail "the generated leaf does not verify against its own CA"

digest="$(python3 "$(dirname "$0")/pack_digest.py" "$OUT_DIR")" \
	|| fail "could not compute the identity digest"

{
	printf 'mode=development\n'
	printf 'cn=%s\n' "$DEV_CN"
	printf 'digest=sha256:%s\n' "$digest"
} > "$MARKER"

expires="$(openssl x509 -in "$WORK/leaf.crt" -noout -enddate | sed 's/^notAfter=//')"

say ""
say "TLS identity: development (self-signed, generated locally — not the release identity)"
say "  common name : $DEV_CN  (SAN: $SAN)"
say "  leaf expires: $expires"
say "  digest      : sha256:$digest"
say "  files       : $OUT_DIR/server.crt, $OUT_DIR/server.pem, $OUT_DIR/commonName.txt, $OUT_DIR/tls-identity.txt"
say "  trust       : Settings → Installation → Server & SSL → Export Root CA Profile, then enable full trust"
say "  release     : use 'make deps-release' with a pinned digest instead (docs/RELEASING.md)"
say ""
