# .github

Shared GitHub configuration for the rasgo-studio organization: the default pull request template
(`.github/PULL_REQUEST_TEMPLATE.md`) and the reusable CI workflows (`.github/workflows/ci-*.yml`),
called from each repository with `uses: rasgo-studio/.github/.github/workflows/<file>@main`.

## Deploy contract: `rasgo.deploy.yml`

Each repository that deploys keeps a `rasgo.deploy.yml` at its root: what it is, how it deploys and how a deploy
is checked (RINF-54). The reusable deploy workflows read it, and RASGO Core shows it in each approval. Version 1
keeps only what exists today: the adapters are the current ways of deploying, behind one contract. Its schema is
`schemas/deploy-contract.json`.

| Field | Required | What it says |
| --- | --- | --- |
| `version` | yes | `1` |
| `component` | yes | Its name in the Registry of RASGO Core: the repository, or the site it publishes |
| `stack` | yes | `laravel`, `wordpress`, `static`, `monorepo` or `n8n`, as the `stack` property of the repository (DEV-02.2) |
| `adapter` | yes | `laravel-ploi` (Ploi deploy webhook), `wordpress`, `static`, `monorepo-ploi` (rasgo-core, one Ploi site per environment) or `n8n` (rasgo-motor) |
| `environments` | yes | `staging` and `production`, each with `ref` (a branch, or `tag` for the published release), `url`, `approval` and `secrets` |
| `migrations` | no | The command the deploy runs after the code; it is shown in the approval |
| `health` | yes | `path` on the environment `url` that answers with the deployed version (`expect: version`), or only its status |
| `rollback` | yes | `previous-tag` (a deploy of the tag before, with its own approval) or `none` |

Rules of the contract:

- **Production always deploys with an approval of Core** (`approval: core`): the deploy workflow asks Core
  (`deploy-start`) whether the `approval_id` exists, has not expired and is for the same commit, and stops
  before touching the server if not (WFA-01.1, level 3; D-104). Staging may be automatic (`approval: none`, level 2).
- **Names, never values** (DEV-07): `secrets` lists the names of the environment secrets the adapter reads, such as
  the Ploi deploy webhook. No host, path with a secret, token or key goes in the contract.
- This repository is public (DEV-02.2): the examples here carry no client names; each repository writes its own.

Laravel app of a client, deployed by its Ploi sites:

```yaml
version: 1
component: acme-portal
stack: laravel
adapter: laravel-ploi
environments:
  staging:
    ref: main
    url: https://staging.example.com
    approval: none
    secrets: [PLOI_DEPLOY_WEBHOOK]
  production:
    ref: tag
    url: https://example.com
    approval: core
    secrets: [PLOI_DEPLOY_WEBHOOK]
migrations: php artisan migrate --force
health:
  path: /version
rollback: previous-tag
```

WordPress site (theme and configuration by Action, WPR-08):

```yaml
version: 1
component: example.com
stack: wordpress
adapter: wordpress
environments:
  production:
    ref: tag
    url: https://example.com
    approval: core
    secrets: [DEPLOY_SSH_KEY]
health:
  path: /
  expect: status
rollback: previous-tag
```

Static site (Cloudflare Pages):

```yaml
version: 1
component: example.org
stack: static
adapter: static
environments:
  staging:
    ref: main
    url: https://staging.example.org
    approval: none
    secrets: [CLOUDFLARE_API_TOKEN]
  production:
    ref: tag
    url: https://example.org
    approval: core
    secrets: [CLOUDFLARE_API_TOKEN]
health:
  path: /version.txt
rollback: none
```
