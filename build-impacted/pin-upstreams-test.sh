#!/usr/bin/env bash
# Tests of pin-upstreams.py, on small Maven reactors written to a temporary directory.
# Run: bash build-impacted/pin-upstreams-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/pin-upstreams.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

# pom <file> <body>: writes a pom whose <project> element holds <body>.
pom() {
  mkdir -p "$(dirname "$1")"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<project xmlns="http://maven.apache.org/POM/4.0.0">\n%s\n</project>\n' "$2" > "$1"
}

# prop <file> <name>: the text of <name> wherever it appears first.
prop() {
  sed -n "s|.*<$2>\([^<]*\)</$2>.*|\1|p" "$1" | head -1
}

pin() { # pin <dir> [--maven-args <args>] <pins...>
  local dir="$1"; shift
  python3 "$SCRIPT" "$@" "$dir"
}

# --- 1. Root properties: pinned upstreams change, everything else stays byte for byte.
R="$TMP/r1"
pom "$R/pom.xml" '  <modules><module>core</module></modules>
  <properties>
    <vauban.version>0.4.0-SNAPSHOT</vauban.version>
    <chappe.version>0.4.0-SNAPSHOT</chappe.version>
    <junit.version>5.12.0</junit.version>
  </properties>
  <build><plugins><plugin><configuration>
    <filterProperties><vauban.version>${vauban.version}</vauban.version></filterProperties>
  </configuration></plugin></plugins></build>
  <!-- <chappe.version>commented</chappe.version> -->'
pom "$R/core/pom.xml" '  <properties><chappe.version>0.3.0</chappe.version></properties>'
cp "$R/pom.xml" "$TMP/r1-root-before.xml"
out=$(pin "$R" --pin vauban=1.0-PR1.a --pin chappe=2.0-PR1.a --pin foy=3.0-PR1.a)
check "exit status 0 when every pom is understood" "0" "$?"
check "a pinned project property is rewritten" "1.0-PR1.a" "$(sed -n 's|^    <vauban.version>\([^<]*\)<.*|\1|p' "$R/pom.xml")"
check "a second pinned property in the same pom is rewritten" "2.0-PR1.a" "$(sed -n 's|^    <chappe.version>\([^<]*\)<.*|\1|p' "$R/pom.xml")"
check "an unrelated property is left alone" "5.12.0" "$(prop "$R/pom.xml" junit.version)"
check "a plugin configuration element with the same name is left alone" \
  '    <filterProperties><vauban.version>${vauban.version}</vauban.version></filterProperties>' \
  "$(grep filterProperties "$R/pom.xml")"
check "a commented-out property is left alone" \
  '  <!-- <chappe.version>commented</chappe.version> -->' "$(grep 'commented' "$R/pom.xml")"
check "a module of the reactor is rewritten too" "2.0-PR1.a" "$(prop "$R/core/pom.xml" chappe.version)"
check "the log names each pinned property once, sorted" \
  "  set chappe.version=2.0-PR1.a|  set vauban.version=1.0-PR1.a" \
  "$(echo "$out" | grep '^  set ' | paste -sd'|' -)"
diff <(sed -e 's|1.0-PR1.a|0.4.0-SNAPSHOT|; s|<chappe.version>2.0-PR1.a|<chappe.version>0.4.0-SNAPSHOT|' "$R/pom.xml") \
  "$TMP/r1-root-before.xml" >/dev/null
check "nothing else in the root pom changed" "0" "$?"

# --- 2. Modules outside the default reactor are not rewritten, as versions:set-property.
R="$TMP/r2"
pom "$R/pom.xml" '  <modules><module>agg</module><module>other/custom.xml</module></modules>
  <profiles>
    <profile><id>tck</id><modules><module>tck</module></modules></profile>
    <profile><id>ci</id>
      <activation><property><name>env.CI</name></property></activation>
      <modules><module>ci-only</module></modules></profile>
    <profile><id>neg</id>
      <activation><property><name>!skipNeg</name></property></activation>
      <modules><module>neg</module></modules></profile>
    <profile><id>val</id>
      <activation><property><name>flavour</name><value>big</value></property></activation>
      <modules><module>val</module></modules></profile>
  </profiles>'
pom "$R/agg/pom.xml" '  <modules><module>leaf</module></modules>'
for m in agg/leaf tck ci-only neg val; do
  pom "$R/$m/pom.xml" '  <properties><vauban.version>0</vauban.version></properties>'
done
pom "$R/other/custom.xml" '  <properties><vauban.version>0</vauban.version></properties>'
pom "$R/stray/pom.xml" '  <properties><vauban.version>0</vauban.version></properties>'
cp -R "$R" "$TMP/r2-copy"

env -u CI python3 "$SCRIPT" --pin vauban=9 "$R" >/dev/null
check "a module of a nested aggregator is rewritten" "9" "$(prop "$R/agg/leaf/pom.xml" vauban.version)"
check "a module given as a pom file is rewritten" "9" "$(prop "$R/other/custom.xml" vauban.version)"
check "a module of a profile without activation is not rewritten" "0" "$(prop "$R/tck/pom.xml" vauban.version)"
check "a pom that is no module at all is not rewritten" "0" "$(prop "$R/stray/pom.xml" vauban.version)"
check "an env-activated profile is inactive without the variable" "0" "$(prop "$R/ci-only/pom.xml" vauban.version)"
check "a negated property activates when the property is absent" "9" "$(prop "$R/neg/pom.xml" vauban.version)"
check "a property/value activation is inactive without the property" "0" "$(prop "$R/val/pom.xml" vauban.version)"

R="$TMP/r2-copy"
CI=true python3 "$SCRIPT" --pin vauban=9 \
  --maven-args='-B -ntp -Dflavour=big -DskipNeg -P tck' "$R" >/dev/null
check "an env-activated profile is active with the variable" "9" "$(prop "$R/ci-only/pom.xml" vauban.version)"
check "-P from the Maven arguments activates a profile" "9" "$(prop "$R/tck/pom.xml" vauban.version)"
check "-D from the Maven arguments satisfies a property/value activation" "9" "$(prop "$R/val/pom.xml" vauban.version)"
check "-D from the Maven arguments defeats a negated activation" "0" "$(prop "$R/neg/pom.xml" vauban.version)"

# --- 3. activeByDefault: active unless another profile of the same pom is active.
R="$TMP/r3"
pom "$R/pom.xml" '  <profiles>
    <profile><id>def</id><activation><activeByDefault>true</activeByDefault></activation>
      <modules><module>def</module></modules></profile>
    <profile><id>other</id><modules><module>other</module></modules></profile>
  </profiles>'
pom "$R/def/pom.xml" '  <properties><vauban.version>0</vauban.version></properties>'
pom "$R/other/pom.xml" '  <properties><vauban.version>0</vauban.version></properties>'
cp -R "$R" "$TMP/r3-copy"
python3 "$SCRIPT" --pin vauban=9 "$R" >/dev/null
check "an activeByDefault profile is active on its own" "9" "$(prop "$R/def/pom.xml" vauban.version)"
python3 "$SCRIPT" --pin vauban=9 --maven-args=-Pother "$TMP/r3-copy" >/dev/null
check "an activeByDefault profile yields to another active profile" "0" "$(prop "$TMP/r3-copy/def/pom.xml" vauban.version)"
check "the other profile is then active" "9" "$(prop "$TMP/r3-copy/other/pom.xml" vauban.version)"

# --- 4. .mvn/maven.config counts as Maven arguments.
R="$TMP/r4"
pom "$R/pom.xml" '  <profiles><profile><id>tck</id><modules><module>tck</module></modules></profile></profiles>'
pom "$R/tck/pom.xml" '  <properties><vauban.version>0</vauban.version></properties>'
mkdir -p "$R/.mvn" && printf -- '-Daether.connector.http.preemptiveAuth=true\n-Ptck\n' > "$R/.mvn/maven.config"
python3 "$SCRIPT" --pin vauban=9 "$R" >/dev/null
check ".mvn/maven.config activates a profile" "9" "$(prop "$R/tck/pom.xml" vauban.version)"

# --- 5. Whatever the script cannot decide exactly: exit 3, and no file is touched.
undecidable() { # undecidable <name> <root body> [<module body>]
  local R="$TMP/u$((++u))"
  pom "$R/pom.xml" "$2"
  [ -n "${3:-}" ] && pom "$R/m/pom.xml" "$3"
  cp -R "$R" "$R.before"
  python3 "$SCRIPT" --pin vauban=9 "$R" >/dev/null 2>&1
  local rc=$?
  diff -r "$R" "$R.before" >/dev/null && rc="$rc/untouched" || rc="$rc/changed"
  check "$1: exit 3, nothing changed" "3/untouched" "$rc"
}
u=0
undecidable "a profile activated by the JDK" \
  '  <properties><vauban.version>0</vauban.version></properties>
  <profiles><profile><id>j</id><activation><jdk>25</jdk></activation><modules><module>m</module></modules></profile></profiles>' \
  '  <properties><vauban.version>0</vauban.version></properties>'
undecidable "a profile activated by a file" \
  '  <properties><vauban.version>0</vauban.version></properties>
  <profiles><profile><id>f</id><activation><file><exists>x</exists></file></activation><modules><module>m</module></modules></profile></profiles>' \
  '  <properties><vauban.version>0</vauban.version></properties>'
undecidable "a profile activated by a JVM system property" \
  '  <properties><vauban.version>0</vauban.version></properties>
  <profiles><profile><id>s</id><activation><property><name>java.vendor</name></property></activation><modules><module>m</module></modules></profile></profiles>' \
  '  <properties><vauban.version>0</vauban.version></properties>'
undecidable "a pinned property defined in a profile" \
  '  <properties><vauban.version>0</vauban.version></properties>
  <profiles><profile><id>p</id><properties><vauban.version>1</vauban.version></properties></profile></profiles>'
undecidable "a pinned property written as an empty element" \
  '  <properties><vauban.version/></properties>'
undecidable "a pinned property defined twice" \
  '  <properties><vauban.version>0</vauban.version><vauban.version>1</vauban.version></properties>'
undecidable "a module path with a Maven expression" \
  '  <properties><vauban.version>0</vauban.version></properties>
  <modules><module>${dir}</module></modules>'
undecidable "a module that does not exist" \
  '  <properties><vauban.version>0</vauban.version></properties>
  <modules><module>missing</module></modules>'
undecidable "a pom that is not well-formed XML" \
  '  <properties><vauban.version>0</vauban.version></properties><broken>'

R="$TMP/r5"
pom "$R/pom.xml" '  <properties><vauban.version>0</vauban.version></properties>
  <profiles><profile><id>j</id><activation><jdk>25</jdk></activation>
    <properties><release>25</release></properties></profile></profiles>'
python3 "$SCRIPT" --pin vauban=9 "$R" >/dev/null
check "a JDK-activated profile that adds no module does not stop the pass" "9" "$(prop "$R/pom.xml" vauban.version)"

# --- 6. Line endings and encoding are kept byte for byte.
R="$TMP/r6"
mkdir -p "$R"
printf '<?xml version="1.0" encoding="UTF-8"?>\r\n<project>\r\n  <name>Caf\xc3\xa9</name>\r\n  <properties>\r\n    <vauban.version>0</vauban.version>\r\n  </properties>\r\n</project>\r\n' > "$R/pom.xml"
python3 "$SCRIPT" --pin vauban=9 "$R" >/dev/null
check "CRLF line endings and UTF-8 text are kept" \
  "$(printf '<?xml version="1.0" encoding="UTF-8"?>\r\n<project>\r\n  <name>Caf\xc3\xa9</name>\r\n  <properties>\r\n    <vauban.version>9</vauban.version>\r\n  </properties>\r\n</project>\r\n' | od -c)" \
  "$(od -c < "$R/pom.xml")"

# --- 7. Nothing to pin: exit 0, no file rewritten.
R="$TMP/r7"
pom "$R/pom.xml" '  <properties><junit.version>5</junit.version></properties>'
touch -t 200001010000 "$R/pom.xml"
out=$(python3 "$SCRIPT" --pin vauban=9 "$R")
check "no pinned property: exit 0" "0" "$?"
check "no pinned property: the pom is not rewritten" "200001010000" "$(date -r "$R/pom.xml" +%Y%m%d%H%M 2>/dev/null || stat -c %y "$R/pom.xml" | sed 's/[-: ]//g' | cut -c1-12)"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
