# Vidocq CI — composite actions partagées

Composite actions Forgejo/Codeberg mutualisant les étapes de CI répétées dans les
sous-projets Vidocq. **Ce repo n'est pas un projet Maven** : il ne se build pas, ne se
teste pas, ne se publie nulle part. Il fournit seulement des actions réutilisables via
`uses: Vidocq/ci/<action>@<ref>`.

> Repo **public** à dessein : il ne contient aucun secret, et un repo public évite que le
> runner ait à s'authentifier pour cloner l'action depuis les repos privés.

## Actions

| Action | Rôle | Inputs notables (tous surchargeables) |
|--------|------|----------------------------------------|
| `setup-maven` | Installe Temurin + Maven, les met dans le PATH | `java-version` (25), `maven-version` (4.0.0-rc-5), `distribution` (temurin), `cache` (maven) |
| `run-tck` | Lance un TCK Maven ou un script shell custom | `command` (shell prioritaire), `module` (-pl), `profile` (tck), `pre-install` (true), `maven-args` (-B -ntp) |
| `notify-slack` | Notification `[ViBot]` sur Slack | `webhook-url` (requis), `status` (success/failure), `repo`, `ref`, `run-url`, `version`/`sha`/`commit-*` (succès) |
| `deploy-maven` | settings.xml + import GPG + deploy Central (SNAPSHOT/RELEASE selon version) | `central-username`, `central-password`, `gpg-private-key`, `gpg-passphrase`, `snapshot-profile` (snapshot), `release-profile` (release) |

## Exemples

```yaml
# Maven 3.9 pour un TCK qui l'exige :
- uses: Vidocq/ci/setup-maven@v1
  with: { maven-version: 3.9.9 }
- uses: Vidocq/ci/run-tck@v1
  with: { module: mon-module-tck }

# TCK hors-reactor via script :
- uses: Vidocq/ci/run-tck@v1
  with: { command: "./run-official-tck-restful-4.0.sh all", pre-install: "false" }
```

## Secrets

Une composite action **n'hérite pas** des `secrets.*` : ils doivent être passés
explicitement via `with:` (mappés en `inputs`, puis ré-exportés en `env:` dans les steps).
Les secrets restent gérés au niveau **organisation** Codeberg.

## Versionnement

- Référencer un **tag mobile `@v1`** (re-pointé sur chaque évolution rétrocompatible).
- Épingler `@vX.Y.Z` pour un repo qui veut figer.
- Breaking change → `v2`, migration repo par repo.
- `@main` réservé aux phases de validation (pilote).
