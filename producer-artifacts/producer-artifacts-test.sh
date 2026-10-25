#!/usr/bin/env bash
# Tests of the shared producer artifacts: pack.sh (producer job: pack the PR-version artifacts of
# the reactor with a manifest), fetch-install.sh (downstream job: download, verify, install, else
# the rebuild), delete.py (aggregator: delete the run's artifact), and rebuild-producer.sh using
# them. Offline: mvn is a stub, the forge API a local HTTP server.
# Run: bash producer-artifacts/producer-artifacts-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
cleanup() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

V=0.4.0-PR7.abc12345
# The producer "knock": effective POM of the producer job (after versions:set) with three modules;
# knock-it skips install by design (maven.install.skip), as the vauban examples and TCK runners do.
cat > "$TMP/eff.xml" <<EOF
<projects>
  <project><groupId>io.vidocq.knock</groupId><artifactId>knock-parent</artifactId><version>$V</version><packaging>pom</packaging></project>
  <project><parent><groupId>io.vidocq.knock</groupId><version>$V</version></parent><artifactId>knock-core</artifactId><version>$V</version></project>
  <project><groupId>io.vidocq.knock</groupId><artifactId>knock-it</artifactId><version>$V</version><properties><maven.install.skip>true</maven.install.skip></properties></project>
</projects>
EOF
# The same reactor as a downstream job's producer checkout describes it, before any versions:set.
sed "s/$V/0.4.0-SNAPSHOT/g" "$TMP/eff.xml" > "$TMP/eff-consumer.xml"
# The producer job's local repository after its install.
PREPO="$TMP/producer-m2"
put() { mkdir -p "$(dirname "$PREPO/$1")"; printf '%s' "${2:-content of $1}" > "$PREPO/$1"; }
put io/vidocq/knock/knock-parent/$V/knock-parent-$V.pom
put io/vidocq/knock/knock-parent/$V/_remote.repositories
put io/vidocq/knock/knock-core/$V/knock-core-$V.pom
put io/vidocq/knock/knock-core/$V/knock-core-$V.jar
put io/vidocq/knock/knock-core/$V/knock-core-$V-sources.jar
put io/vidocq/knock/knock-core/$V/knock-core-$V-javadoc.jar
put io/vidocq/knock/knock-core/$V/knock-core-$V-tests.jar
put io/vidocq/knock/knock-core/$V/knock-core-$V-test-sources.jar
put io/vidocq/knock/knock-it/$V/knock-it-$V.jar
put io/vidocq/knock/knock-core/0.4.0-SNAPSHOT/knock-core-0.4.0-SNAPSHOT.jar
put io/vidocq/knock/knock-core/maven-metadata-local.xml

mkdir -p "$TMP/bin"
cat > "$TMP/bin/mvn" <<EOF
#!/usr/bin/env bash
echo "\$(basename "\$PWD") \$*" >> "$TMP/mvn-calls"
for a in "\$@"; do
  case "\$a" in
    *:effective-pom) for b in "\$@"; do case "\$b" in -Doutput=*) cp "\${STUB_EFF:-$TMP/eff.xml}" "\${b#-Doutput=}" ;; esac; done ;;
    *:evaluate) printf '%s' "\$STUB_REPO"; exit 0 ;;
  esac
done
exit 0
EOF
chmod +x "$TMP/bin/mvn"
mkdir -p "$TMP/producer" && echo '<project><artifactId>knock-parent</artifactId><version>0.4.0-SNAPSHOT</version></project>' > "$TMP/producer/pom.xml"

# --- pack.sh ---------------------------------------------------------------------------------
pack() { rm -rf "$TMP/out"; rm -f "$TMP/mvn-calls"
  (cd "$TMP/producer" && env PATH="$TMP/bin:$PATH" STUB_REPO="$PREPO" PRODUCER_VERSION="$V" MVN_ARGS='-B -ntp' \
     OUT="$TMP/out" "$@" bash "$HERE/pack.sh") > "$TMP/pack.out" 2>&1
  echo $?
}
manifest() { python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$TMP/out/manifest.json" "$1"; }
check "pack: exits 0" "0" "$(pack)"
check "pack: the manifest names the version" "$V" "$(manifest 'm["version"]')"
check "pack: every module of the reactor" "io.vidocq.knock:knock-core io.vidocq.knock:knock-it io.vidocq.knock:knock-parent" "$(manifest '" ".join(sorted(m["modules"]))')"
check "pack: only the PR-version files, test jars included, no sources or javadoc" \
  "io/vidocq/knock/knock-core/$V/knock-core-$V-tests.jar io/vidocq/knock/knock-core/$V/knock-core-$V.jar io/vidocq/knock/knock-core/$V/knock-core-$V.pom io/vidocq/knock/knock-parent/$V/_remote.repositories io/vidocq/knock/knock-parent/$V/knock-parent-$V.pom" \
  "$(manifest '" ".join(sorted(m["files"]))')"
check "pack: a module that skips install is listed apart, its stale files left out" "io.vidocq.knock:knock-it" "$(manifest '" ".join(m["install_skipped"])')"
check "pack: sha256 of each file" "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "content of io/vidocq/knock/knock-core/$V/knock-core-$V.jar")" \
  "$(manifest 'm["files"]["io/vidocq/knock/knock-core/'"$V"'/knock-core-'"$V"'.jar"]')"
check "pack: one archive and the manifest" "artifacts.tar.gz manifest.json" "$(ls "$TMP/out" | sort | paste -sd' ' -)"
check "pack: a release-style version only" "1" "$(pack PRODUCER_VERSION=0.4.0-SNAPSHOT)"
variant() { # variant <file> <python code editing s, the effective POM text>
  python3 -c 'import sys; s = open(sys.argv[1]).read(); exec(sys.argv[3]); open(sys.argv[2], "w").write(s)' "$TMP/eff.xml" "$TMP/$1" "$2"
}
variant eff-noinstall.xml 's = s.replace("</projects>", "<project><groupId>io.vidocq.knock</groupId><artifactId>knock-extra</artifactId><version>'"$V"'</version></project></projects>")'
check "pack: a module that installed nothing without skipping install: nothing packed" "1" "$(pack STUB_EFF="$TMP/eff-noinstall.xml")"
check "pack: ... and the reason" "1" "$(grep -c 'io.vidocq.knock:knock-extra installed nothing' "$TMP/pack.out")"
variant eff-version.xml 's = s.replace("<artifactId>knock-core</artifactId><version>'"$V"'", "<artifactId>knock-core</artifactId><version>0.4.0-SNAPSHOT")'
check "pack: a module that kept another version: nothing packed" "1" "$(pack STUB_EFF="$TMP/eff-version.xml")"
check "pack: ... and the reason" "1" "$(grep -c 'io.vidocq.knock:knock-core is at 0.4.0-SNAPSHOT' "$TMP/pack.out")"
variant eff-plugin-skip.xml 's = s.replace("<artifactId>knock-it</artifactId><version>'"$V"'</version><properties><maven.install.skip>true</maven.install.skip></properties>", "<artifactId>knock-it</artifactId><version>9.9</version><build><plugins><plugin><artifactId>maven-install-plugin</artifactId><executions><execution><id>default-install</id><configuration><skip>true</skip></configuration></execution></executions></plugin></plugins></build>")'
check "pack: install skipped by the plugin configuration, at any version" "0|io.vidocq.knock:knock-it" \
  "$(pack STUB_EFF="$TMP/eff-plugin-skip.xml")|$(manifest '" ".join(m["install_skipped"])')"

# --- the forge API --------------------------------------------------------------------------
cat > "$TMP/server.py" <<'PY'
import http.server, json, os, sys
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(os.path.join(root, 'requests'), 'a') as f: f.write(f"GET {self.path} {self.headers.get('Authorization')}\n")
        p = os.path.join(root, 'files', self.path.strip('/').replace('/', '_'))
        if not os.path.exists(p): self.send_response(404); self.end_headers(); return
        data = open(p, 'rb').read(); self.send_response(200); self.end_headers(); self.wfile.write(data)
    def do_DELETE(self):
        with open(os.path.join(root, 'requests'), 'a') as f: f.write(f"DELETE {self.path}\n")
        self.send_response(204); self.end_headers()
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(os.path.join(root, 'port'), 'w').write(str(s.server_port))
s.serve_forever()
PY
mkdir -p "$TMP/api/files"
python3 "$TMP/server.py" "$TMP/api" & SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/api/port" ] && break; sleep 0.1; done
PORT=$(cat "$TMP/api/port")
API="http://127.0.0.1:$PORT/api/v1/repos/Vidocq/knock"
publish() { # publish the packed out/ as the run's artifact (the upload-artifact zip), with name $1
  pack > /dev/null
  (cd "$TMP/out" && python3 -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], "w"); [z.write(f) for f in sys.argv[2:]]' "$TMP/api/files/zip_9" artifacts.tar.gz manifest.json)
  printf '[{"id":9,"name":"%s","archive_download_url":"http://127.0.0.1:%s/zip/9","expired":false}]' "$1" "$PORT" \
    > "$TMP/api/files/api_v1_repos_Vidocq_knock_actions_runs_77_artifacts"
}

# --- rebuild-producer.sh with shared artifacts ----------------------------------------------
CREPO="$TMP/consumer-m2"
consume() { # consume [VAR=value...] -> exit status
  rm -f "$TMP/mvn-calls" "$TMP/api/requests"; rm -rf "$CREPO" "$TMP/runner"; mkdir -p "$CREPO" "$TMP/runner"
  (env PATH="$TMP/bin:$PATH" STUB_REPO="$CREPO" RUNNER_TEMP="$TMP/runner" PRODUCER_DIR="$TMP/producer" \
     STUB_EFF="$TMP/eff-consumer.xml" PRODUCER_VERSION="$V" PRODUCER_MVN_ARGS='-B -ntp' PRODUCER_ARTIFACTS_NAME=producer-artifacts-77 \
     ARTIFACTS_API="$API" ARTIFACTS_RUN=77 ARTIFACTS_TOKEN=job-token \
     "$@" bash "$HERE/../build-one-consumer/rebuild-producer.sh") > "$TMP/consume.out" 2>&1
  echo $?
}
rebuilt() { grep -c 'versions:set\|install -DskipTests' "$TMP/mvn-calls" 2>/dev/null || true; }

publish producer-artifacts-77
check "shared: exits 0" "0" "$(consume)"
check "shared: no rebuild" "0" "$(rebuilt)"
check "shared: the artifacts are in the local repository, byte for byte" "" \
  "$(diff "$PREPO/io/vidocq/knock/knock-core/$V/knock-core-$V.jar" "$CREPO/io/vidocq/knock/knock-core/$V/knock-core-$V.jar")"
check "shared: the tests jar reached it, as the rebuild installs it" "" \
  "$(diff "$PREPO/io/vidocq/knock/knock-core/$V/knock-core-$V-tests.jar" "$CREPO/io/vidocq/knock/knock-core/$V/knock-core-$V-tests.jar" 2>&1)"
check "shared: no stale file of a module that skips install" "no" "$([ -e "$CREPO/io/vidocq/knock/knock-it/$V/knock-it-$V.jar" ] && echo yes || echo no)"
check "shared: no sources jar reached it" "no" "$([ -e "$CREPO/io/vidocq/knock/knock-core/$V/knock-core-$V-sources.jar" ] && echo yes || echo no)"
check "shared: a notice says so" "1" "$(grep -c '^::notice title=Producer artifacts::' "$TMP/consume.out")"
check "shared: the download uses the job token" "1" "$(grep -c 'GET /api/v1/repos/Vidocq/knock/actions/runs/77/artifacts token job-token' "$TMP/api/requests")"
check "shared + targeted: the producer artifact list comes from the manifest" \
  "io.vidocq.knock:knock-core|io.vidocq.knock:knock-it|io.vidocq.knock:knock-parent" \
  "$(consume TESTS=targeted > /dev/null; sort "$TMP/runner/targeted/producer-artifacts.txt" | paste -sd'|' -)"

fallback() { # fallback <name> <reason fragment> [VAR=value...]
  local name="$1" frag="$2"; shift 2
  check "fallback $name: exits 0" "0" "$(consume "$@")"
  check "fallback $name: the producer is rebuilt" "2" "$(rebuilt)"
  check "fallback $name: a notice with the reason" "1" "$(grep -c "^::notice title=Producer artifacts::.*$frag" "$TMP/consume.out")"
}
publish producer-artifacts-77
fallback "artifact not found" "not found" PRODUCER_ARTIFACTS_NAME=producer-artifacts-other
fallback "API unreachable" "download" ARTIFACTS_API="http://127.0.0.1:1/api"
fallback "version mismatch" "version" PRODUCER_VERSION=0.4.0-PR8.def
STUB_EFF_OTHER="$TMP/eff-other.xml"
sed 's/knock-it/knock-new/' "$TMP/eff-consumer.xml" > "$STUB_EFF_OTHER"
fallback "module list mismatch" "modules" STUB_EFF="$STUB_EFF_OTHER"
# Several artifacts with the run's name: which one is the producer's is unknown.
publish producer-artifacts-77
printf '[{"id":9,"name":"producer-artifacts-77","archive_download_url":"http://127.0.0.1:%s/zip/9","expired":false},{"id":10,"name":"producer-artifacts-77","archive_download_url":"http://127.0.0.1:%s/zip/9","expired":false}]' "$PORT" "$PORT" \
  > "$TMP/api/files/api_v1_repos_Vidocq_knock_actions_runs_77_artifacts"
fallback "several artifacts with the name" "several artifacts"
# The downstream checkout says knock-it installs, the manifest says it skipped install.
publish producer-artifacts-77
sed 's|<properties><maven.install.skip>true</maven.install.skip></properties>||' "$TMP/eff-consumer.xml" > "$TMP/eff-consumer-noskip.xml"
fallback "install skip differs" "skip install" STUB_EFF="$TMP/eff-consumer-noskip.xml"
cat > "$TMP/tamper.py" <<'PY'
import hashlib, io, json, sys, tarfile, zipfile
z = zipfile.ZipFile(sys.argv[1]); man = json.loads(z.read('manifest.json'))
src = tarfile.open(fileobj=io.BytesIO(z.read('artifacts.tar.gz')))
files = {m.name: src.extractfile(m).read() for m in src.getmembers()}
def add(name, data): files[name] = data; man['files'][name] = hashlib.sha256(data).hexdigest()
def drop(name): files.pop(name, None); man['files'].pop(name, None)
exec(sys.argv[2])
out = io.BytesIO(); dst = tarfile.open(fileobj=out, mode='w:gz')
for name, data in files.items():
    ti = tarfile.TarInfo(name); ti.size = len(data); dst.addfile(ti, io.BytesIO(data))
dst.close()
w = zipfile.ZipFile(sys.argv[1], 'w'); w.writestr('manifest.json', json.dumps(man)); w.writestr('artifacts.tar.gz', out.getvalue())
PY
tamper() { publish producer-artifacts-77; python3 "$TMP/tamper.py" "$TMP/api/files/zip_9" "$1"; }
# A module of the manifest that installed nothing although it does not skip install.
tamper '[drop(n) for n in list(files) if "/knock-core/" in n]'
fallback "a module installed nothing" "installed nothing"
# Manifest paths outside the listed modules' PR-version directories, their sha256 consistent.
tamper 'add("io/vidocq/knock/knock-core/0.4.0-SNAPSHOT/knock-core-0.4.0-SNAPSHOT.jar", b"x")'
fallback "a path at another version" "outside the modules"
check "fallback a path at another version: nothing extracted" "no" "$([ -e "$CREPO/io/vidocq/knock/knock-core/$V/knock-core-$V.jar" ] && echo yes || echo no)"
tamper 'add("org/apache/commons/commons-lang3/'"$V"'/commons-lang3-'"$V"'.jar", b"x")'
fallback "a path of a foreign artifact" "outside the modules"
tamper 'add("io/vidocq/knock/knock-it/'"$V"'/knock-it-'"$V"'.jar", b"x")'
fallback "a path of a module that skips install" "outside the modules"
tamper 'add("io/vidocq/knock/knock-core/'"$V"'/sub/x.jar", b"x")'
fallback "a path below a module directory" "outside the modules"
# A file whose bytes do not match the manifest.
publish producer-artifacts-77
python3 - "$TMP/api/files/zip_9" <<'PY'
import io, json, sys, tarfile, zipfile
z = zipfile.ZipFile(sys.argv[1]); man = z.read('manifest.json'); tar = z.read('artifacts.tar.gz')
src = tarfile.open(fileobj=io.BytesIO(tar)); out = io.BytesIO(); dst = tarfile.open(fileobj=out, mode='w:gz')
for m in src.getmembers():
    data = src.extractfile(m).read() if m.isfile() else None
    if m.name.endswith('.jar'): data = b'tampered'; m.size = len(data)
    dst.addfile(m, io.BytesIO(data) if data is not None else None)
dst.close()
w = zipfile.ZipFile(sys.argv[1], 'w'); w.writestr('manifest.json', man); w.writestr('artifacts.tar.gz', out.getvalue())
PY
fallback "checksum mismatch" "checksum"
check "fallback checksum mismatch: nothing extracted" "no" "$([ -e "$CREPO/io/vidocq/knock/knock-core/$V/knock-core-$V.jar" ] && echo yes || echo no)"
# An archive member outside the manifest's paths (path traversal).
publish producer-artifacts-77
python3 - "$TMP/api/files/zip_9" <<'PY'
import io, sys, tarfile, zipfile
z = zipfile.ZipFile(sys.argv[1]); man = z.read('manifest.json'); tar = z.read('artifacts.tar.gz')
src = tarfile.open(fileobj=io.BytesIO(tar)); out = io.BytesIO(); dst = tarfile.open(fileobj=out, mode='w:gz')
for m in src.getmembers():
    dst.addfile(m, src.extractfile(m) if m.isfile() else None)
evil = tarfile.TarInfo('../../evil.sh'); data = b'x'; evil.size = 1; dst.addfile(evil, io.BytesIO(data)); dst.close()
w = zipfile.ZipFile(sys.argv[1], 'w'); w.writestr('manifest.json', man); w.writestr('artifacts.tar.gz', out.getvalue())
PY
fallback "member outside the manifest" "outside"
check "no name: today's rebuild, no download" "0|2|0" \
  "$(consume PRODUCER_ARTIFACTS_NAME=)|$(rebuilt)|$(cat "$TMP/api/requests" 2>/dev/null | wc -l | tr -d ' ')"

# --- delete.py --------------------------------------------------------------------------------
publish producer-artifacts-77
rm -f "$TMP/api/requests"
python3 "$HERE/delete.py" --api "$API" --run 77 --name producer-artifacts-77 --token job-token > "$TMP/delete.out" 2>&1
check "delete: exits 0" "0" "$?"
check "delete: the run's artifact" "1" "$(grep -c '^DELETE /api/v1/repos/Vidocq/knock/actions/artifacts/9$' "$TMP/api/requests")"
python3 "$HERE/delete.py" --api "http://127.0.0.1:1/api" --run 77 --name producer-artifacts-77 --token t > "$TMP/delete.out" 2>&1
check "delete: an API failure is a warning, never a failure" "0|1" "$?|$(grep -c '^::warning' "$TMP/delete.out")"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
