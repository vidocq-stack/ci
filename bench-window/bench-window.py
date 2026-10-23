"""Opens and closes the benchmark window of a host through the Portainer API (workspace ADR 0001).

Usage: bench-window.py status|open|close [--dry-run]

  open    stops each CI runner, letting its running jobs finish (up to BENCH_GRACE seconds), then its
          Docker-in-Docker container; records the CPU governor and turbo of the host, then sets governor
          `performance` and turbo off.
  close   puts the governor and turbo back as `open` found them, starts each Docker-in-Docker container,
          then its runner. Safe to run when the window is already closed: it is also the safety net.
  status  prints the state of the runner containers.

  --dry-run prints the calls that would change something instead of making them.

Environment:
  PORTAINER_URL       base URL of the Portainer instance of the host
  PORTAINER_TOKEN     access token (X-API-Key) of a Portainer user allowed to stop, start and create
                      containers on that environment
  PORTAINER_ENDPOINT  Portainer environment id (default: the only environment of the instance)
  BENCH_RUNNERS       CI runner containers, comma-separated; each has a `<name>-dind` companion
                      (default CodefloeRunnerMontreuil01,CodefloeRunnerMontreuil02)
  BENCH_GRACE         seconds a runner gets to finish its jobs once asked to stop (default 3600). The
                      runner waits only if its config.yaml sets runner.shutdown_timeout at least as long.
  BENCH_STATE         file where `open` keeps the CPU settings it found, for `close` (default
                      bench-window.json); without it `close` sets governor `powersave` and turbo on

The CPU settings are written from a short-lived privileged container (alpine), as they live in the host's
/sys: no shell on the host is needed. Python 3 standard library only.
"""
import json
import os
import sys
import urllib.error
import urllib.request

CPU_IMAGE = ("alpine", "3.20")
DEFAULT_RUNNERS = "CodefloeRunnerMontreuil01,CodefloeRunnerMontreuil02"
CPU_FILES = ("G=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; "
             "T=/sys/devices/system/cpu/intel_pstate/no_turbo; ")
READ_CPU = CPU_FILES + 'echo "governor=$(cat $G)"; echo "no_turbo=$(cat $T 2>/dev/null || echo none)"'


class Portainer:
    def __init__(self, url, token, dry_run):
        self.url, self.token, self.dry_run = url.rstrip("/"), token, dry_run
        self.docker = None

    def call(self, method, path, body=None, timeout=60, raw=False):
        if self.dry_run and method != "GET":
            print("dry-run: %s %s%s" % (method, path, "" if body is None else " " + json.dumps(body)))
            return None
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.url + path, data=data, method=method, headers={
            "X-API-Key": self.token, "Content-Type": "application/json", "User-Agent": "vidocq-bench-window"})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = response.read()
        except urllib.error.HTTPError as error:
            if error.code == 304:  # Docker: the container already is in the requested state
                return None
            raise SystemExit("%s %s: HTTP %d %s" % (method, path, error.code, error.read()[:300]))
        if raw:
            return payload.decode("utf-8", "replace")
        return json.loads(payload) if payload.strip() else None

    def use_endpoint(self, endpoint):
        if not endpoint:
            endpoints = self.call("GET", "/api/endpoints")
            if len(endpoints) != 1:
                raise SystemExit("%d Portainer environments: set PORTAINER_ENDPOINT" % len(endpoints))
            endpoint = endpoints[0]["Id"]
        self.docker = "/api/endpoints/%s/docker" % endpoint

    def state(self, container):
        return self.call("GET", "%s/containers/%s/json" % (self.docker, container))["State"]["Status"]

    def stop(self, container, grace):
        print("stopping %s (up to %ds)" % (container, grace), flush=True)
        self.call("POST", "%s/containers/%s/stop?t=%d" % (self.docker, container, grace), timeout=grace + 120)

    def start(self, container):
        print("starting %s" % container, flush=True)
        self.call("POST", "%s/containers/%s/start" % (self.docker, container))

    def run_privileged(self, script):
        """Runs `script` in a throwaway privileged container and returns its output."""
        self.call("POST", "%s/images/create?fromImage=%s&tag=%s" % ((self.docker,) + CPU_IMAGE), timeout=300,
                  raw=True)
        created = self.call("POST", "%s/containers/create" % self.docker, {
            "Image": "%s:%s" % CPU_IMAGE, "Cmd": ["sh", "-c", script], "Tty": True,
            "HostConfig": {"Privileged": True}})
        if created is None:  # dry run
            return ""
        container = created["Id"]
        try:
            self.call("POST", "%s/containers/%s/start" % (self.docker, container))
            status = self.call("POST", "%s/containers/%s/wait" % (self.docker, container), timeout=120)
            output = self.call("GET", "%s/containers/%s/logs?stdout=1&stderr=1" % (self.docker, container),
                               raw=True)
        finally:
            self.call("DELETE", "%s/containers/%s?force=1" % (self.docker, container))
        if status["StatusCode"] != 0:
            raise SystemExit("CPU settings container failed (%d): %s" % (status["StatusCode"], output))
        return output


def parse_cpu(output):
    values = dict(line.strip().split("=", 1) for line in output.splitlines() if "=" in line)
    return {"governor": values.get("governor", "unknown"), "no_turbo": values.get("no_turbo", "none")}


def set_cpu(portainer, governor, no_turbo):
    script = (CPU_FILES + "for g in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; "
              "do echo %s > $g; done; " % governor)
    if no_turbo != "none":
        script += "echo %s > $T; " % no_turbo
    return parse_cpu(portainer.run_privileged(script + READ_CPU))


def main(argv):
    args = [a for a in argv if a != "--dry-run"]
    if len(args) != 1 or args[0] not in ("status", "open", "close"):
        raise SystemExit(__doc__)
    command = args[0]
    portainer = Portainer(os.environ["PORTAINER_URL"], os.environ["PORTAINER_TOKEN"], "--dry-run" in argv)
    portainer.use_endpoint(os.environ.get("PORTAINER_ENDPOINT", ""))
    runners = [r.strip() for r in os.environ.get("BENCH_RUNNERS", DEFAULT_RUNNERS).split(",") if r.strip()]
    grace = int(os.environ.get("BENCH_GRACE", "3600"))
    state_file = os.environ.get("BENCH_STATE", "bench-window.json")

    if command == "status":
        for runner in runners:
            for container in (runner, runner + "-dind"):
                print("%s\t%s" % (container, portainer.state(container)))
    elif command == "open":
        for runner in runners:
            portainer.stop(runner, grace)
            portainer.stop(runner + "-dind", 60)
        found = parse_cpu(portainer.run_privileged(READ_CPU))
        # A second `open` would otherwise record the window's own settings as the ones to restore.
        if not portainer.dry_run and not os.path.exists(state_file):
            with open(state_file, "w", encoding="utf-8") as fh:
                json.dump(found, fh)
        print("CPU settings found: governor %(governor)s, no_turbo %(no_turbo)s" % found)
        now = set_cpu(portainer, "performance", "1" if found["no_turbo"] != "none" else "none")
        print("CPU settings for the window: governor %(governor)s, no_turbo %(no_turbo)s" % now)
    else:
        found = {"governor": "powersave", "no_turbo": "0"}
        if os.path.exists(state_file):
            with open(state_file, encoding="utf-8") as fh:
                found = json.load(fh)
        now = set_cpu(portainer, found["governor"], found["no_turbo"])
        print("CPU settings restored: governor %(governor)s, no_turbo %(no_turbo)s" % now)
        for runner in runners:
            portainer.start(runner + "-dind")
            portainer.start(runner)


if __name__ == "__main__":
    main(sys.argv[1:])
