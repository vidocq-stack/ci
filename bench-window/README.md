# bench-window

Opens and closes the benchmark window of macuntu (workspace ADR 0001, *Performance testing of the
ecosystem*) through the Portainer API of the host: no systemd timer and no shell on the host, so the
whole window is versioned here and visible in the CI.

| Command | Effect |
|---|---|
| `bench-window.py open` | Stops each CI runner, letting its running jobs finish (up to `BENCH_GRACE`), then its `-dind` container; records the CPU governor and turbo, then sets governor `performance` and turbo off; starts the bench runner |
| `bench-window.py close` | Stops the bench runner, letting its job finish; puts the governor and turbo back; starts each `-dind` container, then its runner. Safe when the window is already closed |
| `bench-window.py status` | Prints the state of the runner containers |
| `--dry-run` | Prints the calls that would change something instead of making them |

The governor and turbo live in the host's `/sys`: a short-lived privileged `alpine` container writes
them, created through the Docker API that Portainer exposes.

Python 3 standard library only. Tests: `bash bench-window/bench-window-test.sh`, against a local stub of
the Portainer API.

## Settings

| Variable | Default | Purpose |
|---|---|---|
| `PORTAINER_URL` | (required) | Portainer instance of the host; organisation variable `PORTAINER_MACUNTU_URL` |
| `PORTAINER_TOKEN` | (required) | Access token of a Portainer user allowed to stop, start and create containers; organisation secret `PORTAINER_MACUNTU_TOKEN` |
| `PORTAINER_ENDPOINT` | the only environment | Portainer environment id |
| `BENCH_RUNNERS` | `CodefloeRunnerMontreuil01,CodefloeRunnerMontreuil02` | CI runners to stop; each has a `<name>-dind` companion |
| `BENCH_RUNNER` | none | The bench runner (`BenchMontreuil01`, label `vidocq-bench`), running only inside the window |
| `BENCH_GRACE` | `3600` | Seconds a runner gets to finish its jobs once asked to stop |
| `BENCH_STATE` | `bench-window.json` | Where `open` keeps the settings it found, for `close`; without it, `close` puts back governor `powersave` and turbo on, the usual state of macuntu |

The token can create privileged containers: it is root on the host. It only goes to workflows of `main`;
pull requests from forks get no secrets.

## Prerequisite: runners that finish their jobs

A Forgejo runner waits for its running jobs on `SIGTERM` only when its `config.yaml` sets
`runner.shutdown_timeout`; without it, stopping the container cancels them. Each runner of macuntu needs:

```yaml
runner:
  shutdown_timeout: 1h   # no longer than BENCH_GRACE
```

## In a workflow

Two scheduled jobs open and close the window. They run on the Foix runner (a label of its own,
`vidocq-foix`): on a runner of macuntu, `open` would wait for its own job. The bench workflows run on
`vidocq-bench`, so a bench job dispatched during the day waits for the next window, and only this
workflow holds the token:

```yaml
on:
  schedule:
    - cron: '30 0 * * *'   # open
    - cron: '45 2 * * *'   # close; Saturday: a later close for the long runs
jobs:
  window:
    runs-on: vidocq-foix
    env:
      PORTAINER_URL: ${{ vars.PORTAINER_MACUNTU_URL }}
      PORTAINER_TOKEN: ${{ secrets.PORTAINER_MACUNTU_TOKEN }}
      BENCH_RUNNER: BenchMontreuil01
    steps:
      - uses: actions/checkout@v4
      - run: python3 bench-window/bench-window.py ${{ github.event.schedule == '30 0 * * *' && 'open' || 'close' }}
```

The open and close jobs do not share a file system, so `close` puts back the usual state of macuntu
(governor `powersave`, turbo on); `open` still prints the settings it found, in its log.
