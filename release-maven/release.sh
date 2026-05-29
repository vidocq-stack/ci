#!/usr/bin/env bash
# release.sh — drive a Maven Central release end-to-end inside Forgejo Actions.
#
# Required env (passed by action.yml):
#   RELEASE_VERSION, NEXT_DEV_VERSION
#   OVERRIDES                      multiline "groupId:artifactId=version"
#   CENTRAL_USERNAME, CENTRAL_PASSWORD
#   GPG_PRIVATE_KEY, GPG_PASSPHRASE, GPG_KEY_ID
#   BOT_NAME, BOT_EMAIL
#   RELEASE_PROFILE                (default: release)
#   WAIT_TIMEOUT_SECONDS, WAIT_INTERVAL_SECONDS
#   DRY_RUN                        "true" → no commit/tag/push/upload (smoke test)
#   AUTO_PUBLISH                   "true" → bundle published auto on Central; "false" → manual click required
#
# Flow:
#   1. pre-checks (clean tree, branch=main, env present, version format)
#   2. write ~/.m2/settings.xml (central + central-snapshots)
#   3. import GPG key (base64 or armored)
#   4. apply overrides (lock io.vidocq.* SNAPSHOTs in <parent> + <dependency>)
#   5. fail-fast if any io.vidocq.* SNAPSHOT remains
#   6. If DRY_RUN:
#         a. `mvn -P release verify` (compile + tests + sign + bundle, NO upload)
#         b. show bundle contents
#         c. STOP — never touch git, never upload
#      Else:
#         a. git commit "release: lock io.vidocq.* deps for X" (if anything changed)
#         b. mvn release:prepare + release:perform — signs, uploads bundle
#            (autoPublish=$AUTO_PUBLISH via -Dcentral.publishing.autoPublish)
#         c. If AUTO_PUBLISH: poll repo1.maven.org until each module's .pom is visible
#            else: print the central.sonatype.com URL to click manually

set -euo pipefail

# ---------------------------------------------------------------- helpers

die()  { printf '❌ %s\n' "$*" >&2; exit 1; }
info() { printf '▸  %s\n' "$*"; }
ok()   { printf '✅ %s\n' "$*"; }

require_env() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "env $v is required but empty"
  done
}

# ---------------------------------------------------------------- 1. pre-checks

step_precheck() {
  info "Pre-checks"
  require_env RELEASE_VERSION NEXT_DEV_VERSION \
              CENTRAL_USERNAME CENTRAL_PASSWORD \
              GPG_PRIVATE_KEY GPG_PASSPHRASE GPG_KEY_ID

  # Default the two new toggles if unset (e.g. when sourced standalone).
  : "${DRY_RUN:=false}"
  : "${AUTO_PUBLISH:=false}"

  [[ "$RELEASE_VERSION" != *-SNAPSHOT ]] \
    || die "RELEASE_VERSION must not end with -SNAPSHOT, got '$RELEASE_VERSION'"
  [[ "$NEXT_DEV_VERSION" == *-SNAPSHOT ]] \
    || die "NEXT_DEV_VERSION must end with -SNAPSHOT, got '$NEXT_DEV_VERSION'"

  local branch dirty
  branch=$(git symbolic-ref --short HEAD)
  [[ "$branch" == "main" ]] || die "branch is '$branch'; release must run on main"
  dirty=$(git status --porcelain | wc -l | tr -d ' ')
  if [[ "$dirty" != "0" ]]; then
    echo "❌ working tree is dirty ($dirty files):" >&2
    git status --porcelain >&2
    echo "" >&2
    echo "Hint: these files were modified or created between actions/checkout and this step." >&2
    echo "      Typically setup-java/setup-maven caches or .ci-action/ leak in. Add them" >&2
    echo "      to .gitignore in the repo and retry." >&2
    exit 1
  fi

  git config user.name  "${BOT_NAME:-Vidocq CI Bot}"
  git config user.email "${BOT_EMAIL:-ci@vidocq.dev}"
  local mode="real release"
  [[ "$DRY_RUN" == "true" ]] && mode="DRY-RUN (no commit/upload)"
  ok "pre-checks passed (branch=$branch, clean, $RELEASE_VERSION → $NEXT_DEV_VERSION, $mode)"
  if [[ "$DRY_RUN" != "true" ]]; then
    if [[ "$AUTO_PUBLISH" == "true" ]]; then
      info "AUTO_PUBLISH=true → bundle will be published automatically after Sonatype validation"
    else
      info "AUTO_PUBLISH=false → bundle will stay in VALIDATED state, waiting for manual click on Portal"
    fi
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

# ---------------------------------------------------------------- 3. GPG

step_import_gpg() {
  info "Importing GPG signing key"
  # Try base64 first (preferred, avoids newline mangling in secrets), fallback to raw armored.
  if echo "$GPG_PRIVATE_KEY" | base64 -d 2>/dev/null | gpg --batch --import 2>/dev/null; then
    ok "GPG key imported (base64-decoded)"
  else
    echo "$GPG_PRIVATE_KEY" | gpg --batch --import
    ok "GPG key imported (ASCII-armored)"
  fi
  gpg --list-secret-keys --with-colons | grep -q '^sec' \
    || die "GPG key import failed — no secret key visible"
  # Trust the key (ultimate) so non-interactive signing does not prompt.
  local fpr
  fpr=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
  echo -e "5\ny\n" | gpg --batch --command-fd 0 --expert --edit-key "$fpr" trust quit 2>/dev/null || true
}

# ---------------------------------------------------------------- 4 & 5. overrides + scan

# Parse OVERRIDES env. Accepted formats (one per line, blanks/# ignored):
#   groupId=version           → applies to every io.vidocq.* dep with that groupId
#   groupId:artifactId=version → narrow override for one coord
# Emits tab-separated "scope\tkey\tversion" where scope is "group" or "coord".
parse_overrides() {
  local line key v
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"       # ltrim
    line="${line%"${line##*[![:space:]]}"}"       # rtrim
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

# Apply all overrides in one Python call: for each (parent|dependency) coord in
# every pom.xml under cwd, if it matches an override AND its version is SNAPSHOT
# (literal or property-resolved), patch the right place:
#   - literal <version>X-SNAPSHOT</version> → patch the <version> element.
#   - <version>${some.prop}</version> with ${some.prop}=X-SNAPSHOT → patch the
#     <properties><some.prop>…</some.prop></properties> element (same POM tree;
#     properties inherited from a higher-level POM are handled when that POM
#     is iterated).
step_apply_overrides() {
  info "Applying overrides"
  if [[ -z "${OVERRIDES// /}" ]]; then
    ok "no overrides given (project has no io.vidocq.* SNAPSHOT deps to lock)"
    return
  fi
  # Feed overrides on stdin to keep the script self-contained.
  parse_overrides | python3 - <<'PY'
import sys, re, xml.etree.ElementTree as ET
from pathlib import Path

# Read overrides from stdin (3-col TSV: scope, key, version).
group_overrides = {}   # groupId      → version
coord_overrides = {}   # (g, a)       → version
for line in sys.stdin:
    parts = line.rstrip('\n').split('\t')
    if len(parts) != 3: continue
    scope, key, v = parts
    if scope == 'group':
        group_overrides[key] = v
    elif scope == 'coord':
        g, a = key.split(':', 1)
        coord_overrides[(g, a)] = v

PROP_RE = re.compile(r'^\$\{([^}]+)\}$')

def match_version(g, a):
    """Return desired release version for a coord, or None if no override matches."""
    if (g, a) in coord_overrides: return coord_overrides[(g, a)]
    if g in group_overrides:      return group_overrides[g]
    return None

total_changes = 0
for pom in Path('.').rglob('pom.xml'):
    if any(part in ('target', 'node_modules') or (part != '.' and part.startswith('.')) for part in pom.parts): continue
    text = pom.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
    if not m: continue
    ns = m.group(1)
    ET.register_namespace('', ns)
    try:
        tree = ET.parse(pom)
    except ET.ParseError as e:
        print(f"  ⚠ skip {pom} (parse error: {e})", file=sys.stderr)
        continue
    root = tree.getroot()

    # Build local property map.
    props_el = root.find(f'{{{ns}}}properties')
    props = {}
    if props_el is not None:
        for child in props_el:
            name = child.tag.split('}', 1)[-1]
            props[name] = (child.text or '').strip()

    changes_in_pom = []  # list of (description) for log
    props_to_patch = {}  # prop_name → new_version

    def visit(elem):
        nonlocal changes_in_pom
        g = elem.findtext(f'{{{ns}}}groupId') or ''
        a = elem.findtext(f'{{{ns}}}artifactId') or ''
        if not g.startswith('io.vidocq'): return
        target = match_version(g, a)
        if target is None: return
        ve = elem.find(f'{{{ns}}}version')
        if ve is None: return
        raw = (ve.text or '').strip()
        m = PROP_RE.match(raw)
        if m:
            prop_name = m.group(1)
            current = props.get(prop_name, '')
            if current.endswith('-SNAPSHOT'):
                props_to_patch[prop_name] = target
                changes_in_pom.append(f"property {prop_name}: {current} → {target} (via {g}:{a})")
        elif raw.endswith('-SNAPSHOT'):
            ve.text = target
            changes_in_pom.append(f"{g}:{a} <version>: {raw} → {target}")

    for parent in root.findall(f'{{{ns}}}parent'):
        visit(parent)
    for dep in root.iter(f'{{{ns}}}dependency'):
        visit(dep)

    # Apply property patches (deferred so we don't mutate while iterating).
    if props_to_patch and props_el is not None:
        for child in props_el:
            name = child.tag.split('}', 1)[-1]
            if name in props_to_patch:
                child.text = props_to_patch[name]

    if changes_in_pom:
        tree.write(pom, encoding='utf-8', xml_declaration=True)
        print(f"  • {pom}")
        for c in changes_in_pom:
            print(f"      ↳ {c}")
        total_changes += len(changes_in_pom)

print(f"  → {total_changes} change(s) across all pom.xml")
PY
  ok "overrides applied"
}

# Scan for remaining io.vidocq.* SNAPSHOTs (resolved through properties), then
# ignore self-references (the project's own artifactIds — release-plugin will
# bump them). Exit 1 with a clear list if anything legitimate remains.
step_failfast_scan() {
  info "Scanning for residual io.vidocq.* SNAPSHOTs"
  python3 <<'PY' || exit 1
import re, sys, xml.etree.ElementTree as ET
from pathlib import Path

PROP_RE = re.compile(r'^\$\{([^}]+)\}$')

# Pass 1: own artifactIds (any artifactId declared by a POM in this repo).
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

# Pass 2: detect external io.vidocq.* SNAPSHOTs (literal or via property).
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
            if a in own_aids: continue       # self-reference
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

# ---------------------------------------------------------------- 6. commit lock

step_commit_lock() {
  info "Committing lock (if any change)"
  if [[ -z "$(git status --porcelain)" ]]; then
    ok "no lock needed (no POM changes)"
    return
  fi
  git add -A
  git commit -m "release: lock io.vidocq.* deps for ${RELEASE_VERSION}"
  git push origin main
  ok "lock commit pushed"
}

# ---------------------------------------------------------------- 7. maven release

# Real release: prepare + perform with autoPublish forwarded into the forked
# release:perform build via -Darguments.
step_maven_release() {
  info "Running maven-release-plugin (prepare + perform)"
  export GPG_TTY=$(tty || echo /dev/null)

  local release_args
  release_args="-P${RELEASE_PROFILE}"
  release_args="${release_args} -Dgpg.passphrase=${GPG_PASSPHRASE}"
  release_args="${release_args} -Dgpg.keyname=${GPG_KEY_ID}"
  release_args="${release_args} -Dcentral.publishing.autoPublish=${AUTO_PUBLISH}"

  mvn -B -ntp \
      -DreleaseVersion="${RELEASE_VERSION}" \
      -DdevelopmentVersion="${NEXT_DEV_VERSION}" \
      -Darguments="${release_args}" \
      release:prepare release:perform

  ok "maven-release-plugin completed (autoPublish=${AUTO_PUBLISH})"
}

# Dry-run: run `mvn -P release verify` to exercise the full build + signing +
# bundle generation pipeline WITHOUT committing, tagging, pushing, or uploading
# anything. The central-publishing-maven-plugin places the bundle under
# target/central-publishing/ — we list it to make the result visible.
step_dryrun_verify() {
  info "DRY-RUN: mvn -P release verify (no commit, no upload)"
  export GPG_TTY=$(tty || echo /dev/null)

  # Bump the project version transiently so the bundle is generated with the
  # release version, then restore before exit. We use versions:set so submodules
  # follow. We do NOT commit any of this.
  mvn -B -ntp versions:set -DnewVersion="${RELEASE_VERSION}" -DgenerateBackupPoms=true

  set +e
  mvn -B -ntp -P "${RELEASE_PROFILE}" verify \
      -Dgpg.passphrase="${GPG_PASSPHRASE}" \
      -Dgpg.keyname="${GPG_KEY_ID}" \
      -Dcentral.publishing.autoPublish=false
  local rc=$?
  set -e

  # Restore POMs (whether verify succeeded or not).
  mvn -B -ntp versions:revert >/dev/null 2>&1 || true

  if [[ "$rc" != "0" ]]; then
    die "DRY-RUN failed during mvn verify (rc=$rc) — POMs restored, nothing pushed"
  fi

  info "Bundle artifacts (target/central-publishing or target/checkout):"
  find . -path '*/target/central-publishing*' -name '*.zip' -print 2>/dev/null | head -20 || true
  find . -path '*/target/*.asc' -print 2>/dev/null | head -10 || true
  ok "DRY-RUN complete — POMs restored, no git or registry side-effects"
}

# ---------------------------------------------------------------- 8. wait Central

# Enumerate (groupId, artifactId) for every module that is actually deployable
# (skip <maven.deploy.skip>true</maven.deploy.skip> + <packaging>pom</packaging>
# for the root if it's not in distributionManagement -- but vidocq-parent IS pom
# and IS deployed, so we keep pom-packaged modules).
list_deployable_coords() {
  python3 <<'PY'
import re, xml.etree.ElementTree as ET
from pathlib import Path

def text(pom):
    return pom.read_text(encoding='utf-8', errors='replace')

def ns(pom):
    m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text(pom))
    return m.group(1) if m else 'http://maven.apache.org/POM/4.0.0'

def skip_deploy(root, ns_):
    # honor <maven.deploy.skip>true</maven.deploy.skip> in <properties>
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
    g = resolve_g(root, n)
    a = root.findtext(f'{{{n}}}artifactId') or ''
    if g and a:
        print(f"{g}:{a}")
PY
}

step_wait_central() {
  if [[ "$AUTO_PUBLISH" != "true" ]]; then
    info "Skipping wait-for-Central (AUTO_PUBLISH=false → bundle awaiting manual Publish on the Portal)"
    info "  → Go to: https://central.sonatype.com/publishing/deployments"
    info "  → Locate the deployment for io.vidocq:* version ${RELEASE_VERSION}, click Publish."
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
  step_apply_overrides
  step_failfast_scan

  if [[ "$DRY_RUN" == "true" ]]; then
    # Dry-run path: never touches git, never uploads. The overrides have been
    # applied in-memory in working tree (they were going to be commit_locked
    # anyway in a real run) — that's fine for the verify because we revert
    # the version with versions:revert right after, but we should NOT push.
    # Reset the override changes to leave the working tree exactly as it was.
    if ! git diff --quiet; then
      info "DRY-RUN: reverting in-tree override changes (they would have been committed in a real run)"
      git checkout -- . 2>/dev/null || true
      git clean -fd 2>/dev/null || true
    fi
    step_dryrun_verify
    ok "DRY-RUN ${RELEASE_VERSION} complete (no commit, no upload, no tag)"
    return 0
  fi

  step_commit_lock
  step_maven_release
  step_wait_central
  ok "Release ${RELEASE_VERSION} complete"
}

main "$@"
