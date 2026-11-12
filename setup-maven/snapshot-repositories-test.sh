#!/usr/bin/env bash
# The settings.xml that setup-maven and deploy-maven write read io.vidocq SNAPSHOTs from maven.vidocq.dev, then from
# its copy maven.bak.vidocq.dev, and never from Sonatype's central-snapshots. For a SNAPSHOT, Maven asks every
# declared repository for its maven-metadata.xml (the first one that answers does not stop it), so a build with
# central-snapshots among them hits Sonatype for each artifact and fails on HTTP 429 (Mansart PRs, 2026-11-12).
# The SNAPSHOTs still go to central-snapshots on deploy (a <server> and a deploy target, outside the profile).
# Run: bash setup-maven/snapshot-repositories-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

# The ids declared as repositories or plugin repositories of the settings.xml profile, in order, one per line.
read_ids() {
  awk '/<profiles>/{p=1} /<\/profiles>/{p=0} p' "$1" \
    | grep -E -A1 '<(plugin)?[Rr]epository>' | grep -o '<id>[^<]*</id>' | sed -e 's/<id>//' -e 's/<\/id>//'
}

for action in setup-maven/action.yml deploy-maven/action.yml; do
  ids="$(read_ids "$HERE/../$action" | tr '\n' ' ')"
  check "$action: repositories, then plugin repositories, in order" \
    "vidocq-snapshots vidocq-snapshots-bak vidocq-snapshots vidocq-snapshots-bak " "$ids"
  check "$action: no read from central-snapshots" "0" "$(read_ids "$HERE/../$action" | grep -c '^central-snapshots$')"
done

# The deploy still reaches Sonatype: the second pass and the fallback without maven.vidocq.dev credentials.
check "deploy-maven still copies the SNAPSHOT to central-snapshots" "1" \
  "$(grep -c 'central-snapshots-deploy::https://central.sonatype.com/repository/maven-snapshots/' "$HERE/../deploy-maven/action.yml")"

if [ "$failures" -gt 0 ]; then echo "$failures test(s) failed"; exit 1; fi
echo "all snapshot repository tests passed"
