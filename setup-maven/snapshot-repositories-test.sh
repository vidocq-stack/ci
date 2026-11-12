#!/usr/bin/env bash
# The settings.xml that setup-maven and deploy-maven write read io.vidocq SNAPSHOTs from maven.vidocq.dev, then from
# its copy maven.bak.vidocq.dev, and never from Sonatype's central-snapshots.
#
# Why: for a SNAPSHOT, Maven asks every declared repository for its maven-metadata.xml (the first one that answers
# does not stop it), so a build with central-snapshots among them hit Sonatype for each io.vidocq artifact and failed
# on HTTP 429 (Mansart pull requests, 2026-11-12). But a few third-party SNAPSHOTs exist only on Sonatype
# (dev.langchain4j.cdi.mcp, which vidocq-runtime-langchain4j-cdi-mcp-extension needs), so the repository stays
# declared for dependencies, behind Maven's remote repository filter: a groupId allow-list that lets only those
# groupIds be asked of it. Plugins are all io.vidocq: no Sonatype among the plugin repositories.
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

# The ids of the profile's <repositories> (kind=repositories) or <pluginRepositories>, in order, on one line.
read_ids() { # read_ids <file> <repositories|pluginRepositories>
  awk -v kind="$2" '/<profiles>/{p=1} /<\/profiles>/{p=0}
    p && $0 ~ "<"kind">" {s=1} p && $0 ~ "</"kind">" {s=0}
    s && /<id>/ {gsub(/.*<id>|<\/id>.*/, ""); printf "%s ", $0}' "$1"
}

for action in setup-maven/action.yml deploy-maven/action.yml; do
  f="$HERE/../$action"
  check "$action: dependencies come from maven.vidocq.dev, its copy, then Sonatype (filtered)" \
    "vidocq-snapshots vidocq-snapshots-bak central-snapshots " "$(read_ids "$f" repositories)"
  check "$action: plugins come from maven.vidocq.dev and its copy only" \
    "vidocq-snapshots vidocq-snapshots-bak " "$(read_ids "$f" pluginRepositories)"
  # The filter: the allow-list file for central-snapshots, and the Maven arguments that switch it on.
  check "$action: only the langchain4j-cdi groupIds are allowed from central-snapshots" "2" \
    "$(grep -c -E "^\s*(dev\.langchain4j\.cdi|dev\.langchain4j\.cdi\.mcp)\s*$" "$f")"
  check "$action: the filter is switched on for every Maven of the job" "1" \
    "$(grep -c 'aether.remoteRepositoryFilter.groupId=true' "$f")"
  check "$action: the filter reads its list from ~/.m2/rrf" "1" \
    "$(grep -c 'aether.remoteRepositoryFilter.groupId.basedir=' "$f")"
  check "$action: the list is named after the repository id" "1" \
    "$(grep -c 'groupId-central-snapshots.txt' "$f")"
done

# The deploy still reaches Sonatype: the second pass and the fallback without maven.vidocq.dev credentials.
check "deploy-maven still copies the SNAPSHOT to central-snapshots" "1" \
  "$(grep -c 'central-snapshots-deploy::https://central.sonatype.com/repository/maven-snapshots/' "$HERE/../deploy-maven/action.yml")"

if [ "$failures" -gt 0 ]; then echo "$failures test(s) failed"; exit 1; fi
echo "all snapshot repository tests passed"
