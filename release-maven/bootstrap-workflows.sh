#!/usr/bin/env bash
# bootstrap-workflows.sh — generate .forgejo/workflows/release.yml for one or more
# Vidocq sub-projects, with inputs adapted to each project's io.vidocq.* deps.
#
# Usage:
#   ./bootstrap-workflows.sh <path-to-project> [<path> ...]
#
# Examples:
#   ./bootstrap-workflows.sh ../vidocq-parent       # generates minimal release.yml
#   ./bootstrap-workflows.sh ../vauban              # adds a parent_release input
#   ./bootstrap-workflows.sh ../cassini             # adds chappe/champollion/ravel/vauban/parent
#   ./bootstrap-workflows.sh ../*/                  # everything in one shot
#
# The script collects every distinct (groupId, artifactId) where the version is
# SNAPSHOT and the groupId starts with io.vidocq, across all pom.xml of the
# project (parent + dependency blocks). It then writes the release.yml with one
# `<artifact>_release` input per distinct dep.

set -euo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -eq 0 ]]; then
  cat >&2 <<EOF
usage: $0 <path-to-project> [<path> ...]

Generates .forgejo/workflows/release.yml for each given Vidocq sub-project,
with inputs adapted to the project's io.vidocq.* SNAPSHOT dependencies.
EOF
  exit 2
fi

# Extract distinct io.vidocq.* groupIds whose deps are SNAPSHOT (literal OR
# resolved via a ${property}). Output: one groupId per line, sorted, unique.
# We group by groupId because a "family" (e.g. all champollion-*) is released
# together → one input per upstream project, not per artifact.
#
# Fail-fast on legacy groupIds (fr.vidocq.*): exits 2 with a clear message,
# instead of generating a release.yml that silently ignores those deps. The
# old fr.vidocq.* coords no longer exist on Maven Central — every consumer
# must use io.vidocq.* exclusively.
collect_deps() {
  local project="$1"
  python3 - "$project" <<'PY'
import sys, re, xml.etree.ElementTree as ET
from pathlib import Path

project = Path(sys.argv[1]).resolve()
own_aids = set()       # artifactIds in this project
groupids = set()       # io.vidocq.* groupIds with at least one SNAPSHOT dep
LEGACY_GROUP_RE = re.compile(r'^fr\.vidocq(\..+)?$')

def parse(pom):
    text = pom.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
    if not m: return None, None
    ns = m.group(1)
    try:
        return ET.parse(pom).getroot(), ns
    except ET.ParseError:
        return None, None

# Walk <modules> depth-first from the root POM. Off-reactor POMs (e.g. the
# Model 4.0.0 standalone TCK runners — champollion-tck, cassini-tck, foy-tck
# etc.) are NOT in any <modules>, so they're ignored: they never reach Maven
# Central, so their SNAPSHOT deps shouldn't gate the release.
def walk_reactor(root_pom):
    seen = set()
    ordered = []
    def visit(pom_path):
        p = pom_path.resolve()
        if p in seen: return
        seen.add(p)
        root, ns = parse(pom_path)
        if root is None: return
        ordered.append(pom_path)
        modules_el = root.find(f'{{{ns}}}modules')
        if modules_el is None: return
        for m in modules_el.findall(f'{{{ns}}}module'):
            sub = (m.text or '').strip()
            if not sub: continue
            sub_pom = pom_path.parent / sub / 'pom.xml'
            if sub_pom.exists():
                visit(sub_pom)
    visit(root_pom)
    return ordered

reactor_poms = walk_reactor(project / 'pom.xml')

# Pass 1: collect own artifactIds AND merge every <properties> block across
# the reactor into a global table. Child modules routinely reference
# ${vauban.version} (etc.) defined only in the root POM; without this merge,
# `resolve()` on the child returns '' and a real SNAPSHOT slips by undetected.
# Local overrides still win when present (see `props` lookup below).
global_props = {}
for pom in reactor_poms:
    root, ns = parse(pom)
    if root is None: continue
    aid = root.findtext(f'{{{ns}}}artifactId')
    if aid: own_aids.add(aid)
    p = root.find(f'{{{ns}}}properties')
    if p is not None:
        for child in p:
            name = child.tag.split('}', 1)[-1]
            global_props.setdefault(name, (child.text or '').strip())

# Pass 2: build a per-POM property map (local overrides global), then walk
# parent + dependency coords.
PROP_RE = re.compile(r'^\$\{([^}]+)\}$')
for pom in reactor_poms:
    root, ns = parse(pom)
    if root is None: continue
    props = dict(global_props)   # start from reactor-wide table
    p = root.find(f'{{{ns}}}properties')
    if p is not None:
        for child in p:
            name = child.tag.split('}', 1)[-1]
            props[name] = (child.text or '').strip()   # local wins

    def resolve(v):
        m = PROP_RE.match(v or '')
        return props.get(m.group(1), '') if m else (v or '')

    def coord(elem):
        return (elem.findtext(f'{{{ns}}}groupId') or '',
                elem.findtext(f'{{{ns}}}artifactId') or '',
                elem.findtext(f'{{{ns}}}version') or '')

    for tag in (f'{{{ns}}}parent', f'{{{ns}}}dependency'):
        for elem in root.iter(tag):
            g, a, v = coord(elem)
            if LEGACY_GROUP_RE.match(g):
                print(f"❌ Legacy groupId '{g}' detected (artifact {a}) in {pom}", file=sys.stderr)
                print(f"   '{g}' has been replaced by 'io.vidocq.<project>' on Maven Central.", file=sys.stderr)
                print(f"   Update the POM groupId (and version if needed) before bootstrapping.", file=sys.stderr)
                sys.exit(2)
            if not g.startswith('io.vidocq'): continue
            if a in own_aids: continue       # self-reference: release-plugin bumps it
            resolved = resolve(v)
            if resolved.endswith('-SNAPSHOT'):
                groupids.add(g)

for g in sorted(groupids):
    print(g)
PY
}

# List the artifactIds of every reactor module that declares
# <maven.deploy.skip>true</maven.deploy.skip> in its own <properties>. Walks
# the reactor tree starting from the project root (depth-first via <modules>).
# These are skipped from `mvn deploy -pl !X,!Y,...` at release time.
collect_excluded() {
  local project="$1"
  python3 - "$project" <<'PY'
import sys, re, xml.etree.ElementTree as ET
from pathlib import Path

project = Path(sys.argv[1]).resolve()

def parse(pom):
    text = pom.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
    if not m: return None, None
    ns = m.group(1)
    try:
        return ET.parse(pom).getroot(), ns
    except ET.ParseError:
        return None, None

# Walk <modules> depth-first from the root POM. Off-reactor modules (not
# listed in any <modules>) are skipped — they aren't deployed anyway.
seen = set()
ordered = []
def walk(pom_path):
    p = pom_path.resolve()
    if p in seen: return
    seen.add(p)
    root, ns = parse(pom_path)
    if root is None: return
    ordered.append(pom_path)
    modules_el = root.find(f'{{{ns}}}modules')
    if modules_el is None: return
    for m in modules_el.findall(f'{{{ns}}}module'):
        sub = (m.text or '').strip()
        if not sub: continue
        sub_pom = pom_path.parent / sub / 'pom.xml'
        if sub_pom.exists():
            walk(sub_pom)

walk(project / 'pom.xml')

excluded = []
for pom in ordered:
    root, ns = parse(pom)
    if root is None: continue
    props = root.find(f'{{{ns}}}properties')
    if props is None: continue
    flag = props.findtext(f'{{{ns}}}maven.deploy.skip')
    if (flag or '').strip().lower() != 'true': continue
    aid = root.findtext(f'{{{ns}}}artifactId')
    if aid: excluded.append(aid)

for a in excluded:
    print(a)
PY
}

# Query Maven Central for the latest release version of a groupId.
#   central_latest io.vidocq.vauban  → "0.1.1" (or empty on miss/timeout)
#
# Strategy: parse maven-metadata.xml under repo1.maven.org for the conventional
# <project>-parent artifact (every Vidocq sub-project carries one). We bypass
# search.maven.org's Solr because it lags fresh releases by hours-to-days; the
# raw repo mirror is updated within seconds of the upload completing.
#
# Convention:
#   io.vidocq          → vidocq-parent
#   io.vidocq.<x>      → <x>-parent
#
# Best-effort: any error (404, timeout, malformed XML) → empty stdout + warning
# on stderr. The caller leaves the input blank in that case.
central_latest() {
  local groupid="$1"
  python3 - "$groupid" <<'PY' 2>/dev/null || true
import sys, urllib.request, urllib.error, xml.etree.ElementTree as ET

g = sys.argv[1]
g_path = g.replace('.', '/')
aid = "vidocq-parent" if g == "io.vidocq" else f"{g.rsplit('.', 1)[-1]}-parent"
url = f"https://repo1.maven.org/maven2/{g_path}/{aid}/maven-metadata.xml"

try:
    with urllib.request.urlopen(url, timeout=5) as resp:
        if resp.status != 200:
            print(f"⚠ no default for {g} (HTTP {resp.status})", file=sys.stderr)
            sys.exit(0)
        root = ET.fromstring(resp.read())
except urllib.error.HTTPError as e:
    # 404 is the common case: the project hasn't been released yet.
    print(f"⚠ no default for {g} ({aid}: HTTP {e.code})", file=sys.stderr)
    sys.exit(0)
except Exception as e:
    print(f"⚠ no default for {g} ({type(e).__name__}: {e})", file=sys.stderr)
    sys.exit(0)

# <release> wins when present (the highest non-SNAPSHOT version). Fall back to
# the last <version> in the list if the upstream metadata is missing <release>.
release = (root.findtext("./versioning/release") or "").strip()
if release:
    print(release)
    sys.exit(0)

stable = [v.text for v in root.findall("./versioning/versions/version")
          if v.text and not v.text.endswith("-SNAPSHOT")]
if stable:
    print(stable[-1])
PY
}

# Build a YAML-safe input key for a groupId.
# io.vidocq            → vidocq_parent_release (always the parent POM)
# io.vidocq.champollion → champollion_release
# io.vidocq.vauban      → vauban_release
input_key() {
  local groupid="$1"
  if [[ "$groupid" == "io.vidocq" ]]; then
    echo "vidocq_parent_release"
  else
    local last="${groupid##*.}"
    echo "${last}_release"
  fi
}

# Emit the release.yml content to stdout.
#
# Two channels carry the extra metadata (env vars so bash 3.2 arrays stay flat):
#   EXCLUDED_MODULES   multiline list of artifactIds to skip from `mvn deploy`
#   CENTRAL_DEFAULTS   multiline "groupId=version" map used to pre-fill input
#                      defaults; an empty value means "no default available".
emit_workflow() {
  local project_name="$1"
  shift
  # bash 3.2 (macOS) + `set -u` chokes on empty arrays; build defensively.
  local deps=()
  if [[ $# -gt 0 ]]; then deps=("$@"); fi

  cat <<EOF
# Generated by Vidocq/ci/release-maven/bootstrap-workflows.sh
# Re-run that script if the project's io.vidocq.* deps or deploy-skip flags change.
name: release

on:
  workflow_dispatch:
    inputs:
      release_version:
        description: "Release version (e.g. 0.1.0). Without -SNAPSHOT."
        type: string
        required: true
      next_dev_version:
        description: "Next dev version WITHOUT -SNAPSHOT (e.g. 0.2.0); the release action appends -SNAPSHOT automatically."
        type: string
        required: true
      dry_run:
        description: "Dry-run: build + sign + bundle without commit/tag/push/upload."
        type: choice
        required: true
        default: "false"
        options: ["false", "true"]
      auto_publish:
        description: "Promote: 'manual' (default; click Publish on Sonatype Portal) or 'auto' (publish + wait for repo1.maven.org)."
        type: choice
        required: true
        default: "manual"
        options: ["manual", "auto"]
EOF

  if (( ${#deps[@]} > 0 )); then
    for g in "${deps[@]}"; do
      local key pretty default_v
      key=$(input_key "$g")
      # Special-case io.vidocq: only one artifact lives under that groupId
      # (vidocq-parent). For every other groupId, mention that we lock all
      # artifacts of that family at once.
      if [[ "$g" == "io.vidocq" ]]; then
        pretty="io.vidocq:vidocq-parent"
      else
        pretty="${g}:* (all artifacts under ${g})"
      fi
      # Look up a Central-resolved default, if any (CENTRAL_DEFAULTS is fed by
      # process_project from `central_latest`). Missing entry → empty default →
      # no `default:` line emitted, maintainer fills the input by hand.
      default_v=$(printf '%s\n' "${CENTRAL_DEFAULTS:-}" | awk -F= -v g="$g" '$1==g {print $2; exit}')
      cat <<EOF
      ${key}:
        description: "${pretty} — stable version (must be released on Central first)"
        type: string
        required: true
EOF
      if [[ -n "$default_v" ]]; then
        printf '        default:     "%s"\n' "$default_v"
      fi
    done
  fi

  cat <<EOF

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: \${{ secrets.VIDOCQ_BOT_TOKEN }}
          # Always checkout the current HEAD of the branch, not the SHA captured
          # at dispatch time — ensures in-flight commits are included in the release.
          ref: \${{ github.ref_name }}

      - uses: https://codefloe.com/Vidocq/ci/release-maven@main
        with:
          release-version:  \${{ inputs.release_version }}
          next-dev-version: \${{ inputs.next_dev_version }}
          dry-run:          \${{ inputs.dry_run }}
          # Map 'manual'/'auto' → 'false'/'true' so the action.yml input stays boolean.
          auto-publish:     \${{ inputs.auto_publish == 'auto' && 'true' || 'false' }}
EOF

  if (( ${#deps[@]} > 0 )); then
    echo "          overrides: |"
    for g in "${deps[@]}"; do
      local key
      key=$(input_key "$g")
      # The ${{ ... }} is Forgejo Actions expression syntax, NOT bash expansion.
      # Single quotes around the format string keep it literal in the YAML output.
      # Format `groupId=version` (no artifactId) — release.sh patches every
      # io.vidocq.* dep + property under that groupId.
      printf '            %s=${{ inputs.%s }}\n' "$g" "$key"
    done
  fi

  # excluded-modules block — one artifactId per line, fed via the env var by
  # process_project (sourced from each module's <maven.deploy.skip>true</...>).
  if [[ -n "${EXCLUDED_MODULES:-}" ]]; then
    echo "          excluded-modules: |"
    while IFS= read -r mod; do
      [[ -z "$mod" ]] && continue
      printf '            %s\n' "$mod"
    done <<< "$EXCLUDED_MODULES"
  fi

  cat <<EOF
          central-username: \${{ secrets.CENTRAL_USERNAME }}
          central-password: \${{ secrets.CENTRAL_PASSWORD }}
          gpg-private-key:  \${{ secrets.GPG_PRIVATE_KEY }}
          gpg-passphrase:   \${{ secrets.GPG_PASSPHRASE }}
          gpg-key-id:       \${{ secrets.GPG_KEY_ID }}
          bot-token:        \${{ secrets.VIDOCQ_BOT_TOKEN }}

      - name: Notify Slack — release success
        if: success()
        uses: https://codefloe.com/Vidocq/ci/notify-slack@main
        with:
          webhook-url:      \${{ secrets.SLACK_WEBHOOK_URL }}
          status:           release-success
          repo:             \${{ github.repository }}
          ref:              \${{ github.ref_name }}
          run-url:          \${{ github.server_url }}/\${{ github.repository }}/actions/runs/\${{ github.run_number }}
          release-version:  \${{ inputs.release_version }}
          next-dev-version: \${{ inputs.next_dev_version }}
          release-tag-url:  \${{ github.server_url }}/\${{ github.repository }}/src/tag/v\${{ inputs.release_version }}

      - name: Notify Slack — release failure
        if: failure()
        uses: https://codefloe.com/Vidocq/ci/notify-slack@main
        with:
          webhook-url:      \${{ secrets.SLACK_WEBHOOK_URL }}
          status:           release-failure
          repo:             \${{ github.repository }}
          ref:              \${{ github.ref_name }}
          run-url:          \${{ github.server_url }}/\${{ github.repository }}/actions/runs/\${{ github.run_number }}
          release-version:  \${{ inputs.release_version }}
EOF
}

process_project() {
  local project_path
  project_path=$(cd "$1" && pwd)
  local project_name
  project_name=$(basename "$project_path")

  if [[ ! -f "$project_path/pom.xml" ]]; then
    echo "⚠ skip $project_name (no pom.xml at root)" >&2
    return
  fi

  local out_dir="$project_path/.forgejo/workflows"
  local out_file="$out_dir/release.yml"
  mkdir -p "$out_dir"

  # 1) SNAPSHOT cross-project deps → one input per groupId. Aborts (exit 2) on
  #    a legacy fr.vidocq.* coord; we must propagate that failure here, because
  #    `set -e` is silently bypassed when the python child runs inside
  #    `< <(... )` process substitution. Use command substitution + an explicit
  #    rc check so an abort actually stops the bootstrap (and skips emitting an
  #    incorrect release.yml).
  local deps_out deps_rc
  deps_out=$(collect_deps "$project_path") && deps_rc=0 || deps_rc=$?
  if (( deps_rc != 0 )); then
    echo "❌ aborting bootstrap for $project_name (collect_deps exited $deps_rc — see above)" >&2
    exit "$deps_rc"
  fi
  local deps=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && deps+=("$line")
  done <<< "$deps_out"

  # 2) Reactor modules carrying <maven.deploy.skip>true</...> → excluded-modules.
  local excluded
  excluded=$(collect_excluded "$project_path")
  local excluded_count
  excluded_count=$(printf '%s' "$excluded" | grep -c . || true)

  # 3) Best-effort default per input: ask Central for the latest release version
  #    of each groupId. Misses (404 / 0 results / timeout) leave the input bare.
  local defaults=""
  local default_count=0
  if (( ${#deps[@]} > 0 )); then
    for g in "${deps[@]}"; do
      local v
      v=$(central_latest "$g")
      if [[ -n "$v" ]]; then
        defaults+="${g}=${v}"$'\n'
        default_count=$(( default_count + 1 ))
      fi
    done
  fi

  # bash 3.2 (macOS) chokes on `"${arr[@]}"` when arr is empty under `set -u`.
  if (( ${#deps[@]} > 0 )); then
    EXCLUDED_MODULES="$excluded" CENTRAL_DEFAULTS="$defaults" \
      emit_workflow "$project_name" "${deps[@]}" > "$out_file"
  else
    EXCLUDED_MODULES="$excluded" CENTRAL_DEFAULTS="$defaults" \
      emit_workflow "$project_name" > "$out_file"
  fi
  echo "✅ $project_name: ${#deps[@]} dep(s) (${default_count} with Central default), ${excluded_count} excluded module(s) → $out_file"
}

for arg in "$@"; do
  process_project "$arg"
done
