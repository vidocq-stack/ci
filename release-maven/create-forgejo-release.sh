#!/usr/bin/env bash
# After a REAL release: create the Forgejo "release" (the Publications tab) for the tag v<version>, so
# a release is visible on the forge and not only as a bare tag. A version with a suffix (0.4.0-RC2) is
# flagged as a pre-release.
#
# Env:
#   PRODUCER_SLUG     forge slug of the producer that released, e.g. Vidocq/bodoni (required)
#   RELEASE_VERSION   the released version, e.g. 0.4.0-RC2 (required)
#   BOT_TOKEN         token with release-write access on the producer (required unless DRY_RUN)
#   GITHUB_SERVER_URL forge base URL (set by the runner)
#   DRY_RUN           "true": print what would be created and call nothing
#   Test hook: RELEASE_API_BASE (forge API base, default <forge>/api/v1).
#
# It never fails the job: the artifacts are out by the time it runs. A forge error is reported as a
# ::warning. It is idempotent: a tag that already has a release is left alone.
set -uo pipefail

: "${PRODUCER_SLUG:?PRODUCER_SLUG}" "${RELEASE_VERSION:?RELEASE_VERSION}"
FORGE="${GITHUB_SERVER_URL:-https://codefloe.com}"; FORGE="${FORGE%/}"
API="${RELEASE_API_BASE:-$FORGE/api/v1}"
TAG="v${RELEASE_VERSION}"
NAME="${PRODUCER_SLUG#*/} ${RELEASE_VERSION}"
case "$RELEASE_VERSION" in *-*) PRE=true ;; *) PRE=false ;; esac

if [[ "${DRY_RUN:-false}" == "true" ]]; then
  echo "dry run: would create the release ${TAG} (pre-release: ${PRE}) of ${PRODUCER_SLUG}"
  exit 0
fi
: "${BOT_TOKEN:?BOT_TOKEN}"

BODY="Release ${RELEASE_VERSION} of ${PRODUCER_SLUG#*/}. The artifacts are on Maven Central under https://repo1.maven.org/maven2/io/vidocq/ once the deployment is published on the Central Portal (about 15 to 30 minutes after the publication)."
PAYLOAD=$(printf '{"tag_name":"%s","name":"%s","body":"%s","draft":false,"prerelease":%s}' "$TAG" "$NAME" "$BODY" "$PRE")
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

http=$(curl -sS -o "$WORK/get.out" -w '%{http_code}' -H "Authorization: token ${BOT_TOKEN}" \
  "${API}/repos/${PRODUCER_SLUG}/releases/tags/${TAG}" 2>/dev/null || true)
if [[ "$http" == "200" ]]; then
  echo "release ${TAG} already exists on ${PRODUCER_SLUG}: left alone"
  exit 0
fi

http=$(curl -sS -o "$WORK/post.out" -w '%{http_code}' -X POST -H "Authorization: token ${BOT_TOKEN}" \
  -H 'Content-Type: application/json' -d "$PAYLOAD" "${API}/repos/${PRODUCER_SLUG}/releases" 2>/dev/null || true)
if [[ "$http" == "201" ]]; then
  echo "release ${TAG} created on ${PRODUCER_SLUG} (pre-release: ${PRE})"
else
  echo "::warning::could not create the release ${TAG} on ${PRODUCER_SLUG} (HTTP ${http:-none}); the tag is there, create it by hand"
fi
exit 0
