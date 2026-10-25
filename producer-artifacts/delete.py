#!/usr/bin/env python3
"""Delete a run's shared producer artifacts once the downstream jobs are done.

  delete.py --api API --run RUN_ID --name NAME --token TOKEN

API is <server>/api/v1/repos/<owner>/<repo>. Deletes every artifact of the run named NAME
(DELETE /actions/artifacts/<id>, checked on Forgejo 16 with the job token). Never fails: an API
error is a warning, and the upload's one-day retention removes the artifact anyway.
"""
import argparse
import json
import sys
import urllib.request


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    for opt in ('--api', '--run', '--name', '--token'):
        ap.add_argument(opt, required=True)
    a = ap.parse_args(argv)
    h = {'Authorization': 'token ' + a.token}
    try:
        req = urllib.request.Request(f'{a.api}/actions/runs/{a.run}/artifacts', headers=h)
        with urllib.request.urlopen(req, timeout=60) as r:
            arts = [x for x in json.load(r) if x.get('name') == a.name]
        for x in arts:
            req = urllib.request.Request(f"{a.api}/actions/artifacts/{x['id']}", headers=h, method='DELETE')
            with urllib.request.urlopen(req, timeout=60) as r:
                print(f"deleted artifact {x['id']} ({a.name}): HTTP {r.status}")
        if not arts:
            print(f'no artifact {a.name} in run {a.run}')
    except Exception as e:  # noqa: BLE001 - never fail the verdict job
        print(f'::warning title=Producer artifacts::{a.name} not deleted ({e}); the one-day retention removes it.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
