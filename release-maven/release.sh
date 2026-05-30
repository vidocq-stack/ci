#!/usr/bin/env bash
# release.sh — drive a Maven Central release end-to-end inside Forgejo Actions.
#
# Required env (passed by action.yml):
#   RELEASE_VERSION, NEXT_DEV_VERSION
#   OVERRIDES                      multiline "groupId:artifactId=version"
#   EXCLUDED_MODULES               multiline artifactIds excluded from `mvn deploy`
#   CENTRAL_USERNAME, CENTRAL_PASSWORD
#   GPG_PRIVATE_KEY, GPG_PASSPHRASE, GPG_KEY_ID
#   BOT_NAME, BOT_EMAIL, BOT_TOKEN
#   RELEASE_PROFILE                (default: release)
#   WAIT_TIMEOUT_SECONDS, WAIT_INTERVAL_SECONDS
#   DRY_RUN                        "true" → no push, no upload (branch + tag local only)
#   AUTO_PUBLISH                   "true" → bundle auto-published on Central
#
# Flow (10 steps):
#    1. precheck             clean tree, branch=main, env present, format versions
#    2. write_settings       ~/.m2/settings.xml (central + central-snapshots)
#    3. import_gpg           GPG signing key (base64 or armored)
#    4. reroute_ssh          insteadOf SSH→HTTPS for Codeberg pushes (bot token)
#    5. branch_create        git checkout -b release/${RELEASE_VERSION} (off main)
#                            All POM mutations land on the release branch — main
#                            is left untouched until the deploy succeeds.
#    6. apply_overrides      versions:update-parent / set-property / use-dep-version
#                            then fail-fast scan for residual io.vidocq.* SNAPSHOTs
#    7. set_version_and_commit
#                            versions:set RELEASE_VERSION (processAllModules)
#                            git commit on release/${RELEASE_VERSION}
#                            DRY_RUN=false → push branch, DRY_RUN=true → keep local
#    8. validate_build       mvn clean install (reactor) with a module-by-module
#                            fallback if Maven 4 RC-5 mis-orders the DAG
#    9. deploy               mvn -P release deploy -pl !${excluded}
#                            DRY_RUN=true → replaced by `verify` (sign + bundle, no upload)
#   10. tag_and_finalize     git tag v${RELEASE_VERSION} on release branch HEAD
#                            DRY_RUN=false → push tag, checkout main, versions:set
#                              NEXT_DEV_VERSION, commit, push main
#                            DRY_RUN=true → tag local only, main untouched
#       wait_central         DRY_RUN=true → skip (nothing was uploaded)
#                            DRY_RUN=false + AUTO_PUBLISH=true → poll repo1.maven.org
#                            DRY_RUN=false + AUTO_PUBLISH=false → print Portal URL
#
# Isolation guarantee:
# - main never moves before deploy succeeds. If anything fails between step 5
#   and step 9, main is bit-for-bit identical to its pre-release state.
# - If the Central upload fails (step 9), the release/${RELEASE_VERSION} branch
#   is destroyed automatically on both local and remote so the next attempt
#   starts from a clean slate. The Maven build log is the only evidence kept.
# - On deploy SUCCESS, release/${RELEASE_VERSION} stays as the audit trail and
#   hotfix base.

set -euo pipefail

# ---------------------------------------------------------------- helpers

die()  { printf '❌ %s\n' "$*" >&2; exit 1; }
info() { printf '▸  %s\n' "$*"; }
ok()   { printf '✅ %s\n' "$*"; }

# Maven Resolver default connectTimeout is 10s and requestTimeout 30 min. On
# the Forgejo runner (Foix), 10s is too short for the first cold downloads —
# we see `HTTP connect timed out` on Maven Central even though the deps exist.
# Bump both connect and request via Aether system properties on every mvn call.
MVN_NET_FLAGS="-Daether.connector.connectTimeout=60000 -Daether.connector.requestTimeout=300000"

# Globals filled by step_branch_create — consumed by later steps.
RELEASE_BRANCH=""
PRE_RELEASE_SHA=""

require_env() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "env $v is required but empty"
  done
}

# Walk every parent's <modules> tree depth-first starting from ./pom.xml. The
# declaration order is already topological by Vidocq convention (the maintainer
# lists producers before consumers). Used to bypass the Maven 4 RC-5 DAG sort
# bug where consumers are scheduled before their producers in vanilla reactor.
_walk_modules_in_declaration_order() {
  python3 - <<'PY'
import re, xml.etree.ElementTree as ET
from pathlib import Path

def parse(pom):
    text = pom.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
    if not m: return None, None
    ns = m.group(1)
    try:
        return ET.parse(pom).getroot(), ns
    except ET.ParseError:
        return None, None

def walk(pom_path, out, seen):
    p = pom_path.resolve()
    if p in seen: return
    seen.add(p)
    root, ns = parse(pom_path)
    if root is None: return
    out.append(str(pom_path.parent))
    modules_el = root.find(f'{{{ns}}}modules')
    if modules_el is None: return
    for m in modules_el.findall(f'{{{ns}}}module'):
        sub = (m.text or '').strip()
        if not sub: continue
        sub_pom = pom_path.parent / sub / 'pom.xml'
        if sub_pom.exists():
            walk(sub_pom, out, seen)

ordered = []
walk(Path('pom.xml'), ordered, set())
for d in ordered: print(d)
PY
}

# Run `mvn -N -P release clean install` in every reactor module, in <modules>
# declaration order. Each invocation handles a single POM (no recursion), so
# ~/.m2 fills linearly and consumers always find their producers' artifacts.
# The release profile is activated to pre-warm the cache (javadoc, source, gpg
# plugins) and attach sources/javadocs at install time — the deploy step (pass
# 2) then has nothing left to download.
_install_modules_in_declaration_order() {
  local modules_in_order rc=0 module_dir rel
  modules_in_order=$(_walk_modules_in_declaration_order)
  while IFS= read -r module_dir; do
    [[ -z "$module_dir" ]] && continue
    rel="${module_dir#./}"
    [[ "$rel" == "." || -z "$rel" ]] && rel="<root>"
    info "    • install ${rel}"
    set +e
    ( cd "$module_dir" && mvn -B -ntp ${MVN_NET_FLAGS} -N -P"${RELEASE_PROFILE}" clean install \
        -DskipTests \
        -Dgpg.passphrase="${GPG_PASSPHRASE}" \
        -Dgpg.keyname="${GPG_KEY_ID}" )
    rc=$?
    set -e
    [[ "$rc" != "0" ]] && return "$rc"
  done <<< "$modules_in_order"
  return 0
}

# Transform EXCLUDED_MODULES (multiline, one artifactId per line, # comments
# tolerated) into a comma-separated "!a,!b,!c" string suitable for `mvn -pl`.
# Empty input → empty output (caller must omit -pl entirely in that case).
_build_excluded_pl_args() {
  local result="" mod
  while IFS= read -r mod; do
    mod="${mod#"${mod%%[![:space:]]*}"}"
    mod="${mod%"${mod##*[![:space:]]}"}"
    [[ -z "$mod" || "$mod" == \#* ]] && continue
    if [[ -z "$result" ]]; then
      result="!${mod}"
    else
      result="${result},!${mod}"
    fi
  done <<< "${EXCLUDED_MODULES:-}"
  printf '%s' "$result"
}

# ---------------------------------------------------------------- 1. pre-checks

step_precheck() {
  info "Pre-checks"
  require_env RELEASE_VERSION NEXT_DEV_VERSION \
              CENTRAL_USERNAME CENTRAL_PASSWORD \
              GPG_PRIVATE_KEY GPG_PASSPHRASE GPG_KEY_ID

  # Default the two toggles if unset (e.g. when sourced standalone).
  : "${DRY_RUN:=false}"
  : "${AUTO_PUBLISH:=false}"
  : "${EXCLUDED_MODULES:=}"

  [[ "$RELEASE_VERSION" != *-SNAPSHOT ]] \
    || die "RELEASE_VERSION must not end with -SNAPSHOT, got '$RELEASE_VERSION'"
  [[ "$NEXT_DEV_VERSION" == *-SNAPSHOT ]] \
    || die "NEXT_DEV_VERSION must end with -SNAPSHOT, got '$NEXT_DEV_VERSION'"

  local branch dirty untracked tracked
  branch=$(git symbolic-ref --short HEAD)
  [[ "$branch" == "main" ]] || die "branch is '$branch'; release must run on main"

  # Distinguish untracked (safe to remove — typically tooling leaks like .m2/,
  # .gradle/, .ci-action/) from modified-tracked (must NOT be auto-cleaned).
  untracked=$(git status --porcelain | grep -c '^?? ' || true)
  tracked=$(git status --porcelain | grep -cv '^?? ' || true)

  if (( untracked > 0 )); then
    info "Found $untracked untracked path(s) (tooling leak — removing):"
    git status --porcelain | grep '^?? ' | sed 's/^/    /'
    git clean -fdq -e .git
  fi

  dirty=$(git status --porcelain | wc -l | tr -d ' ')
  if [[ "$dirty" != "0" ]]; then
    echo "❌ working tree still has $dirty modified TRACKED file(s) after untracked cleanup:" >&2
    git status --porcelain >&2
    echo "" >&2
    echo "Hint: these are tracked files modified between checkout and the precheck." >&2
    echo "      Could not auto-clean (would lose data). Investigate the workflow." >&2
    exit 1
  fi

  git config user.name  "${BOT_NAME:-Vidocq CI Bot}"
  git config user.email "${BOT_EMAIL:-ci@vidocq.dev}"

  local mode="real release"
  [[ "$DRY_RUN" == "true" ]] && mode="DRY-RUN (no push, no upload)"
  ok "pre-checks passed (branch=$branch, clean, $RELEASE_VERSION → $NEXT_DEV_VERSION, $mode)"
  if [[ "$DRY_RUN" != "true" ]]; then
    if [[ "$AUTO_PUBLISH" == "true" ]]; then
      info "AUTO_PUBLISH=true → bundle will be published automatically after Sonatype validation"
    else
      info "AUTO_PUBLISH=false → bundle will stay in VALIDATED state, waiting for manual click on Portal"
    fi
  fi
  local pl_args
  pl_args=$(_build_excluded_pl_args)
  if [[ -n "$pl_args" ]]; then
    info "Excluded modules (deploy will skip): ${pl_args//,/ }"
  else
    info "No module exclusions — every reactor module will be deployed"
  fi
}

# ---------------------------------------------------------------- 2. settings.xml

step_write_settings() {
  info "Writing ~/.m2/settings.xml"
  mkdir -p ~/.m2
  cat > ~/.m2/settings.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings>
  <servers>
    <server>
      <id>central</id>
      <username>${CENTRAL_USERNAME}</username>
      <password>${CENTRAL_PASSWORD}</password>
    </server>
    <server>
      <id>central-snapshots</id>
      <username>${CENTRAL_USERNAME}</username>
      <password>${CENTRAL_PASSWORD}</password>
    </server>
  </servers>
  <profiles>
    <profile>
      <id>vidocq-snapshots</id>
      <repositories>
        <repository>
          <id>central-snapshots</id>
          <url>https://central.sonatype.com/repository/maven-snapshots/</url>
          <releases><enabled>false</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
      </repositories>
      <pluginRepositories>
        <pluginRepository>
          <id>central-snapshots</id>
          <url>https://central.sonatype.com/repository/maven-snapshots/</url>
          <releases><enabled>false</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </pluginRepository>
      </pluginRepositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>vidocq-snapshots</activeProfile>
  </activeProfiles>
</settings>
EOF
  ok "settings.xml written"
}

# ---------------------------------------------------------------- 3. GPG + SSH reroute

# Reroute `git push ssh://git@codeberg.org/...` to HTTPS-with-token. POMs
# declare <developerConnection>ssh://...</developerConnection> by convention,
# and the runner has no SSH key for Codeberg. The insteadOf config is global
# so every subsequent git push is rerouted transparently.
step_reroute_ssh() {
  if [[ -z "${BOT_TOKEN:-}" ]]; then
    info "Skipping SSH→HTTPS reroute (BOT_TOKEN not provided)"
    return 0
  fi
  info "Rerouting ssh://git@codeberg.org/* to https://oauth2:<token>@codeberg.org/*"
  git config --global --add "url.https://oauth2:${BOT_TOKEN}@codeberg.org/.insteadOf" "ssh://git@codeberg.org/"
  git config --global --add "url.https://oauth2:${BOT_TOKEN}@codeberg.org/.insteadOf" "ssh://codeberg.org/"
  ok "SSH→HTTPS reroute armed"
}

step_import_gpg() {
  info "Importing GPG signing key"
  if echo "$GPG_PRIVATE_KEY" | base64 -d 2>/dev/null | gpg --batch --import 2>/dev/null; then
    ok "GPG key imported (base64-decoded)"
  else
    echo "$GPG_PRIVATE_KEY" | gpg --batch --import
    ok "GPG key imported (ASCII-armored)"
  fi
  gpg --list-secret-keys --with-colons | grep -q '^sec' \
    || die "GPG key import failed — no secret key visible"
  local fpr
  fpr=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
  echo -e "5\ny\n" | gpg --batch --command-fd 0 --expert --edit-key "$fpr" trust quit 2>/dev/null || true
}

# ---------------------------------------------------------------- 5. branch_create

# Create the release/${RELEASE_VERSION} branch off main BEFORE any POM mutation.
# Every subsequent commit (overrides, version bump) lands on this branch, never
# on main. If the release fails, deleting the branch is the entire rollback.
#
# Pre-existence checks: a leftover branch from a previous failed run blocks the
# retry so the maintainer can audit before discarding.
step_branch_create() {
  PRE_RELEASE_SHA=$(git rev-parse HEAD)
  RELEASE_BRANCH="release/${RELEASE_VERSION}"

  if git show-ref --verify --quiet "refs/heads/${RELEASE_BRANCH}"; then
    die "branch ${RELEASE_BRANCH} already exists locally — investigate, delete, retry"
  fi
  if [[ "$DRY_RUN" != "true" ]] \
     && git ls-remote --exit-code --heads origin "${RELEASE_BRANCH}" >/dev/null 2>&1; then
    die "branch ${RELEASE_BRANCH} already exists on remote — release likely in flight or failed previously"
  fi

  info "Creating ${RELEASE_BRANCH} off main (${PRE_RELEASE_SHA})"
  git checkout -b "${RELEASE_BRANCH}"
  ok "on branch ${RELEASE_BRANCH}"
}

# ---------------------------------------------------------------- 6. apply_overrides + failfast

# Parse OVERRIDES env. Accepted formats (one per line, blanks/# ignored):
#   groupId=version           → applies to every io.vidocq.* dep with that groupId
#   groupId:artifactId=version → narrow override for one coord
# Emits tab-separated "scope\tkey\tversion" where scope is "group" or "coord".
parse_overrides() {
  local line key v
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || die "bad override line (missing '='): $line"
    key="${line%%=*}"; v="${line#*=}"
    if [[ "$key" == *:* ]]; then
      printf 'coord\t%s\t%s\n' "$key" "$v"
    else
      printf 'group\t%s\t%s\n' "$key" "$v"
    fi
  done <<< "$OVERRIDES"
}

# List the property names referenced as ${X} inside any <dependency groupId="$1">
# version field across the reactor. Used to drive versions:set-property.
detect_props_for_group() {
  local g="$1"
  python3 - "$g" <<'PY'
import sys, re, xml.etree.ElementTree as ET
from pathlib import Path
g = sys.argv[1]
PROP_RE = re.compile(r'^\$\{([^}]+)\}$')
seen = set()
for pom in Path('.').rglob('pom.xml'):
    if any(p in ('target', 'node_modules') or (p != '.' and p.startswith('.')) for p in pom.parts): continue
    text = pom.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
    if not m: continue
    ns = m.group(1)
    try: root = ET.parse(pom).getroot()
    except ET.ParseError: continue
    for dep in root.iter(f'{{{ns}}}dependency'):
        if (dep.findtext(f'{{{ns}}}groupId') or '') != g: continue
        raw = (dep.findtext(f'{{{ns}}}version') or '').strip()
        mp = PROP_RE.match(raw)
        if mp: seen.add(mp.group(1))
    parent = root.find(f'{{{ns}}}parent')
    if parent is not None and (parent.findtext(f'{{{ns}}}groupId') or '') == g:
        raw = (parent.findtext(f'{{{ns}}}version') or '').strip()
        mp = PROP_RE.match(raw)
        if mp: seen.add(mp.group(1))
for p in sorted(seen): print(p)
PY
}

# List groupId:artifactId of <dependency> blocks for this groupId whose
# <version> is a LITERAL SNAPSHOT (not a ${prop}). Feeds versions:use-dep-version.
# Skips <parent> (handled by versions:update-parent) and own-project artifacts.
detect_literal_coords_for_group() {
  local g="$1"
  python3 - "$g" <<'PY'
import sys, re, xml.etree.ElementTree as ET
from pathlib import Path
g = sys.argv[1]
PROP_RE = re.compile(r'^\$\{([^}]+)\}$')
own_aids = set()
poms = []
for pom in Path('.').rglob('pom.xml'):
    if any(p in ('target', 'node_modules') or (p != '.' and p.startswith('.')) for p in pom.parts): continue
    poms.append(pom)
for pom in poms:
    text = pom.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
    if not m: continue
    ns = m.group(1)
    try: root = ET.parse(pom).getroot()
    except ET.ParseError: continue
    aid = root.findtext(f'{{{ns}}}artifactId')
    if aid: own_aids.add(aid)
seen = set()
for pom in poms:
    text = pom.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
    if not m: continue
    ns = m.group(1)
    try: root = ET.parse(pom).getroot()
    except ET.ParseError: continue
    for dep in root.iter(f'{{{ns}}}dependency'):
        if (dep.findtext(f'{{{ns}}}groupId') or '') != g: continue
        a = (dep.findtext(f'{{{ns}}}artifactId') or '')
        if a in own_aids: continue
        raw = (dep.findtext(f'{{{ns}}}version') or '').strip()
        if PROP_RE.match(raw): continue
        if raw.endswith('-SNAPSHOT'):
            seen.add(f"{g}:{a}")
for c in sorted(seen): print(c)
PY
}

# Replace io.vidocq.* SNAPSHOTs by running versions-maven-plugin goals:
#   - versions:update-parent      → root <parent>
#   - versions:set-property       → <dependency><version>${X}</version>
#   - versions:use-dep-version    → <dependency><version>X-SNAPSHOT</version> literal
# Runs on the release branch — main is untouched.
step_apply_overrides() {
  info "Applying overrides (on ${RELEASE_BRANCH})"
  if [[ -z "${OVERRIDES// /}" ]]; then
    ok "no overrides given (project has no io.vidocq.* SNAPSHOT deps to lock)"
    return
  fi

  local parent_coords parent_g parent_a
  parent_coords=$(python3 - <<'PY'
import re, xml.etree.ElementTree as ET
try:
    text = open('pom.xml', encoding='utf-8').read()
except FileNotFoundError:
    print(""); raise SystemExit(0)
m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
if not m:
    print(""); raise SystemExit(0)
ns = m.group(1)
try:
    root = ET.fromstring(text)
except ET.ParseError:
    print(""); raise SystemExit(0)
p = root.find(f'{{{ns}}}parent')
if p is None:
    print("")
else:
    g = (p.findtext(f'{{{ns}}}groupId') or '').strip()
    a = (p.findtext(f'{{{ns}}}artifactId') or '').strip()
    print(f"{g}\t{a}")
PY
  )
  parent_g="${parent_coords%%$'\t'*}"
  parent_a="${parent_coords##*$'\t'}"
  [[ "$parent_coords" == *$'\t'* ]] || { parent_g=""; parent_a=""; }
  info "  root parent: ${parent_g:-<none>}:${parent_a:-<none>}"

  local scope key v g a
  while IFS=$'\t' read -r scope key v; do
    [[ -z "${scope:-}" ]] && continue
    if [[ "$scope" == "coord" ]]; then
      g="${key%%:*}"; a="${key#*:}"
    else
      g="$key"; a=""
    fi
    info "Override: ${key} → ${v}"

    # 1) <parent>. Preferred: versions:update-parent (validates via repos).
    #    Fallback: direct XML edit when the parent version has been UPLOADED
    #    but not yet PUBLISHED on Central, OR when mvn silently no-ops because
    #    `allowSnapshots=false` discarded the only candidate it found.
    if [[ -n "$parent_g" && "$g" == "$parent_g" ]] \
       && { [[ -z "$a" ]] || [[ "$a" == "$parent_a" ]]; }; then
      info "  • <parent> ${parent_g}:${parent_a} → ${v}"
      local up_log=/tmp/release-update-parent.$$.log
      set +e
      mvn -B -ntp ${MVN_NET_FLAGS} versions:update-parent \
          -DparentVersion="$v" -DallowSnapshots=false -DgenerateBackupPoms=false 2>&1 | tee "$up_log"
      local up_rc=${PIPESTATUS[0]}
      set -e
      local current_v
      current_v=$(python3 - <<'PY'
import re, xml.etree.ElementTree as ET
try:
    text = open('pom.xml', encoding='utf-8').read()
except FileNotFoundError:
    print(""); raise SystemExit(0)
m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
if not m: print(""); raise SystemExit(0)
ns = m.group(1)
try: root = ET.fromstring(text)
except ET.ParseError: print(""); raise SystemExit(0)
p = root.find(f'{{{ns}}}parent')
print((p.findtext(f'{{{ns}}}version') or '').strip() if p is not None else "")
PY
)
      if [[ "$up_rc" != "0" ]] \
         || grep -q 'No versions found' "$up_log" \
         || [[ "$current_v" != "$v" ]]; then
        if [[ "$current_v" != "$v" && "$up_rc" == "0" ]] \
           && ! grep -q 'No versions found' "$up_log"; then
          info "    ↻ mvn finished BUILD SUCCESS but left pom.xml unchanged"
          info "    ↻ (parent version still ${current_v:-<empty>}, expected ${v})"
        else
          info "    ↻ mvn could not resolve ${parent_g}:${parent_a}:${v} on the configured repos"
        fi
        info "    ↻ falling back to a direct XML edit of pom.xml's <parent><version>"
        python3 - "$parent_g" "$parent_a" "$v" <<'PY'
import sys, re, xml.etree.ElementTree as ET
g, a, v = sys.argv[1], sys.argv[2], sys.argv[3]
text = open('pom.xml', encoding='utf-8').read()
m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
if not m:
    raise SystemExit("pom.xml has no xmlns")
ns = m.group(1)
ET.register_namespace('', ns)
tree = ET.parse('pom.xml')
root = tree.getroot()
p = root.find(f'{{{ns}}}parent')
if p is None:
    print(f"      (root pom has no <parent>; nothing to do)")
    raise SystemExit(0)
pg = (p.findtext(f'{{{ns}}}groupId') or '').strip()
pa = (p.findtext(f'{{{ns}}}artifactId') or '').strip()
if pg != g or pa != a:
    print(f"      (root <parent> is {pg}:{pa}, not {g}:{a}; nothing to do)")
    raise SystemExit(0)
ve = p.find(f'{{{ns}}}version')
if ve is None:
    raise SystemExit(0)
old = (ve.text or '').strip()
ve.text = v
tree.write('pom.xml', encoding='utf-8', xml_declaration=True)
print(f"      patched <parent><version>: {old} → {v}")
PY
      fi
      rm -f "$up_log"
    fi

    # 2) Properties referenced by <dependency groupId=$g> blocks.
    local prop
    while IFS= read -r prop; do
      [[ -z "$prop" ]] && continue
      info "  • property \${${prop}} → ${v}"
      mvn -B -ntp ${MVN_NET_FLAGS} versions:set-property \
          -Dproperty="$prop" -DnewVersion="$v" \
          -DallowSnapshots=false -DgenerateBackupPoms=false
    done < <(detect_props_for_group "$g")

    # 3) Literal <dependency><version>X-SNAPSHOT</version> (rare under Vidocq
    #    convention but covered for safety).
    local ga
    while IFS= read -r ga; do
      [[ -z "$ga" ]] && continue
      if [[ -n "$a" && "$ga" != "${g}:${a}" ]]; then continue; fi
      info "  • literal <dependency> ${ga} → ${v}"
      mvn -B -ntp ${MVN_NET_FLAGS} versions:use-dep-version \
          -Dincludes="$ga" -DdepVersion="$v" -DforceVersion=true \
          -DgenerateBackupPoms=false
    done < <(detect_literal_coords_for_group "$g")
  done < <(parse_overrides)

  ok "overrides applied"
}

# Scan for residual io.vidocq.* SNAPSHOTs (resolved through properties).
# Self-references (this project's own artifactIds) are ignored — they will be
# flipped by step_set_version_and_commit.
step_failfast_scan() {
  info "Scanning for residual io.vidocq.* SNAPSHOTs"
  python3 <<'PY' || exit 1
import re, sys, xml.etree.ElementTree as ET
from pathlib import Path

PROP_RE = re.compile(r'^\$\{([^}]+)\}$')

own_aids = set()
def parse(pom):
    text = pom.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
    if not m: return None, None
    ns = m.group(1)
    try:
        return ET.parse(pom).getroot(), ns
    except ET.ParseError:
        return None, None

poms = [p for p in Path('.').rglob('pom.xml')
        if not any(part in ('target', 'node_modules') or (part != '.' and part.startswith('.')) for part in p.parts)]

for pom in poms:
    root, ns = parse(pom)
    if root is None: continue
    aid = root.findtext(f'{{{ns}}}artifactId')
    if aid: own_aids.add(aid)

bad = []
for pom in poms:
    root, ns = parse(pom)
    if root is None: continue
    props_el = root.find(f'{{{ns}}}properties')
    props = {}
    if props_el is not None:
        for child in props_el:
            name = child.tag.split('}', 1)[-1]
            props[name] = (child.text or '').strip()

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
            if not g.startswith('io.vidocq'): continue
            if a in own_aids: continue
            resolved = resolve(v)
            if resolved.endswith('-SNAPSHOT'):
                bad.append((str(pom), g, a, v, resolved))

if bad:
    print("❌ Residual io.vidocq.* SNAPSHOTs — provide overrides for these:", file=sys.stderr)
    for pom, g, a, raw, resolved in bad:
        if raw != resolved:
            print(f"  - {g}:{a} = {raw} (resolved {resolved}) in {pom}", file=sys.stderr)
        else:
            print(f"  - {g}:{a} = {resolved} in {pom}", file=sys.stderr)
    print("\nAdd to the workflow's `overrides` input (one per line):", file=sys.stderr)
    print("    <groupId>=<stable-version>             # all artifacts of that groupId", file=sys.stderr)
    print("    <groupId>:<artifactId>=<stable-version> # narrow override", file=sys.stderr)
    sys.exit(1)
print("  no io.vidocq.* SNAPSHOTs remain")
PY
  ok "no residual io.vidocq.* SNAPSHOTs"
}

# ---------------------------------------------------------------- 7. set_version_and_commit

# Flip every reactor module to RELEASE_VERSION and commit on the release branch.
# -DprocessAllModules=true is critical under Model 4.1: submodules whose
# <parent> declares an implicit version (no <version> tag) are skipped by
# versions:set without it.
step_set_version_and_commit() {
  info "Setting reactor version to ${RELEASE_VERSION}"
  mvn -B -ntp ${MVN_NET_FLAGS} versions:set \
      -DnewVersion="${RELEASE_VERSION}" \
      -DprocessAllModules=true \
      -DgenerateBackupPoms=false

  if [[ -z "$(git status --porcelain)" ]]; then
    info "no POM changes — versions:set was a no-op"
  else
    info "Committing on ${RELEASE_BRANCH}"
    git add -A
    git commit -m "release: ${RELEASE_VERSION}"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: branch ${RELEASE_BRANCH} kept LOCAL (not pushed)"
    return 0
  fi

  info "Pushing ${RELEASE_BRANCH} to origin"
  git push -u origin "${RELEASE_BRANCH}"
  ok "${RELEASE_BRANCH} pushed"
}

# ---------------------------------------------------------------- 8. validate_build

# Build the full reactor to validate the release-locked POMs and pre-warm
# ~/.m2 for the deploy step. The release profile is activated here so every
# release-time plugin (javadoc, source, gpg) is resolved and run during
# install — without it, those plugins would be pulled at deploy time, when
# any transient network glitch on the Forgejo runner (Foix has shown timeouts
# fetching central transitives) aborts the upload after we already committed
# and pushed the release branch.
#
# Try the standard reactor first; if Maven 4 RC-5 mis-orders the DAG (consumers
# scheduled before producers — visible as `Could not find artifact io.vidocq.*`),
# fall back to a module-by-module install in <modules> declaration order.
step_validate_build() {
  info "Validating build with -P${RELEASE_PROFILE} (reactor first, pre-warms ~/.m2 for deploy)"
  local log
  log=$(mktemp)
  set +e
  mvn -B -ntp ${MVN_NET_FLAGS} -P"${RELEASE_PROFILE}" clean install \
      -DskipTests \
      -Dgpg.passphrase="${GPG_PASSPHRASE}" \
      -Dgpg.keyname="${GPG_KEY_ID}" 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  set -e

  if [[ "$rc" == "0" ]]; then
    rm -f "$log"
    ok "build OK (reactor)"
    return 0
  fi

  if grep -q 'Could not find artifact io.vidocq' "$log"; then
    info "↻ DAG reorder detected — falling back to module-by-module install"
    rm -f "$log"
    if _install_modules_in_declaration_order; then
      ok "build OK (module-by-module fallback)"
      return 0
    fi
    die "module-by-module install failed too — real compile/test error"
  fi
  rm -f "$log"
  die "reactor build failed (rc=${rc}) — not a DAG reorder, real error in the logs above"
}

# ---------------------------------------------------------------- 9. deploy

# Real release: `mvn -P release deploy -pl !X,!Y,!Z` with central-publishing
# bundling and signing everything. Pass 1 (validate_build) populated ~/.m2 so
# central-publishing's reactor reorder no longer breaks dependency resolution.
#
# DRY_RUN: replaced by `mvn verify`. Signs and bundles locally, never uploads.
step_deploy() {
  export GPG_TTY=$(tty || echo /dev/null)
  local pl_args
  pl_args=$(_build_excluded_pl_args)
  local pl_flag=""
  [[ -n "$pl_args" ]] && pl_flag="-pl ${pl_args}"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: mvn -P${RELEASE_PROFILE} verify ${pl_flag} (sign + bundle, NO upload)"
    set +e
    mvn -B -ntp ${MVN_NET_FLAGS} -P"${RELEASE_PROFILE}" verify ${pl_flag} \
        -DskipTests \
        -Dmaven.install.skip=true \
        -Dgpg.passphrase="${GPG_PASSPHRASE}" \
        -Dgpg.keyname="${GPG_KEY_ID}" \
        -Dcentral.publishing.autoPublish=false
    local rc=$?
    set -e
    if [[ "$rc" != "0" ]]; then
      die "DRY-RUN verify failed (rc=${rc}) — nothing was pushed, branch ${RELEASE_BRANCH} stays local"
    fi
    info "Bundle artifacts (target/central-publishing or target/checkout):"
    find . -path '*/target/central-publishing*' -name '*.zip' -print 2>/dev/null | head -20 || true
    find . -path '*/target/*.asc' -print 2>/dev/null | head -10 || true
    ok "DRY-RUN deploy complete — POMs signed, bundle generated, NOT uploaded"
    return 0
  fi

  info "mvn -P${RELEASE_PROFILE} deploy ${pl_flag} (autoPublish=${AUTO_PUBLISH})"
  set +e
  mvn -B -ntp ${MVN_NET_FLAGS} -P"${RELEASE_PROFILE}" deploy ${pl_flag} \
      -DskipTests \
      -Dmaven.install.skip=true \
      -Dgpg.passphrase="${GPG_PASSPHRASE}" \
      -Dgpg.keyname="${GPG_KEY_ID}" \
      -Dcentral.publishing.autoPublish="${AUTO_PUBLISH}"
  local rc=$?
  set -e
  if [[ "$rc" != "0" ]]; then
    info "↻ deploy failed (rc=${rc}) — destroying release branch ${RELEASE_BRANCH} (local + remote)"
    info "↻ main is untouched ; the Maven build log above is the only evidence kept"
    # Switch off the branch so we can delete it. Use main as the safe parking spot.
    git checkout main 2>/dev/null || true
    git branch -D "${RELEASE_BRANCH}" 2>/dev/null && info "  - local branch deleted" || info "  - local branch not present (already gone)"
    if git push origin --delete "${RELEASE_BRANCH}" 2>&1; then
      info "  - remote branch deleted on origin"
    else
      info "  - remote branch delete failed (possibly already gone or never pushed)"
    fi
    die "deploy failed (rc=${rc}) — release branch destroyed, no tag, no main bump, no Slack release-success"
  fi
  ok "deploy complete"
}

# ---------------------------------------------------------------- 10. tag + finalize

# Tag v${RELEASE_VERSION} on the release branch HEAD. On a real run: push the
# tag, switch back to main, bump main to NEXT_DEV_VERSION, push main.
# On a dry run: tag locally only; main is never touched, branch stays local.
step_tag_and_finalize() {
  info "Tagging v${RELEASE_VERSION} on ${RELEASE_BRANCH}"
  git tag -a "v${RELEASE_VERSION}" -m "Release ${RELEASE_VERSION}"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: tag v${RELEASE_VERSION} kept LOCAL (not pushed)"
    info "DRY-RUN: main NOT bumped; branch ${RELEASE_BRANCH} stays local"
    ok "DRY-RUN finalize complete"
    return 0
  fi

  info "Pushing tag v${RELEASE_VERSION}"
  git push origin "v${RELEASE_VERSION}"

  info "Switching back to main to bump dev version"
  git checkout main
  mvn -B -ntp ${MVN_NET_FLAGS} versions:set \
      -DnewVersion="${NEXT_DEV_VERSION}" \
      -DprocessAllModules=true \
      -DgenerateBackupPoms=false

  if [[ -n "$(git status --porcelain)" ]]; then
    git add -A
    git commit -m "post-release: bump to ${NEXT_DEV_VERSION}"
    git push origin main
    ok "main bumped to ${NEXT_DEV_VERSION} and pushed"
  else
    info "main already at ${NEXT_DEV_VERSION} — nothing to commit"
  fi
}

# ---------------------------------------------------------------- 11. wait Central

# Enumerate (groupId, artifactId) for every reactor module that is deployable
# AND not in EXCLUDED_MODULES. Honors <maven.deploy.skip>true</maven.deploy.skip>.
list_deployable_coords() {
  EXCLUDED_MODULES="${EXCLUDED_MODULES:-}" python3 <<'PY'
import os, re, xml.etree.ElementTree as ET
from pathlib import Path

excluded = set()
for line in (os.environ.get('EXCLUDED_MODULES') or '').splitlines():
    line = line.strip()
    if line and not line.startswith('#'):
        excluded.add(line)

def text(pom):
    return pom.read_text(encoding='utf-8', errors='replace')

def ns(pom):
    m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text(pom))
    return m.group(1) if m else 'http://maven.apache.org/POM/4.0.0'

def skip_deploy(root, ns_):
    p = root.find(f'{{{ns_}}}properties')
    if p is None: return False
    v = p.findtext(f'{{{ns_}}}maven.deploy.skip')
    return (v or '').strip().lower() == 'true'

def resolve_g(root, ns_):
    g = root.findtext(f'{{{ns_}}}groupId')
    if g: return g
    parent = root.find(f'{{{ns_}}}parent')
    if parent is not None:
        return parent.findtext(f'{{{ns_}}}groupId') or ''
    return ''

for pom in Path('.').rglob('pom.xml'):
    if any(p in pom.parts for p in ('target', 'node_modules')):
        continue
    n = ns(pom)
    try:
        root = ET.parse(pom).getroot()
    except ET.ParseError:
        continue
    if skip_deploy(root, n):
        continue
    a = root.findtext(f'{{{n}}}artifactId') or ''
    if a in excluded:
        continue
    g = resolve_g(root, n)
    if g and a:
        print(f"{g}:{a}")
PY
}

step_wait_central() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "DRY-RUN: skipping wait-for-Central (nothing was uploaded)"
    return 0
  fi
  if [[ "$AUTO_PUBLISH" != "true" ]]; then
    info "Skipping wait-for-Central (AUTO_PUBLISH=false → bundle awaiting manual Publish on the Portal)"
    info "  → Go to: https://central.sonatype.com/publishing/deployments"
    info "  → Locate the deployment for ${RELEASE_VERSION}, click Publish."
    info "  → Then verify https://repo1.maven.org/maven2/io/vidocq/... after ~15-30 min."
    return 0
  fi
  info "Waiting for Maven Central propagation (timeout=${WAIT_TIMEOUT_SECONDS}s, interval=${WAIT_INTERVAL_SECONDS}s)"
  local coords pom_url deadline now
  mapfile -t coords < <(list_deployable_coords | sort -u)
  info "  Checking ${#coords[@]} deployable artifact(s) for version ${RELEASE_VERSION}"

  deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECONDS ))
  local pending=("${coords[@]}")
  local next_pending=()

  while (( ${#pending[@]} > 0 )); do
    next_pending=()
    for ga in "${pending[@]}"; do
      local g="${ga%%:*}" a="${ga#*:}"
      local g_path="${g//.//}"
      pom_url="https://repo1.maven.org/maven2/${g_path}/${a}/${RELEASE_VERSION}/${a}-${RELEASE_VERSION}.pom"
      local code
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$pom_url" || echo 000)
      if [[ "$code" == "200" ]]; then
        ok "  ${ga}:${RELEASE_VERSION} visible on Central"
      else
        next_pending+=("$ga")
      fi
    done
    pending=("${next_pending[@]}")
    if (( ${#pending[@]} == 0 )); then break; fi
    now=$(date +%s)
    if (( now > deadline )); then
      printf '❌ Central propagation timed out after %ds; still missing:\n' "$WAIT_TIMEOUT_SECONDS" >&2
      printf '   - %s\n' "${pending[@]}" >&2
      return 1
    fi
    info "  still waiting on ${#pending[@]} artifact(s); next poll in ${WAIT_INTERVAL_SECONDS}s"
    sleep "$WAIT_INTERVAL_SECONDS"
  done
  ok "all artifacts propagated to Maven Central"
}

# ---------------------------------------------------------------- main

main() {
  step_precheck
  step_write_settings
  step_import_gpg
  step_reroute_ssh
  step_branch_create
  step_apply_overrides
  step_failfast_scan
  step_set_version_and_commit
  step_validate_build
  step_deploy
  step_tag_and_finalize
  step_wait_central

  if [[ "$DRY_RUN" == "true" ]]; then
    ok "DRY-RUN ${RELEASE_VERSION} complete — no push, no upload, main untouched"
  else
    ok "Release ${RELEASE_VERSION} complete"
  fi
}

main "$@"
