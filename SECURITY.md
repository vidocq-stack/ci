# Security policy

This policy applies to **Vidocq CI** (`Vidocq/ci`) and to the artifacts it publishes. The
process below is the same in every repository of the Vidocq ecosystem.

## Supported versions

This repository publishes no versioned release: it is consumed from `main`.

| Version | Supported |
|---|---|
| `main` | Yes: this repository is not versioned in release lines; it is used and deployed from `main`, where fixes land |
| Anything else (forks, old commits) | No |

## Reporting a vulnerability

**Do not open a public issue, pull request or discussion for a vulnerability.**

Report it privately by email to **[contribute@vidocq.io](mailto:contribute@vidocq.io)**, the
maintainers' mailbox, with the subject `SECURITY: ci - <short title>`. Include:

- the affected repository, version and, if known, the commit;
- a description of the vulnerability and its impact;
- the steps or a minimal proof of concept to reproduce it;
- how you would like to be credited, or that you prefer to stay anonymous.

Encrypt the message if you wish: ask for a public key in a first, empty message. Never send a
secret, a token or personal data you do not need to demonstrate the issue.

A vulnerability in a dependency of the build (not shipped in the artifacts) or in the CI
infrastructure is also welcome at this address.

## Response times

Vidocq is an open source project run by its maintainers on a best-effort basis. These are targets, not commitments or a service level; we tell you when one cannot be met.

| Step | Target |
|---|---|
| Acknowledgement of your report | 3 working days |
| Triage: confirmed or not, severity, affected versions | 10 working days |
| Fix for a critical or high severity issue | 30 days after triage |
| Fix for a medium or low severity issue | Next regular release |
| Public advisory | At the release of the fix, or at the latest 90 days after your report |

## Vulnerability process

1. **Receipt.** A maintainer acknowledges the report and opens a private working note. The
   report stays confidential until the advisory.
2. **Triage.** The maintainers reproduce the issue, decide whether it is a vulnerability, rate
   its severity (CVSS v4.0 base score: critical 9.0-10.0, high 7.0-8.9, medium 4.0-6.9, low
   0.1-3.9) and list the affected versions. The reporter is told the outcome, including a
   refusal with its reason.
3. **Fix.** The fix is prepared in private, with a regression test written first (red, then
   green), on a branch that is not published before the release. If another Vidocq repository
   is affected or has to follow, the maintainers coordinate the companion branches (see
   `docs/changes-across-repositories.md` in the workspace) so that the fixed releases go out
   together.
4. **Advisory and CVE request.** The maintainers write the advisory: description, impact,
   affected and fixed versions, workaround, credit. When the issue deserves one, they request a
   CVE identifier and fill the advisory with it.
5. **Release.** The fixed versions are built and published through the normal release
   pipeline (signed commits and tags). The fix, the advisory and the release notes are
   published together.
6. **Disclosure and credit.** The advisory is published at the release; the reporter is
   credited unless they asked otherwise. If the reporter and the maintainers disagree on the
   date, the 90-day limit above prevails, except for an issue under active exploitation, which
   is disclosed as soon as a fix or a workaround exists.

## Scope

In scope: the code and the artifacts published by the repository. Out of scope: vulnerabilities
of the application built with the artifacts, of third-party software, and findings without
security impact (a missing hardening header on a documentation site, for instance).

For the threat model of the Vidocq runtime, see `THREAT-MODEL.md` in
[`Vidocq/vidocq`](https://codefloe.com/Vidocq/vidocq).
