// main-watch: posts a loud Slack alert when a job of a repository's `main` failed.
//
// For every repository of the organisation, the head commit of `main` is read with its commit statuses.
// A post-merge job (a context ending in "(push)": the SonarQube analysis, build-and-deploy...) in failure
// or error makes `main` red. The alert is sent once per commit: the watcher then sets its own status,
// MARKER, on that commit, and skips any commit that already carries it.
//
// Environment:
//   FORGE_URL          forge base URL (default https://codefloe.com)
//   ORG                organisation (default Vidocq)
//   BOT_TOKEN          Codefloe token: read the repositories, write the MARKER status
//   SLACK_WEBHOOK_URL  incoming webhook the alert is posted to
//   SONAR_HOST_URL     optional: SonarQube server, to name the quality-gate conditions that failed
//   SONAR_TOKEN        optional: SonarQube token for the same
//   DRY_RUN            1/true: print the alerts, post nothing, set no status
//   SKIP_REPOS         optional comma-separated repository names to leave out

const FORGE = (process.env.FORGE_URL || 'https://codefloe.com').replace(/\/$/, '');
const ORG = process.env.ORG || 'Vidocq';
const DRY = /^(1|true|yes|on)$/i.test(process.env.DRY_RUN || '');
const MARKER = 'main-watch / alerted';
const SKIP = new Set((process.env.SKIP_REPOS || '').split(',').map(s => s.trim()).filter(Boolean));

const forgeHeaders = { Accept: 'application/json', Authorization: `token ${process.env.BOT_TOKEN}` };

async function forge(path, init = {}) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const res = await fetch(`${FORGE}/api/v1${path}`, { ...init, headers: { ...forgeHeaders, ...(init.headers || {}) } });
    if (res.status === 429) { await new Promise(r => setTimeout(r, 15000)); continue; }
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`${init.method || 'GET'} ${path}: HTTP ${res.status}`);
    return res.status === 204 ? null : res.json();
  }
  throw new Error(`${path}: still rate-limited`);
}

async function repositories() {
  const all = [];
  for (let page = 1; ; page++) {
    const batch = await forge(`/orgs/${ORG}/repos?limit=50&page=${page}`);
    if (!batch || batch.length === 0) return all;
    all.push(...batch.filter(r => !r.archived && !r.empty && !SKIP.has(r.name)));
  }
}

/** The failed post-merge contexts of `sha`, and whether the alert was already sent for it. */
export function redJobs(statuses) {
  const latest = new Map();
  for (const s of statuses) {
    const prev = latest.get(s.context);
    if (!prev || new Date(s.updated_at) > new Date(prev.updated_at)) latest.set(s.context, s);
  }
  const red = [...latest.values()].filter(s => s.context.endsWith('(push)') && ['failure', 'error'].includes(s.status));
  return { red, alerted: latest.has(MARKER) };
}

async function sonarConditions(repo) {
  const host = (process.env.SONAR_HOST_URL || '').replace(/\/$/, '');
  if (!host || !process.env.SONAR_TOKEN) return [];
  try {
    const res = await fetch(`${host}/api/qualitygates/project_status?projectKey=vidocq-${repo}&branch=main`,
      { headers: { Authorization: `Bearer ${process.env.SONAR_TOKEN}` } });
    if (!res.ok) return [];
    const body = await res.json();
    return body.projectStatus.conditions.filter(c => c.status !== 'OK')
      .map(c => `${c.metricKey.replace(/^new_software_quality_/, 'new ').replace(/_/g, ' ')}: ${c.actualValue}`);
  } catch {
    return [];
  }
}

/** The Slack payload: a big header block so the alert stands out in the channel. */
export function alertPayload({ repo, ref, sha, subject, author, red, conditions, sonarUrl }) {
  const jobs = red.map(s => `• <${FORGE}${s.target_url}|${s.context}>`).join('\n');
  const gate = conditions.length ? `\n*Quality gate:* ${conditions.join(' · ')} — <${sonarUrl}|SonarQube>` : '';
  const text = `[ViBot]: 🚨 ALERT — MAIN IS RED — \`${ORG}/${repo}\`@${ref}`;
  return {
    text,
    blocks: [
      { type: 'header', text: { type: 'plain_text', text: '🚨 ALERT — MAIN IS RED 🚨', emoji: true } },
      { type: 'section', text: { type: 'mrkdwn', text:
        `*<${FORGE}/${ORG}/${repo}|${ORG}/${repo}>* @ \`${ref}\` — <${FORGE}/${ORG}/${repo}/commit/${sha}|\`${sha.slice(0, 8)}\`>`
        + `${author ? ` by *${author}*` : ''}\n> ${subject}` } },
      { type: 'section', text: { type: 'mrkdwn', text: `*Failed after the merge:*\n${jobs}${gate}` } },
      { type: 'context', elements: [{ type: 'mrkdwn', text: 'Fix it now: the next pull requests build on a red main. [ViBot]' }] },
    ],
  };
}

async function main() {
  let alerts = 0;
  for (const r of await repositories()) {
    const branch = await forge(`/repos/${ORG}/${r.name}/branches/${r.default_branch || 'main'}`);
    if (!branch) continue;
    const sha = branch.commit.id;
    const combined = await forge(`/repos/${ORG}/${r.name}/commits/${sha}/status`);
    const { red, alerted } = redJobs((combined && combined.statuses) || []);
    if (red.length === 0 || alerted) continue;
    const sonarRed = red.some(s => s.context.startsWith('sonar'));
    const payload = alertPayload({
      repo: r.name, ref: branch.name, sha,
      subject: (branch.commit.message || '').split('\n')[0],
      author: branch.commit.author && (branch.commit.author.username || branch.commit.author.name),
      red,
      conditions: sonarRed ? await sonarConditions(r.name) : [],
      sonarUrl: `${(process.env.SONAR_HOST_URL || '').replace(/\/$/, '')}/dashboard?id=vidocq-${r.name}&branch=main`,
    });
    alerts++;
    if (DRY) {
      console.log(`[dry-run] ${r.name}@${sha.slice(0, 8)}: ${red.map(s => s.context).join(', ')}`);
      console.log(JSON.stringify(payload, null, 2));
      continue;
    }
    const res = await fetch(process.env.SLACK_WEBHOOK_URL, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload),
    });
    if (!res.ok) throw new Error(`Slack webhook: HTTP ${res.status}`);
    await forge(`/repos/${ORG}/${r.name}/statuses/${sha}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ context: MARKER, state: 'success', description: 'Slack alert sent: main is red' }),
    });
    console.log(`alert sent: ${r.name}@${sha.slice(0, 8)} (${red.map(s => s.context).join(', ')})`);
  }
  console.log(`${alerts} red main(s)${DRY ? ' (dry run)' : ''}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  if (!process.env.BOT_TOKEN || (!DRY && !process.env.SLACK_WEBHOOK_URL)) {
    console.error('BOT_TOKEN and SLACK_WEBHOOK_URL are required (SLACK_WEBHOOK_URL not in a dry run)');
    process.exit(1);
  }
  main().catch(e => { console.error(e.message); process.exit(1); });
}
