#!/usr/bin/env bash
# Tests of actions/deploy-core/core.sh (RINF-54). Core, Ploi and the sites are fakes: a curl and a git in PATH that
# answer from files and record each call. Run: bash tests/deploy-core.test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/actions/deploy-core/core.sh"
SHA="0123456789abcdef0123456789abcdef01234567"
PASS=0
FAILED=0
BASE="$(mktemp -d)"
export TMPDIR="$BASE"
trap 'rm -rf "$BASE"' EXIT

ok() {
  PASS=$((PASS + 1))
  printf 'ok   %s\n' "$1"
}

ko() {
  FAILED=$((FAILED + 1))
  printf 'FAIL %s\n' "$1"
  [ -z "${2:-}" ] || printf '     %s\n' "$2"
  [ ! -f "${OUT:-}" ] || sed 's/^/     | /' "$OUT"
}

# A clean run: a repository with its contract, fake curl and git, and the variables GitHub sets.
setup() {
  WORK="$(mktemp -d "$BASE/run.XXXXXX")"
  FAKE="$WORK/fake"
  mkdir -p "$FAKE/bin" "$WORK/repo"
  OUT="$WORK/out"
  cat > "$FAKE/bin/curl" << 'EOF'
#!/usr/bin/env bash
out="" data="" url=""
printf '%s\n' "$*" >> "$FAKE_DIR/args"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    -H) case "$2" in @*) cat "${2#@}" >> "$FAKE_DIR/headers" ;; esac; shift 2 ;;
    -w | -X | --max-time | --retry) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  */api/v1/deploy-start) key=start ;;
  */api/v1/deploy-finish) key=finish ;;
  *) key=health ;;
esac
n=$(($(cat "$FAKE_DIR/count.$key" 2> /dev/null || echo 0) + 1))
echo "$n" > "$FAKE_DIR/count.$key"
echo "$url" >> "$FAKE_DIR/urls"
if [ -n "$data" ]; then cp "$data" "$FAKE_DIR/request.$key.json"; fi
if [ -f "$FAKE_DIR/$key.unreachable" ]; then exit 7; fi
body="$FAKE_DIR/$key.$n.body"; [ -f "$body" ] || body="$FAKE_DIR/$key.body"
code="$FAKE_DIR/$key.$n.code"; [ -f "$code" ] || code="$FAKE_DIR/$key.code"
if [ -n "$out" ]; then if [ -f "$body" ]; then cp "$body" "$out"; else : > "$out"; fi; fi
cat "$code" 2> /dev/null || printf '000'
EOF
  cat > "$FAKE/bin/git" << 'EOF'
#!/usr/bin/env bash
[ "$1" = ls-remote ] || exit 1
[ -f "$FAKE_DIR/head" ] || exit 2
printf '%s\t%s\n' "$(cat "$FAKE_DIR/head")" "$4"
EOF
  chmod +x "$FAKE/bin/curl" "$FAKE/bin/git"
  cat > "$WORK/repo/rasgo.deploy.yml" << 'EOF'
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
    url: https://example.com/
    approval: core
    secrets: [PLOI_DEPLOY_WEBHOOK]
migrations: php artisan migrate --force
health:
  path: /version
  timeout_s: 5
rollback: previous-tag
EOF
  unset APPROVAL_ID ROLLBACK_OF TASK APP VERSION VERSIONS PLOI_BRANCH CORE_TOKEN OUTPUT_DIR CONTRACT_FILE
  export FAKE_DIR="$FAKE" PATH="$FAKE/bin:$PATH" RASGO_STATE="$WORK/state.json" HEALTH_INTERVAL=0
  export GITHUB_SHA="$SHA" GITHUB_REPOSITORY="rasgo-studio/acme-portal" GITHUB_SERVER_URL="https://github.com"
  export GITHUB_RUN_ID=42 GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main GITHUB_STEP_SUMMARY="$WORK/summary"
  export DEPLOY_ENVIRONMENT=staging DEPLOY_ADAPTERS="laravel-ploi monorepo-ploi" CORE_URL="https://core.test/"
  cd "$WORK/repo" || exit 1
}

answer() { # key code [body]
  printf '%s' "$2" > "$FAKE/$1.code"
  if [ -n "${3:-}" ]; then printf '%s' "$3" > "$FAKE/$1.body"; fi
}

core() { "$CORE" "$@" > "$OUT" 2>&1; }
has() { grep -Fq -- "$1" "$OUT"; }
state() { jq -r ".$1 // empty" "$RASGO_STATE"; }

expect_ok() { # name command...
  local name="$1"
  shift
  if core "$@"; then ok "$name"; else ko "$name" "exited $?"; fi
}

expect_fail() { # name text command...
  local name="$1" text="$2"
  shift 2
  if core "$@"; then
    ko "$name" "expected a failure"
  elif has "$text"; then
    ok "$name"
  else
    ko "$name" "missing: $text"
  fi
}

check() { # name condition...
  local name="$1"
  shift
  if "$@"; then ok "$name"; else ko "$name" "condition: $*"; fi
}

# --- contract ---------------------------------------------------------------------------------------------------

setup
expect_ok "contract: staging from its branch" contract
check "contract: state has the url without the trailing slash" test "$(state url)" = "https://staging.example.com"
check "contract: version is the short commit off a tag" test "$(state version)" = "0123456"
check "contract: the contract sent to Core drops the secret names" test "$(jq '.contract | tostring | test("PLOI_DEPLOY_WEBHOOK")' "$RASGO_STATE")" = false
check "contract: app defaults to the component" test "$(state app)" = acme-portal

setup
export DEPLOY_ENVIRONMENT=production GITHUB_REF_TYPE=tag GITHUB_REF_NAME=acme-v1.4.0
expect_fail "contract: production needs an approval_id" "Falta approval_id" contract
check "contract: the message cites WFA-01.1" has "WFA-01.1"

setup
export DEPLOY_ENVIRONMENT=production APPROVAL_ID=01JAPPROVAL
expect_fail "contract: production deploys a tag, not a branch" "etiqueta publicada" contract

setup
export DEPLOY_ENVIRONMENT=production APPROVAL_ID=01JAPPROVAL GITHUB_REF_TYPE=tag GITHUB_REF_NAME=acme-v1.4.0
expect_ok "contract: production on a tag with an approval" contract
check "contract: version is the number of the tag" test "$(state version)" = "1.4.0"
check "contract: a tag deploy follows the Ploi branch (main)" test "$(state branch)" = main
check "contract: the trailing slash of the url goes" test "$(state url)" = "https://example.com"

setup
export DEPLOY_ENVIRONMENT=production ROLLBACK_OF=01JFAILED GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.3.0 PLOI_BRANCH=release
expect_ok "contract: a rollback goes on without approval_id (Core decides)" contract
check "contract: PLOI_BRANCH for a tag" test "$(state branch)" = release

setup
sed -i 's/approval: core/approval: none/' rasgo.deploy.yml
export DEPLOY_ENVIRONMENT=production APPROVAL_ID=01JAPPROVAL GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.4.0
expect_fail "contract: production without approval core is refused" "Producción solo despliega" contract

setup
export DEPLOY_ADAPTERS=static
expect_fail "contract: another adapter is refused" "adapter: «laravel-ploi»" contract

setup
export GITHUB_REF_NAME=feature-x
expect_fail "contract: staging only from its branch" "despliega la rama main" contract

setup
export DEPLOY_ENVIRONMENT=preview
expect_fail "contract: unknown environment" "desconocido" contract

setup
rm rasgo.deploy.yml
expect_fail "contract: no contract, no deploy" "No encuentro rasgo.deploy.yml" contract

if python3 -c 'import jsonschema' 2> /dev/null; then
  setup
  if python3 - "$ROOT/schemas/deploy-contract.json" rasgo.deploy.yml << 'EOF'; then ok "contract: the fixture follows the schema"; else ko "contract: the fixture follows the schema"; fi
import json, sys, yaml, jsonschema
jsonschema.validate(yaml.safe_load(open(sys.argv[2])), json.load(open(sys.argv[1])))
EOF
  # Every contract example of the README follows the schema too.
  if python3 - "$ROOT/schemas/deploy-contract.json" "$ROOT/README.md" << 'EOF'; then ok "contract: the README examples follow the schema"; else ko "contract: the README examples follow the schema"; fi
import json, re, sys, yaml, jsonschema
schema = json.load(open(sys.argv[1]))
blocks = [b for b in re.findall(r"```yaml\n(.*?)```", open(sys.argv[2]).read(), re.S) if b.startswith("version: 1")]
assert len(blocks) >= 3, blocks
for block in blocks:
    jsonschema.validate(yaml.safe_load(block), schema)
EOF
fi

# --- require ----------------------------------------------------------------------------------------------------

setup
export PLOI_DEPLOY_WEBHOOK=""
expect_fail "require: a missing secret stops the deploy" "PLOI_DEPLOY_WEBHOOK" require RASGO_CORE_DEPLOY_TOKEN PLOI_DEPLOY_WEBHOOK
export PLOI_DEPLOY_WEBHOOK=x RASGO_CORE_DEPLOY_TOKEN=y
expect_ok "require: all secrets present" require RASGO_CORE_DEPLOY_TOKEN PLOI_DEPLOY_WEBHOOK
check "require: the values are not printed" test "$(grep -c '^x$\|^y$' "$OUT")" = 0
unset PLOI_DEPLOY_WEBHOOK RASGO_CORE_DEPLOY_TOKEN

# --- branch-head ------------------------------------------------------------------------------------------------

setup
core contract
printf '%s' "$SHA" > "$FAKE/head"
expect_ok "branch-head: the branch is at the commit of the run" branch-head
printf '%s' "fedcba9876543210fedcba9876543210fedcba98" > "$FAKE/head"
expect_fail "branch-head: a branch that moved stops the deploy" "no recibiría el commit aprobado" branch-head

# --- start ------------------------------------------------------------------------------------------------------

setup
export DEPLOY_ENVIRONMENT=production APPROVAL_ID=01JAPPROVAL TASK=ACME01WEB-23 GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.4.0
core contract
export CORE_TOKEN=token-secret-value
answer start 201 '{"deployment_id":"01JDEPLOY"}'
expect_ok "start: Core confirms the approval" start
check "start: the deployment_id is saved" test "$(state deployment_id)" = 01JDEPLOY
check "start: calls deploy-start on Core" grep -Fxq "https://core.test/api/v1/deploy-start" "$FAKE/urls"
check "start: the body carries the approval tuple" test "$(jq -r '[.repository, .app, .environment, .commit_sha, .approval_id, .task] | join(" ")' "$FAKE/request.start.json")" = "rasgo-studio/acme-portal acme-portal production $SHA 01JAPPROVAL ACME01WEB-23"
check "start: the body carries the run url" test "$(jq -r .run_url "$FAKE/request.start.json")" = "https://github.com/rasgo-studio/acme-portal/actions/runs/42"
check "start: no rollback_of when there is none" test "$(jq 'has("rollback_of")' "$FAKE/request.start.json")" = false
check "start: the token goes in a header" grep -Fq "Authorization: Bearer token-secret-value" "$FAKE/headers"
check "start: the token is not on the command line" test "$(grep -c token-secret-value "$FAKE/args")" = 0

setup
core contract
export CORE_TOKEN=t
answer start 403 '{"error":"Approval already used","reason":"used","rule":"WFA-01.1"}'
expect_fail "start: a used approval stops the deploy" "ya se usó" start
check "start: the rule is shown" has "(WFA-01.1)"
check "start: no deployment_id after a 403" test -z "$(state deployment_id)"

setup
core contract
export CORE_TOKEN=t
answer start 403 '{"reason":"mismatch","rule":"WFA-01.1"}'
expect_fail "start: an approval for another commit stops the deploy" "otro repositorio, app, entorno o commit" start

setup
core contract
export CORE_TOKEN=t
answer start 500 '{}'
expect_fail "start: an error of Core stops the deploy" "respondió 500" start

setup
core contract
export CORE_TOKEN=t
touch "$FAKE/start.unreachable"
expect_fail "start: without Core nothing deploys" "No llego a Core" start

setup
core contract
answer start 201 '{"deployment_id":"01JDEPLOY"}'
expect_fail "start: without the token nothing deploys" "RASGO_CORE_DEPLOY_TOKEN" start

setup
core contract
export CORE_TOKEN=t
answer start 201 '{}'
expect_fail "start: a 201 without deployment_id stops the deploy" "sin deployment_id" start

# --- health -----------------------------------------------------------------------------------------------------

setup
core contract
printf '200' > "$FAKE/health.1.code"
printf '{"version":"0.9.0","commit":"aaaaaaa"}' > "$FAKE/health.1.body"
answer health 200 '{"version":"0.9.1","commit":"0123456"}'
expect_ok "health: waits until the short commit is served" health
check "health: asked twice" test "$(cat "$FAKE/count.health")" = 2
check "health: asks url plus path" grep -Fxq "https://staging.example.com/version" "$FAKE/urls"
check "health: state ok" test "$(state health)" = ok

setup
export DEPLOY_ENVIRONMENT=production APPROVAL_ID=a GITHUB_REF_TYPE=tag GITHUB_REF_NAME=acme-v1.4.0
core contract
answer health 200 '{"app":"acme-portal","version":"1.4.0"}'
expect_ok "health: the version number counts" health

setup
export DEPLOY_ENVIRONMENT=production APPROVAL_ID=a GITHUB_REF_TYPE=tag GITHUB_REF_NAME=acme-v1.4.0
core contract
jq '.health_timeout = "1"' "$RASGO_STATE" > "$RASGO_STATE.tmp" && mv "$RASGO_STATE.tmp" "$RASGO_STATE"
export HEALTH_INTERVAL=1
answer health 200 '{"version":"11.4.0"}'
expect_fail "health: another version is not this one (timeout)" "no sirve la versión 1.4.0" health
check "health: state failed" test "$(state health)" = failed

setup
export DEPLOY_ENVIRONMENT=production APPROVAL_ID=a GITHUB_REF_TYPE=tag GITHUB_REF_NAME=acme-v1.4.0
core contract
jq '.health_timeout = "1"' "$RASGO_STATE" > "$RASGO_STATE.tmp" && mv "$RASGO_STATE.tmp" "$RASGO_STATE"
export HEALTH_INTERVAL=1
answer health 200 '{"app":"web","version":"1.4.0","commit":"aaaaaaabbbbbbb"}'
expect_fail "health: the same version from another commit is the old release" "no sirve la versión 1.4.0" health

setup
export DEPLOY_ENVIRONMENT=production APPROVAL_ID=a GITHUB_REF_TYPE=tag GITHUB_REF_NAME=acme-v1.4.0
core contract
answer health 200 "{\"app\":\"web\",\"version\":\"2.0.0\",\"commit\":\"$SHA\"}"
expect_ok "health: with a commit field, the full commit counts whatever the version" health

setup
core contract
answer health 200 "{\"app\":\"web\",\"version\":\"2.0.0\",\"commit\":\"${SHA:0:10}\"}"
expect_ok "health: with a commit field, a prefix of the commit counts" health

setup
core contract
jq '.health_timeout = "1"' "$RASGO_STATE" > "$RASGO_STATE.tmp" && mv "$RASGO_STATE.tmp" "$RASGO_STATE"
export HEALTH_INTERVAL=1
answer health 200 "{\"app\":\"web\",\"commit\":\"${SHA:0:4}\"}"
expect_fail "health: a commit shorter than 7 characters does not count" "no sirve la versión" health

setup
sed -i 's|  timeout_s: 5|  expect: status\n  timeout_s: 5|' rasgo.deploy.yml
core contract
answer health 200 'hello'
expect_ok "health: status only" health
jq '.health_timeout = "1"' "$RASGO_STATE" > "$RASGO_STATE.tmp" && mv "$RASGO_STATE.tmp" "$RASGO_STATE"
export HEALTH_INTERVAL=1
answer health 503 'down'
expect_fail "health: a 503 is not healthy" "último código: 503" health

# --- finish -----------------------------------------------------------------------------------------------------

setup
core contract
export CORE_TOKEN=t
jq '.deployment_id = "01JDEPLOY" | .health = "ok"' "$RASGO_STATE" > "$RASGO_STATE.tmp" && mv "$RASGO_STATE.tmp" "$RASGO_STATE"
answer finish 200 '{}'
export VERSIONS='{"api":"1.2.0","hub":"0.4.0"}'
expect_ok "finish: a healthy deploy" finish
check "finish: result success" test "$(jq -r .result "$FAKE/request.finish.json")" = success
check "finish: deployment_id and version" test "$(jq -r '[.deployment_id, .version] | join(" ")' "$FAKE/request.finish.json")" = "01JDEPLOY 0123456"
check "finish: versions of a monorepo" test "$(jq -r .versions.hub "$FAKE/request.finish.json")" = 0.4.0
check "finish: finished_at in UTC" grep -Eq '"finished_at": "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z"' "$FAKE/request.finish.json"
check "finish: retries only when Core cannot be reached" grep -Fq -- "--retry 3 --retry-connrefused" "$FAKE/args"

setup
export DEPLOY_ENVIRONMENT=production ROLLBACK_OF=01JFAILED GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v1.3.0
core contract
export CORE_TOKEN=t
jq '.deployment_id = "01JDEPLOY" | .health = "ok"' "$RASGO_STATE" > "$RASGO_STATE.tmp" && mv "$RASGO_STATE.tmp" "$RASGO_STATE"
answer finish 200 '{}'
expect_ok "finish: a rollback" finish
check "finish: a healthy rollback is rolled_back" test "$(jq -r .result "$FAKE/request.finish.json")" = rolled_back

setup
core contract
export CORE_TOKEN=t
jq '.deployment_id = "01JDEPLOY" | .health = "failed"' "$RASGO_STATE" > "$RASGO_STATE.tmp" && mv "$RASGO_STATE.tmp" "$RASGO_STATE"
answer finish 200 '{}'
expect_ok "finish: records a failed deploy" finish
check "finish: result failure" test "$(jq -r .result "$FAKE/request.finish.json")" = failure

setup
core contract
export CORE_TOKEN=t
jq '.deployment_id = "01JDEPLOY"' "$RASGO_STATE" > "$RASGO_STATE.tmp" && mv "$RASGO_STATE.tmp" "$RASGO_STATE"
answer finish 200 '{}'
expect_ok "finish: a deploy that never got checked" finish
check "finish: without health it is a failure" test "$(jq -r .result "$FAKE/request.finish.json")" = failure

setup
core contract
export CORE_TOKEN=t
expect_ok "finish: nothing to close when deploy-start did not create it" finish
check "finish: no call to Core" test ! -f "$FAKE/request.finish.json"

setup
expect_ok "finish: nothing to close without a contract" finish

setup
core contract
export CORE_TOKEN=t
jq '.deployment_id = "01JDEPLOY" | .health = "ok"' "$RASGO_STATE" > "$RASGO_STATE.tmp" && mv "$RASGO_STATE.tmp" "$RASGO_STATE"
answer finish 500 '{}'
expect_fail "finish: says when the deploy stays open in Core" "queda abierto en Core" finish

setup
core contract
export CORE_TOKEN=t VERSIONS='not json'
jq '.deployment_id = "01JDEPLOY" | .health = "ok"' "$RASGO_STATE" > "$RASGO_STATE.tmp" && mv "$RASGO_STATE.tmp" "$RASGO_STATE"
expect_fail "finish: versions must be a JSON object" "no es un objeto JSON" finish

# --- version-file -----------------------------------------------------------------------------------------------

setup
core contract
mkdir -p .output/public
export OUTPUT_DIR=.output/public
expect_ok "version-file: writes version.json" version-file
check "version-file: with the commit" test "$(jq -r .commit .output/public/version.json)" = "$SHA"
check "version-file: with the component" test "$(jq -r .component .output/public/version.json)" = acme-portal
printf '{"mine":true}' > .output/public/version.json
expect_ok "version-file: an existing version.json stays" version-file
check "version-file: untouched" test "$(jq -r .mine .output/public/version.json)" = true
expect_fail "version-file: a folder that does not exist" "No existe la carpeta" version-file dist

printf '\n%s passed, %s failed\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ]
