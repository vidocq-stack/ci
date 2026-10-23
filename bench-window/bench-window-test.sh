#!/usr/bin/env bash
# Tests of bench-window.py, against a local stub of the Portainer API (no network).
# Run: bash bench-window/bench-window-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/bench-window.py"
TMP="$(mktemp -d)"

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

# The stub logs "METHOD path [body]" for every call, and answers like Portainer's Docker proxy. The
# CPU settings container prints the governor and turbo it finds in its command, or powersave and 0.
cat > "$TMP/stub.py" <<'EOF'
import http.server, json, re, sys
log = open(sys.argv[1], "a")
class Stub(http.server.BaseHTTPRequestHandler):
    last_cmd = ""
    def reply(self, code, body=b""):
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        log.write("GET %s\n" % self.path); log.flush()
        if self.path == "/api/endpoints":
            return self.reply(200, b'[{"Id": 3}]')
        if self.path.endswith("/json"):
            return self.reply(200, b'{"State": {"Status": "running"}}')
        if "/logs" in self.path:
            cmd = Stub.last_cmd
            governor = re.search(r"do echo (\w+) >", cmd)
            turbo = re.search(r"echo (\d) > \$T", cmd)
            return self.reply(200, ("governor=%s\r\nno_turbo=%s\r\n" % (
                governor.group(1) if governor else "powersave", turbo.group(1) if turbo else "0")).encode())
        self.reply(404)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        log.write("POST %s\n" % self.path); log.flush()
        if self.path.endswith("/containers/create"):
            Stub.last_cmd = json.loads(body)["Cmd"][2]
            privileged = json.loads(body)["HostConfig"]["Privileged"]
            log.write("CMD privileged=%s %s\n" % (privileged, Stub.last_cmd)); log.flush()
            return self.reply(201, b'{"Id": "cpu1"}')
        if self.path.endswith("/wait"):
            return self.reply(200, b'{"StatusCode": 0}')
        if "/images/create" in self.path:
            return self.reply(200, b'{"status": "done"}')
        if "/CodefloeRunnerMontreuil02/start" in self.path:
            return self.reply(304)
        self.reply(204)
    def do_DELETE(self):
        log.write("DELETE %s\n" % self.path); log.flush()
        self.reply(204)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Stub)
print(server.server_address[1], flush=True)
server.serve_forever()
EOF
python3 "$TMP/stub.py" "$TMP/calls.log" > "$TMP/port" &
STUB=$!
trap 'kill $STUB 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port" ] && break; sleep 0.2; done

window() {
  : > "$TMP/calls.log"
  (cd "$TMP" && PORTAINER_URL="http://127.0.0.1:$(cat "$TMP/port")" PORTAINER_TOKEN=t \
    python3 "$SCRIPT" "$@")
}
calls() { grep -E "^(POST|DELETE) .*containers/Codefloe" "$TMP/calls.log" | sed -E 's#/api/endpoints/3/docker/containers/##'; }

out=$(window open)
check "open stops each runner with its grace, then its Docker-in-Docker container" \
  "POST CodefloeRunnerMontreuil01/stop?t=3600|POST CodefloeRunnerMontreuil01-dind/stop?t=60|POST CodefloeRunnerMontreuil02/stop?t=3600|POST CodefloeRunnerMontreuil02-dind/stop?t=60" \
  "$(calls | paste -sd'|' -)"
check "open records the CPU settings it found" \
  '{"governor": "powersave", "no_turbo": "0"}' "$(cat "$TMP/bench-window.json")"
check "open sets governor performance and turbo off, from a privileged container" \
  "1" "$(grep -c '^CMD privileged=True .*do echo performance > \$g; done; echo 1 > \$T' "$TMP/calls.log")"
check "open reports the settings of the window" \
  "CPU settings for the window: governor performance, no_turbo 1" "$(echo "$out" | tail -1)"
check "open removes the CPU settings containers" "2" "$(grep -c '^DELETE .*containers/cpu1?force=1' "$TMP/calls.log")"

echo '{"governor": "schedutil", "no_turbo": "0"}' > "$TMP/bench-window.json"
window open > /dev/null
check "a second open keeps the settings recorded by the first" \
  '{"governor": "schedutil", "no_turbo": "0"}' "$(cat "$TMP/bench-window.json")"

out=$(window close)
check "close restores the recorded CPU settings" \
  "CPU settings restored: governor schedutil, no_turbo 0" "$(echo "$out" | grep restored)"
check "close starts each Docker-in-Docker container, then its runner (a 304 is fine)" \
  "POST CodefloeRunnerMontreuil01-dind/start|POST CodefloeRunnerMontreuil01/start|POST CodefloeRunnerMontreuil02-dind/start|POST CodefloeRunnerMontreuil02/start" \
  "$(calls | paste -sd'|' -)"

rm -f "$TMP/bench-window.json"
out=$(window close)
check "close without recorded settings puts back governor powersave and turbo on" \
  "CPU settings restored: governor powersave, no_turbo 0" "$(echo "$out" | grep restored)"

out=$(BENCH_RUNNERS=OnlyRunner window open --dry-run)
check "a dry run changes nothing" "0" "$(grep -c -E '^(POST|DELETE)' "$TMP/calls.log")"
check "a dry run prints the stop of the runner" \
  "dry-run: POST /api/endpoints/3/docker/containers/OnlyRunner/stop?t=3600" "$(echo "$out" | head -2 | tail -1)"

out=$(window status)
check "status lists each runner and its Docker-in-Docker container" \
  "CodefloeRunnerMontreuil01	running|CodefloeRunnerMontreuil01-dind	running|CodefloeRunnerMontreuil02	running|CodefloeRunnerMontreuil02-dind	running" \
  "$(echo "$out" | paste -sd'|' -)"

bench_calls() { grep -E "^(POST|DELETE) " "$TMP/calls.log" | grep -E "Bench01|containers/create" | sed -E 's#/api/endpoints/3/docker/containers/##'; }
rm -f "$TMP/bench-window.json"
BENCH_RUNNER=Bench01 window open > /dev/null
check "open starts the bench runner once the CPU is set" \
  "POST create|POST create|POST Bench01/start" "$(bench_calls | paste -sd'|' -)"
BENCH_RUNNER=Bench01 window close > /dev/null
check "close stops the bench runner, with its grace, before the CPU is restored" \
  "POST Bench01/stop?t=3600|POST create" "$(bench_calls | paste -sd'|' -)"

echo
if [ "$failures" -eq 0 ]; then echo "all tests passed"; else echo "$failures test(s) failed"; exit 1; fi
