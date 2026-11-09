# .github

Shared GitHub configuration of the rasgo-studio organization: the default pull request template
(`.github/PULL_REQUEST_TEMPLATE.md`) and three reusable CI workflows. GitHub only tests: every deploy is Sergio's merge
into `main`, which the Ploi site of each repository pulls (`5-desarrollo/despliegues.md` of RASGO OS).

| Workflow | For | What it checks |
| --- | --- | --- |
| `ci-laravel.yml` | A Laravel app | The branch, then Pint, the build and Pest once `composer.json` exists |
| `ci-wordpress.yml` | A WordPress theme | The branch, the PHP syntax, phpcs and the theme build when they exist |
| `ci-static.yml` | A static site | The branch, lint, build and tests |

Each repository calls one from its own `.github/workflows/ci.yml`, as a job named `ci`:

```yaml
name: CI
on: [pull_request]
jobs:
  ci:
    uses: rasgo-studio/.github/.github/workflows/ci-laravel.yml@main
```

Each shared workflow ends with a job `ci` that is green only when nothing above failed, so a calling repository
reports one check, `ci / ci`: the one its ruleset asks for. The branch check asks for the code of a Plane task and a
number (`ACME01WEB-23-contact-form`), as `5-desarrollo/github.md` says. This repository is public: no client name, host or secret goes in it.
