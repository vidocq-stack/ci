#!/usr/bin/env bash
# Builds a trust store that refuses the compromised eMudhra intermediate CA certificates,
# for Maven, without touching the JDK.
#
# On 2026-10-20 Mozilla disclosed that the private keys of eight eMudhra intermediate CAs
# can be recovered from their certificates (https://emudhra.we-have-a-problem.com/), so
# anyone can mint a certificate for any host name (Vidocq/vidocq#292). Their 16
# certificates chain to three roots only: emSign Root TLS CA - G3, emSign ECC Root CA - G3
# (which cross-signs the former) and Sectigo's AAA Certificate Services. The JDK ships its
# own trust store and checks no revocation, so it keeps accepting them until the vendors
# ship a fix.
#
# The script copies the JDK's cacerts and deletes those three roots from the copy, matched
# by SHA-256 fingerprint whatever their alias. Point Maven at the copy with
#   MAVEN_OPTS="-Djavax.net.ssl.trustStore=<copy> -Djavax.net.ssl.trustStorePassword=changeit"
# Legitimate sites keep validating: Sectigo's current chains end at the USERTrust roots,
# which stay, and Java anchors a cross-signed root on its trusted self-signed twin.
#
# The JDK itself must stay untouched. A JDK without jmods (Temurin 24 and later) links
# images from its own files, and jlink refuses to run once one of them has changed
# (JEP 493): an earlier version of this script edited lib/security/blocked.certs and broke
# every jlink build. If it finds the copy that version kept (blocked.certs.orig), it puts
# the original file back.
#
# Usage: block-emudhra-intermediates.sh <java-home> <output-trust-store>
# Delete this script once Temurin ships a JDK that refuses these certificates.
set -euo pipefail

JH="$1"
OUT="$2"

# SHA-256 of the three roots the compromised certificates chain to (roots.json on the
# incident page): emSign ECC Root CA - G3, emSign Root TLS CA - G3, AAA Certificate Services.
# One line: BSD awk (macOS) refuses a newline inside a -v value.
ROOTS="86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B 7DD78D5F4F13459A83DFF9ABBBA62EDBAF6F2D102BF257FD712F4D9F2746ED8D D7A7A0FB5D7E2731D771E9484EBCDEF71D5F0C3E0A2948782BC83EE0EA699EF4"

blocked="$JH/lib/security/blocked.certs"
if [ -f "$blocked.orig" ]; then
    mv -f "$blocked.orig" "$blocked"
    echo "Restored the JDK's original lib/security/blocked.certs, edited by an earlier version of this script"
fi

src="$JH/lib/security/cacerts"
[ -f "$src" ] || src="$JH/jre/lib/security/cacerts"   # JDK 8 layout
keytool="$JH/bin/keytool"
cp "$src" "$OUT"
chmod 644 "$OUT"

# Verbose listing of the copy, in English whatever the machine's locale so that the labels
# below match. Fails when keytool fails or lists nothing: an empty listing must never pass
# for "no compromised root left".
listing() {
    local out
    out=$("$keytool" -J-Duser.language=en -J-Duser.country=US -list -v -keystore "$OUT" -storepass changeit)
    if ! grep -q '^Alias name: ' <<< "$out"; then
        echo "error: keytool listed no certificate in $OUT" >&2
        return 1
    fi
    printf '%s\n' "$out"
}

aliases=$(listing | awk -v want="$ROOTS" '
    /^Alias name: / { alias = substr($0, 13) }
    /^[[:space:]]*SHA256: / { fp = $2; gsub(":", "", fp); if (index(want, fp) > 0) print alias }')

removed=0
while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    "$keytool" -J-Duser.language=en -delete -alias "$alias" -keystore "$OUT" -storepass changeit
    echo "Removed root '$alias' from the Maven trust store"
    removed=$((removed + 1))
done <<< "$aliases"

# Independent check: no fingerprint of the three roots may remain anywhere in the listing.
# The listing is taken first, so that a keytool failure stops the script here.
final=$(listing)
left=$(printf '%s\n' "$final" | tr -d ':' | grep -c -E "${ROOTS// /|}" || true)
if [ "$left" -ne 0 ]; then
    echo "error: $left compromised eMudhra root(s) still in $OUT" >&2
    exit 1
fi
echo "Maven trust store $OUT: $removed root(s) removed, none of the three roots left"
