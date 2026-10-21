#!/usr/bin/env bash
# Blocks the 16 compromised eMudhra intermediate CA certificates in one or more JDKs.
#
# On 2026-10-20 Mozilla disclosed that the private keys of eight eMudhra intermediate CAs
# can be recovered from their certificates (https://emudhra.we-have-a-problem.com/), so
# anyone can mint a certificate for any host name. Each key has two certificates: one
# issued by an eMudhra root, one cross-signed by Sectigo "AAA Certificate Services". The
# JDK ships its own trust store and checks no revocation by default, so it keeps
# accepting them until the vendors ship a fix (Vidocq/vidocq#292).
#
# The fix: add their SHA-256 fingerprints to lib/security/blocked.certs. The JDK checks
# that list on every certificate path it validates, TLS included, whatever the roots in
# cacerts. Delete this script once Temurin ships a JDK that blocks them.
#
# Usage: block-emudhra-intermediates.sh [JAVA_HOME ...]
#   Without arguments: every JDK under ~/.sdkman/candidates/java (maintainer machines).
# Idempotent; keeps the original list as blocked.certs.orig next to it. JDK 8 is skipped:
# its list is jre/lib/security/blacklisted.certs.
set -euo pipefail

# SHA-256 of the 16 certificates listed in impacted-intermediates.json on the incident
# page, recomputed from the published PEM files.
FINGERPRINTS="
42C4ACCD12C4F59597925E1A08A7A90102608543809308D50EC427E118BA1493
45A883F349AEDFD5F3A649B5498FFB121712BA8B448F3F2A91DBC5A766FCDDBE
98B896625C0C230ADEEC3EB2CF6AAD5001ECF9156A68644E82374CE5833BC25B
5F1DED4DD590AF74631290CF073B122A2AAC6A1FA479778A0BD43579BD832699
E7568FE6E12331F4FD7DE61DA4C7559D0F8EB192A218D4741A3BA75184333838
579480AEA166290BD3C643589E795FC0D0E54E86505D180F1DFF99EFD3199512
0164D7CEAE5BB909C272AF151FF44B1177AE9B47D9424B94F1D9558C30934D19
62B7F9868263F72F6911FC78CEAF72C1979158B7368BF648683BB2AA39B02E72
CB6E15165AC802E9B3F993F16C25D41F4E81C21EBDE71AE1B012AC00BF9C7C3F
7485B51C0ED192878FA1D2F948FB529AE1842CC5086C4B67F7BE5B2039DE9489
432EC25F0D28DE9006D97BF752F17BBB2CD41F669933FCB072D9A1148D0261F3
FD9D5C2DBBD4995AB69B8D50C439D9527B00529199C2FD01B2174EB58F07021F
9E39DE2881273ACC225A149C72BA3E0F51424963669AB633EE1DC7DF5DB067B4
A496E23AC0CAB8155FC9B117B97EAE368EFCBB9041AEC8804D5A308D2D01C2D8
4B2460A466F95FD40113BCDCCA2CEB29B3B093921DE45474DA7DF48874C630B1
84112972B8E59D14560AE7E7119654474AAD119990CF3722BFC1E3B91615E1FD
"

warn() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning::$*"
    else
        echo "warning: $*" >&2
    fi
}

homes=("$@")
if [ "${#homes[@]}" -eq 0 ]; then
    for d in "$HOME"/.sdkman/candidates/java/*; do
        [ -L "$d" ] && continue   # skip the "current" symlink
        [ -d "$d" ] && homes+=("$d")
    done
fi

for h in "${homes[@]}"; do
    f="$h/lib/security/blocked.certs"
    if [ ! -f "$f" ]; then
        warn "eMudhra block skipped for '$h': no lib/security/blocked.certs (JDK 8, or not a JDK)"
        continue
    fi
    if [ "$(head -1 "$f")" != "Algorithm=SHA-256" ]; then
        warn "eMudhra block skipped for '$h': unexpected first line in blocked.certs"
        continue
    fi
    # A runner may share its tool cache between concurrent jobs: write nothing when the
    # list is already complete, and otherwise replace it in one atomic rename.
    missing=0
    for fp in $FINGERPRINTS; do
        grep -qx "$fp" "$f" || missing=$((missing + 1))
    done
    if [ "$missing" -eq 0 ]; then
        echo "The 16 eMudhra certificates were already blocked in $h"
        continue
    fi
    [ -f "$f.orig" ] || cp -p "$f" "$f.orig"
    tmp=$(mktemp "$f.XXXXXX")
    {
        echo "Algorithm=SHA-256"
        { tail -n +2 "$f"; printf '%s\n' $FINGERPRINTS; } | grep -E '^[0-9A-F]{64}$' | sort -u
    } > "$tmp"
    chmod 644 "$tmp"   # mktemp creates the file readable by its owner only
    mv -f "$tmp" "$f"
    missing=0
    for fp in $FINGERPRINTS; do
        grep -qx "$fp" "$f" || missing=$((missing + 1))
    done
    if [ "$missing" -ne 0 ]; then
        echo "error: $missing eMudhra fingerprint(s) missing from $f after the update" >&2
        exit 1
    fi
    echo "Blocked the 16 eMudhra certificates in $h ($(grep -cE '^[0-9A-F]{64}$' "$f") entries in blocked.certs)"
done
