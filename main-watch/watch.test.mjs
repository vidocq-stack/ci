// node --test main-watch/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { redJobs, alertPayload } from './watch.mjs';

const status = (context, s, at = '2026-10-29T08:00:00Z') => ({ context, status: s, updated_at: at, target_url: '/Vidocq/x/actions/runs/1/jobs/0' });

test('a failed post-merge job makes main red', () => {
  const { red, alerted } = redJobs([status('sonar / sonar (push)', 'failure'), status('CI / build-and-deploy (push)', 'success')]);
  assert.deepEqual(red.map(s => s.context), ['sonar / sonar (push)']);
  assert.equal(alerted, false);
});

test('pull-request checks and pending jobs do not make main red', () => {
  const { red } = redJobs([
    status('sonar / sonar (pull_request)', 'failure'),
    status('CI / build-and-deploy (push)', 'pending'),
  ]);
  assert.deepEqual(red, []);
});

test('only the latest status of a context counts', () => {
  const { red } = redJobs([
    status('sonar / sonar (push)', 'failure', '2026-10-29T08:00:00Z'),
    status('sonar / sonar (push)', 'success', '2026-10-29T08:10:00Z'),
  ]);
  assert.deepEqual(red, []);
});

test('a commit that already carries the marker is not alerted again', () => {
  const { red, alerted } = redJobs([status('sonar / sonar (push)', 'error'), status('main-watch / alerted', 'success')]);
  assert.equal(red.length, 1);
  assert.equal(alerted, true);
});

test('the alert carries the big header, the repository, the failed job and the gate conditions', () => {
  const payload = alertPayload({
    repo: 'vauban', ref: 'main', sha: 'd478fc42aaaa', subject: 'docs(bench): record', author: 'yblazart',
    red: [status('sonar / sonar (push)', 'failure')],
    conditions: ['new low issues: 2'], sonarUrl: 'https://sonar.example/dashboard?id=vidocq-vauban&branch=main',
  });
  assert.equal(payload.blocks[0].type, 'header');
  assert.equal(payload.blocks[0].text.text, '🚨 ALERT — MAIN IS RED 🚨');
  assert.match(payload.text, /MAIN IS RED — `Vidocq\/vauban`@main/);
  assert.match(payload.blocks[1].text.text, /`d478fc42`> by \*yblazart\*/);
  assert.match(payload.blocks[2].text.text, /sonar \/ sonar \(push\)/);
  assert.match(payload.blocks[2].text.text, /new low issues: 2/);
});
