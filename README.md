# .github

Shared GitHub configuration for the rasgo-studio organization: the default pull request template
(`.github/PULL_REQUEST_TEMPLATE.md`), the reusable CI workflows (`.github/workflows/ci-*.yml`) and the reusable
deploy workflows (`.github/workflows/deploy-*.yml`), called from each repository with
`uses: rasgo-studio/.github/.github/workflows/<file>@main`.

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
| `adapter` | yes | `laravel-ploi` (Ploi deploy webhook), `wordpress` (Ploi deploy webhook too), `static` (Cloudflare Pages), `monorepo-ploi` (rasgo-core, one Ploi site per environment) or `n8n` (rasgo-motor) |
| `environments` | yes | `staging` and `production`, each with `ref` (a branch, or `tag` for the published release), `url`, `approval` and `secrets` |
| `migrations` | no | The command the deploy runs after the code; it is shown in the approval |
| `health` | yes | `path` on the environment `url` that answers with the deployed version (`expect: version`), or only its status |
| `rollback` | yes | `previous-tag` (a deploy of the tag before: Core allows it without a new approval up to 24 hours after the failed deploy) or `none` (going back is not done by the system) |

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
  timeout_s: 300
rollback: none
```

WordPress site, deployed by its Ploi site (WPR-08):

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
    secrets: [PLOI_DEPLOY_WEBHOOK]
health:
  path: /
  expect: status
  timeout_s: 120
rollback: none
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
    secrets: [CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID]
  production:
    ref: tag
    url: https://example.org
    approval: core
    secrets: [CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID]
health:
  path: /version.json
rollback: previous-tag
```

## Deploy workflows

Three reusable workflows deploy what a contract describes, one per way of deploying (RINF-54). Each repository calls
the one of its `adapter` from its own `.github/workflows/deploy.yml`; the header of each file has the call to copy.

| Workflow | Adapters | How the code reaches the server |
| --- | --- | --- |
| `deploy-laravel.yml` | `laravel-ploi`, `monorepo-ploi` | Calls the Ploi deploy webhook of the site; its deploy script pulls and builds |
| `deploy-wordpress.yml` | `wordpress` | The same: the Ploi site pulls the repository and builds the theme |
| `deploy-static.yml` | `static` | Builds this commit in the Action and uploads it to Cloudflare Pages with wrangler (Direct Upload) |

Every deploy follows the same order, and stops at the first step that fails:

1. **Contract.** Reads `rasgo.deploy.yml` and checks it against the run: the adapter is the one of the workflow, the
   environment exists, production has `approval: core`, an environment with `approval: core` got an `approval_id`,
   and the run comes from what the environment deploys (its branch, or a tag when `ref: tag`).
2. **Secrets.** The secrets the adapter reads come from Bitwarden Secrets Manager or, while they have not moved, from
   the environment of the calling repository (see Secrets below). In `deploy-static.yml` this step runs after the build.
3. **deploy-start.** Asks RASGO Core with the repository, app, environment, commit and `approval_id`. Core answers with
   a `deployment_id`, or with 403 and the reason (`pending`, `expired`, `used`, `mismatch`…), and then nothing touches
   the server (WFA-01.1, D-104). If Core does not answer, nothing deploys: there is no emergency exit.
4. **Deploy.** The adapter: the Ploi webhook, or the upload to Cloudflare Pages.
5. **Health.** Asks `url` + `health.path` until it answers with this commit (full or short) or this version, up to
   `health.timeout_s`. A JSON answer with a `commit` field, such as a `version.json`, counts only by that commit: the
   release before may carry the same version number. With `expect: status` it only checks that the site answers,
   which does not prove the new code is live.
6. **deploy-finish.** Closes the deploy in Core with `success`, `failure` or, for a healthy rollback, `rolled_back`.
   It runs even when an earlier step failed, so failed deploys are recorded too.

Calling them:

- **Inputs.** `environment` (required), `approval_id`, `rollback_of` (the `deployment_id` of the failed deploy that
  this one undoes) and `task` (the Plane code, so Core can report on it), plus `app`, `version` and, for a monorepo,
  `versions` (a JSON object with the version of each app). `deploy-static.yml` also takes `pages-project`,
  `build-command`, `output-dir`, `production-branch` and `staging-branch`.
- **Tying a deploy to its run.** `deploy-laravel.yml` takes `run_id`, the number of the RASGO Core run the deploy
  belongs to. With it, deploy-start and deploy-finish carry the header `X-Rasgo-Run: <run_id>` and Core keeps the
  deploy in `deployments.run_id`, as an artifact of that run (RCOR-45). Only digits are accepted, and the Contract
  step stops on anything else. Without it, neither request carries the header and the deploy works as before. Core
  ignores a number that is not one of its runs.
- **Secrets** have the names the contract lists (DEV-07): `RASGO_CORE_DEPLOY_TOKEN` always (the Core token of the
  deploy actor, ops 1), then `PLOI_DEPLOY_WEBHOOK`, or `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. They live in
  Bitwarden Secrets Manager, project `actions`, EU region (D-109). The `staging` and `production` environments of the
  calling repository keep only `BWS_ACCESS_TOKEN`, the token of the read-only machine account of that project.
  - **Keys.** One project holds every repository, so the Secrets step looks for the most specific key first:
    `NAME__<COMPONENT>__<ENVIRONMENT>`, then `NAME__<COMPONENT>`, then `NAME`. The component of the contract and the
    environment go in capitals, with anything else as `_`: the production webhook of `acme-portal` is
    `PLOI_DEPLOY_WEBHOOK__ACME_PORTAL__PRODUCTION`; a token shared by all, such as `RASGO_CORE_DEPLOY_TOKEN`, keeps
    its plain name.
  - **While they move (RINF-55).** A name not found in Bitwarden is taken from the GitHub secret of the same name, and
    the run warns with its name. Without `BWS_ACCESS_TOKEN` everything comes from GitHub, as before. A name in
    neither place stops the deploy.
  - **How.** `bws` (bitwarden/sdk-sm, pinned version, checked against its sha256) reads the project with the
    machine account. Each value is masked and left for the next steps of the job, and the run names the keys it
    used, never a value. If Bitwarden does not answer, nothing deploys. Optional repository variables:
    `BWS_PROJECT_ID` (read only that project) and `BWS_SERVER_URL` (another region).
  - **Calling.** With `secrets: inherit`, or passing `BWS_ACCESS_TOKEN` explicitly under `secrets:`.
- The repository variable `RASGO_CORE_URL` points to another Core, for tests.
- **Production** runs from `workflow_dispatch` once Sergio has approved it in the Hub, on the tag it deploys:
  `gh workflow run deploy.yml --ref acme-v1.4.0 -f environment=production -f approval_id=<id>`. Each approval serves
  one deploy of one commit and lasts 24 hours (spec 003 of rasgo-core). Staging with `approval: none` can deploy on
  each push to its branch.
- **Ploi deploys the head of its branch**, not a given commit. So both Ploi workflows stop before deploy-start when
  that head (`ref`, or `ploi-branch` for a tag, `main` by default) is not the commit of the run: with release-please,
  deploy the tag right after merging the release. For the same reason a Ploi rollback to an older tag cannot pass;
  going back there is a revert merged into the branch, deployed with a new approval, or the rollback of the Ploi panel
  (Sergio); their contracts say `rollback: none`. `deploy-static.yml` builds the commit it runs on, so
  `rollback: previous-tag` works there.
- **Static sites** get `version.json` (`component`, `version`, `commit`) in the published folder unless the build
  writes one, so `health.path: /version.json` checks the deployed commit.

The steps live in `actions/deploy-core` (`core.sh`, with its tests in `tests/`). The workflows call it at `@main`,
like the repositories call the workflows: a change here reaches every deploy at once, so it comes with its tests and
the `test` workflow green.
