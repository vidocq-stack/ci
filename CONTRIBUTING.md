# Contributing to Vidocq

Thank you for your interest in contributing!

## Licensing of contributions

This project is released under a **disjunctive triple license**:

```
SPDX-License-Identifier: EPL-2.0 OR EUPL-1.2 OR GPL-2.0-or-later
```

- Eclipse Public License 2.0 (EPL-2.0) — see [`LICENSE`](LICENSE) (anchor licence)
- European Union Public Licence 1.2 (EUPL-1.2) — see [`licenses/EUPL-1.2.txt`](licenses/EUPL-1.2.txt)
- GNU General Public License v2.0 or later — see [`licenses/GPL-2.0.txt`](licenses/GPL-2.0.txt)

By submitting a contribution to this project, **you agree that your
contribution is licensed under this same triple license** and that it may be
redistributed under any of these three licences at the recipient's option.

## Developer Certificate of Origin (DCO)

We use the [Developer Certificate of Origin](https://developercertificate.org/)
(DCO), version 1.1 — the same lightweight mechanism used by the Linux kernel
and the OW2 consortium. Every commit MUST be signed off.

Add a `Signed-off-by` line to every commit by using the `-s` (or `--signoff`)
flag:

```bash
git commit -s -m "Your commit message"
```

This appends a line such as:

```
Signed-off-by: Jane Doe <jane.doe@example.com>
```

By signing off, you certify the statement below (DCO 1.1). Your sign-off also
certifies your agreement to publish the contribution under the project's triple
license described above.

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

## Code conventions

See `CLAUDE.md` / `README.md` at the root of this repository for the project's
coding standards (JPMS-strict, zero runtime dependencies, virtual threads,
TDD, English-only code and Javadoc).
