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

# Maven Resolver default connectTimeout is 10s and requestTimeout 30 min. On
# the Forgejo runner (Foix), 10s is too short for the first cold downloads —
# we see `HTTP connect timed out` on Maven Central even though the deps exist.
# Bump both connect and request via Aether system properties on every mvn call.
MVN_NET_FLAGS="-Daether.connector.connectTimeout=60000 -Daether.connector.requestTimeout=300000"

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

# Reroute `git push ssh://git@codeberg.org/...` to HTTPS-with-token. The
# release-plugin uses the developerConnection of the POM (ssh://...) and the
# runner has no SSH key for codeberg.org. The insteadOf config is global so
# it applies to the release-plugin's separate `git push` invocations too.
step_reroute_ssh() {
  if [[ -z "${BOT_TOKEN:-}" ]]; then
    info "Skipping SSH→HTTPS reroute (BOT_TOKEN not provided)"
    return 0
  fi
  info "Rerouting ssh://git@codeberg.org/* to https://oauth2:<token>@codeberg.org/*"
  # `insteadOf` is multi-valued; use --add so both ssh:// shapes resolve.
  git config --global --add "url.https://oauth2:${BOT_TOKEN}@codeberg.org/.insteadOf" "ssh://git@codeberg.org/"
  git config --global --add "url.https://oauth2:${BOT_TOKEN}@codeberg.org/.insteadOf" "ssh://codeberg.org/"
  ok "SSH→HTTPS reroute armed"
}

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

# Detection helper: list the property names referenced as ${X} inside any
# <dependency groupId="$1"> ... <version>${X}</version> across the reactor.
# Read-only XML scan (no mutation — versions-maven-plugin handles the writes).
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
    # <dependency>
    for dep in root.iter(f'{{{ns}}}dependency'):
        if (dep.findtext(f'{{{ns}}}groupId') or '') != g: continue
        raw = (dep.findtext(f'{{{ns}}}version') or '').strip()
        mp = PROP_RE.match(raw)
        if mp: seen.add(mp.group(1))
    # <parent> (in case the parent version is also a ${prop})
    parent = root.find(f'{{{ns}}}parent')
    if parent is not None and (parent.findtext(f'{{{ns}}}groupId') or '') == g:
        raw = (parent.findtext(f'{{{ns}}}version') or '').strip()
        mp = PROP_RE.match(raw)
        if mp: seen.add(mp.group(1))
for p in sorted(seen): print(p)
PY
}

# Detection helper: list groupId:artifactId of <dependency> blocks for this
# groupId whose <version> is a LITERAL SNAPSHOT (not a ${prop}). Used to feed
# versions:use-dep-version. Skips <parent> (handled by versions:update-parent
# upstream). Skips own-project artifacts (release-plugin bumps them itself).
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
# Pass 1: collect own artifactIds.
for pom in poms:
    text = pom.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
    if not m: continue
    ns = m.group(1)
    try: root = ET.parse(pom).getroot()
    except ET.ParseError: continue
    aid = root.findtext(f'{{{ns}}}artifactId')
    if aid: own_aids.add(aid)
# Pass 2: list literal-SNAPSHOT dep coords for this groupId.
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
        if PROP_RE.match(raw): continue       # property — handled elsewhere
        if raw.endswith('-SNAPSHOT'):
            seen.add(f"{g}:{a}")
for c in sorted(seen): print(c)
PY
}

# Replace io.vidocq.* SNAPSHOTs by running versions-maven-plugin goals.
# Three mvn invocations cover the bases:
#   - versions:update-parent      → root <parent>
#   - versions:set-property       → <dependency><version>${X}</version>
#   - versions:use-dep-version    → <dependency><version>X-SNAPSHOT</version> literal
# All goals run with -DgenerateBackupPoms=false (we don't want .versionsBackup
# files cluttering the worktree; release-plugin will commit the changed POMs).
step_apply_overrides() {
  info "Applying overrides"
  if [[ -z "${OVERRIDES// /}" ]]; then
    ok "no overrides given (project has no io.vidocq.* SNAPSHOT deps to lock)"
    return
  fi

  # Read parent coords from pom.xml directly. `mvn help:evaluate` is unusable
  # here: under Maven 4, even with -q, the output is interleaved with
  # `[INFO] [stdout]` lines that pollute the captured value.
  local parent_coords parent_g parent_a
  parent_coords=$(python3 - <<'PY'
import re, xml.etree.ElementTree as ET
try:
    text = open('pom.xml', encoding='utf-8').read()
except FileNotFoundError:
    print("")
    raise SystemExit(0)
m = re.search(r'<project\b[^>]*\bxmlns="([^"]+)"', text)
if not m:
    print("")
    raise SystemExit(0)
ns = m.group(1)
try:
    root = ET.fromstring(text)
except ET.ParseError:
    print("")
    raise SystemExit(0)
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
  # If pom.xml has no <parent>, parent_coords is empty → both empty.
  [[ "$parent_coords" == *$'\t'* ]] || { parent_g=""; parent_a=""; }
  info "  root parent: ${parent_g:-<none>}:${parent_a:-<none>}"

  # Iterate one override at a time. parse_overrides emits TSV "scope\tkey\tv".
  local scope key v g a
  while IFS=$'\t' read -r scope key v; do
    [[ -z "${scope:-}" ]] && continue
    if [[ "$scope" == "coord" ]]; then
      g="${key%%:*}"; a="${key#*:}"
    else
      g="$key"; a=""
    fi
    info "Override: ${key} → ${v}"

    # 1) Update <parent> if our root parent matches.
    #    Preferred path: `mvn versions:update-parent` (validates via Maven repos).
    #    Fallback: direct XML edit of pom.xml's <parent><version> — used when
    #    the parent version has been UPLOADED but not yet PUBLISHED on Central
    #    (typical when chaining a release immediately after an upstream one,
    #    before the operator clicks "Publish" or the propagation completes),
    #    OR — more subtly — when mvn finishes BUILD SUCCESS without writing
    #    anything because the requested version is unknown to every configured
    #    repo and `allowSnapshots=false` made it discard the local SNAPSHOT
    #    candidate. The plugin treats "no resolvable upgrade" as a no-op, not
    #    an error, so we have to detect it by re-reading the file.
    if [[ -n "$parent_g" && "$g" == "$parent_g" ]] \
       && { [[ -z "$a" ]] || [[ "$a" == "$parent_a" ]]; }; then
      info "  • <parent> ${parent_g}:${parent_a} → ${v}"
      local up_log=/tmp/release-update-parent.$$.log
      set +e
      mvn -B -ntp ${MVN_NET_FLAGS} versions:update-parent \
          -DparentVersion="$v" -DallowSnapshots=false -DgenerateBackupPoms=false 2>&1 | tee "$up_log"
      local up_rc=${PIPESTATUS[0]}
      set -e
      # Re-read what pom.xml's <parent><version> looks like now. If mvn was a
      # silent no-op the value is still the original SNAPSHOT and we have to
      # patch it ourselves.
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

    # 3) Literal <dependency><version>X-SNAPSHOT</version> (rare for Vidocq —
    #    the convention is property-driven — but we cover it for safety).
    local ga
    while IFS= read -r ga; do
      [[ -z "$ga" ]] && continue
      # If a narrow coord override was given, only patch that specific coord.
      if [[ -n "$a" && "$ga" != "${g}:${a}" ]]; then continue; fi
      info "  • literal <dependency> ${ga} → ${v}"
      mvn -B -ntp ${MVN_NET_FLAGS} versions:use-dep-version \
          -Dincludes="$ga" -DdepVersion="$v" -DforceVersion=true \
          -DgenerateBackupPoms=false
    done < <(detect_literal_coords_for_group "$g")
  done < <(parse_overrides)

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

# ---------------------------------------------------------------- 7. manual release

# Replace maven-release-plugin (3.1.1 is Model-4.0 only — it crashes on Model
# 4.1 implicit-version inheritance with NPE during rewrite-poms-for-release)
# by driving the release lifecycle ourselves:
#
#   1. versions:set to RELEASE_VERSION (processAllModules covers Model 4.1
#      submodules that omit <version>)
#   2. commit "release: $v" + lightweight tag "v$v" — LOCAL ONLY at this point
#   3. mvn -P release clean deploy — central-publishing-maven-plugin signs
#      and uploads the bundle, autoPublish forwarded as the workflow input
#   4. push main + tag (only on deploy success → a failed upload leaves no
#      published tag pointing to an unshippable revision)
#   5. versions:set to NEXT_DEV_VERSION, commit "release: prepare next dev
#      iteration $next", push
#
# If deploy fails, the local commit and tag are rolled back and the worktree
# is reset so the workflow can be retried without manual cleanup.
step_release_manual() {
  info "Manual release (versions:set + tag + deploy + bump-next)"
  export GPG_TTY=$(tty || echo /dev/null)

  local pre_release_sha
  pre_release_sha=$(git rev-parse HEAD)

  # 1. Flip every reactor module to RELEASE_VERSION. -DprocessAllModules=true
  #    is critical under Model 4.1 where submodules omit <version> entirely
  #    — without it versions:set only touches the root pom.
  info "  → versions:set ${RELEASE_VERSION}"
  mvn -B -ntp ${MVN_NET_FLAGS} versions:set \
      -DnewVersion="${RELEASE_VERSION}" \
      -DprocessAllModules=true \
      -DgenerateBackupPoms=false

  # 2. Local commit + tag. Push deferred until the deploy succeeds.
  info "  → git commit + tag v${RELEASE_VERSION}"
  git add -A
  git commit -m "release: ${RELEASE_VERSION}"
  git tag -a "v${RELEASE_VERSION}" -m "Release ${RELEASE_VERSION}"

  # 3. Two-pass build.
  #    Pass 1: `clean install` WITHOUT the release profile. Vanilla reactor
  #    order (topological) → every consumer sees its producer's artifact in
  #    ~/.m2 before it builds. Tests run here.
  #    Pass 2: `deploy -P release -Dmaven.install.skip=true`. Activates
  #    central-publishing-maven-plugin to sign + bundle + upload. v0.10.0
  #    reorders the reactor (so the root pom collects everything for the
  #    aggregated bundle); since every <dependency> already resolves from
  #    the populated ~/.m2, the reorder no longer breaks inter-module
  #    resolution. Tests are skipped — already covered in pass 1.
  info "  → pass 1/2: install each module in <modules> declaration order"
  # Maven 4 RC-5 + Model 4.1 mis-sorts the reactor DAG (consumers scheduled
  # before producers), breaking inter-module compile resolution. Walk every
  # parent's <modules> tree depth-first — that order is already topological
  # by Vidocq convention (the maintainer lists producers before consumers)
  # — and run an isolated `mvn -N` build in each module so ~/.m2 fills up
  # linearly. -N skips re-recursion into <modules> (each call handles a
  # single POM).
  local modules_in_order
  modules_in_order=$(python3 - <<'PY'
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
)
  set +e
  local install_rc=0
  local module_dir rel
  while IFS= read -r module_dir; do
    [[ -z "$module_dir" ]] && continue
    rel="${module_dir#./}"
    [[ "$rel" == "." || -z "$rel" ]] && rel="<root>"
    info "    • install ${rel}"
    ( cd "$module_dir" && mvn -B -ntp ${MVN_NET_FLAGS} -N clean install )
    install_rc=$?
    [[ "$install_rc" != "0" ]] && break
  done <<< "$modules_in_order"
  set -e
  if [[ "$install_rc" != "0" ]]; then
    info "  ↻ install failed — rolling back local commit + tag (nothing was pushed)"
    git tag -d "v${RELEASE_VERSION}" >/dev/null 2>&1 || true
    git reset --hard "${pre_release_sha}" >/dev/null
    die "install failed (rc=${install_rc}) — local commit/tag undone, tree restored to ${pre_release_sha}"
  fi

  info "  → pass 2/2: mvn -P${RELEASE_PROFILE} deploy (sign + central-publishing, autoPublish=${AUTO_PUBLISH})"
  set +e
  mvn -B -ntp ${MVN_NET_FLAGS} -P"${RELEASE_PROFILE}" deploy \
      -DskipTests \
      -Dmaven.install.skip=true \
      -Dgpg.passphrase="${GPG_PASSPHRASE}" \
      -Dgpg.keyname="${GPG_KEY_ID}" \
      -Dcentral.publishing.autoPublish="${AUTO_PUBLISH}"
  local deploy_rc=$?
  set -e
  if [[ "$deploy_rc" != "0" ]]; then
    info "  ↻ deploy failed — rolling back local commit + tag (nothing was pushed)"
    git tag -d "v${RELEASE_VERSION}" >/dev/null 2>&1 || true
    git reset --hard "${pre_release_sha}" >/dev/null
    die "deploy failed (rc=${deploy_rc}) — local commit/tag undone, tree restored to ${pre_release_sha}"
  fi

  # 4. Publish the release commit + tag.
  info "  → git push main + tag v${RELEASE_VERSION}"
  git push origin main
  git push origin "v${RELEASE_VERSION}"

  # 5. Bump to NEXT_DEV_VERSION and push.
  info "  → versions:set ${NEXT_DEV_VERSION}"
  mvn -B -ntp ${MVN_NET_FLAGS} versions:set \
      -DnewVersion="${NEXT_DEV_VERSION}" \
      -DprocessAllModules=true \
      -DgenerateBackupPoms=false
  git add -A
  git commit -m "release: prepare next dev iteration ${NEXT_DEV_VERSION}"
  git push origin main

  ok "manual release completed (released ${RELEASE_VERSION}, next dev ${NEXT_DEV_VERSION})"
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
  mvn -B -ntp ${MVN_NET_FLAGS} versions:set -DnewVersion="${RELEASE_VERSION}" -DgenerateBackupPoms=true

  # `clean verify` (not just `verify`): mvn-plugin descriptors and other
  # generated metadata embedded into JARs read from target/ left over from
  # earlier compiles, which still reference the pre-set version
  # (vauban-maven-plugin failed the first dry-run with
  #  "Plugin's descriptor contains the wrong version: 0.1.0-SNAPSHOT"
  #  for /…/vauban-maven-plugin-0.1.0.jar). A clean before verify is the
  # standard fix and matches what maven-release-plugin's preparationGoals
  # already does for the real release path.
  set +e
  mvn -B -ntp ${MVN_NET_FLAGS} -P "${RELEASE_PROFILE}" clean verify \
      -Dgpg.passphrase="${GPG_PASSPHRASE}" \
      -Dgpg.keyname="${GPG_KEY_ID}" \
      -Dcentral.publishing.autoPublish=false
  local rc=$?
  set -e

  # Restore POMs (whether verify succeeded or not).
  mvn -B -ntp ${MVN_NET_FLAGS} versions:revert >/dev/null 2>&1 || true

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
  step_reroute_ssh
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
  step_release_manual
  step_wait_central
  ok "Release ${RELEASE_VERSION} complete"
}

main "$@"
