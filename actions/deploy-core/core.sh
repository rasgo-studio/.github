#!/usr/bin/env bash
# Steps shared by the reusable deploy workflows of rasgo-studio (RINF-54, WFA-01.1, D-104).
#
#   core.sh require NAME...    the named environment variables (the secrets the adapter reads) are set
#   core.sh contract           reads rasgo.deploy.yml, checks it against this run and saves the deploy state
#   core.sh branch-head        the branch the Ploi site pulls is still at the commit of this run
#   core.sh version-file [DIR] writes DIR (or OUTPUT_DIR)/version.json with component, version and commit
#   core.sh start              deploy-start in RASGO Core: it only goes on with an approval Core confirms
#   core.sh health             waits until the environment answers with this commit or version
#   core.sh finish             deploy-finish in RASGO Core with the result
#
# Core is the barrier: without an answer from Core nothing deploys, and there is no emergency exit (RINF-54).
# The state of one deploy lives in a JSON file between steps; it holds names and ids, never a secret.
# Messages are in Spanish, for the person who reads the run (AGT-03).
set -euo pipefail

STATE="${RASGO_STATE:-${RUNNER_TEMP:-/tmp}/rasgo-deploy.json}"
CORE_URL="${CORE_URL:-https://api.rasgo.studio}"
CORE_URL="${CORE_URL%/}"

fail() {
  printf '::error::%s\n' "$*"
  summary "- $*"
  exit 1
}

note() { printf '%s\n' "$*"; }

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi
}

short() { printf '%s' "${1:0:7}"; }

state_get() { jq -r --arg k "$1" '.[$k] // empty' "$STATE"; }

state_set() {
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$STATE" > "$tmp"
  mv "$tmp" "$STATE"
}

# The runners bring the yq of mikefarah; elsewhere (a Mac, the tests) PyYAML does the same job.
yaml_to_json() {
  if yq --version 2>/dev/null | grep -q mikefarah; then
    yq -o=json '.' "$1"
  else
    python3 -c 'import json, sys, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$1"
  fi
}

# POST to Core: path, request file, response file. Prints the HTTP code; fails only when Core cannot be reached.
# The token goes in a header file, so it never shows in the command line of the runner.
core_post() {
  local path="$1" request="$2" response="$3" headers code rc=0
  shift 3
  headers="$(mktemp)"
  chmod 600 "$headers"
  printf 'Authorization: Bearer %s\n' "${CORE_TOKEN:-}" > "$headers"
  code="$(curl -sS --max-time 30 "$@" -X POST -H @"$headers" -H 'Content-Type: application/json' \
    -H 'Accept: application/json' --data-binary @"$request" -o "$response" -w '%{http_code}' \
    "$CORE_URL/api/v1/$path")" || rc=$?
  rm -f "$headers"
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$code"
}

cmd_require() {
  local name missing=""
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then missing="$missing $name"; fi
  done
  [ -z "$missing" ] || fail "Faltan secretos en el entorno ${DEPLOY_ENVIRONMENT:-}:$missing. Van en el entorno del repositorio, con el nombre que lista rasgo.deploy.yml (DEV-07)."
  note "Secretos presentes: $*"
}

cmd_contract() {
  local file="${CONTRACT_FILE:-rasgo.deploy.yml}" env="${DEPLOY_ENVIRONMENT:-}" json
  local adapter component ref url approval path expect timeout version app branch public tag

  case "$env" in
    staging | production) ;;
    *) fail "Entorno «$env» desconocido: el contrato v1 solo tiene staging y production." ;;
  esac
  [ -f "$file" ] || fail "No encuentro $file en la raíz del repositorio: es el contrato de despliegue (RINF-54)."
  json="$(yaml_to_json "$file")" || fail "$file no es un YAML válido."
  [ "$(jq -r '.version' <<< "$json")" = 1 ] || fail "$file no es la versión 1 del contrato de despliegue."

  adapter="$(jq -r '.adapter // empty' <<< "$json")"
  case " ${DEPLOY_ADAPTERS:-} " in
    *" $adapter "*) ;;
    *) fail "Este workflow despliega «${DEPLOY_ADAPTERS:-}» y el contrato dice adapter: «$adapter»." ;;
  esac
  component="$(jq -r '.component // empty' <<< "$json")"
  [ -n "$component" ] || fail "Al contrato le falta component."
  jq -e --arg e "$env" '.environments[$e]' <<< "$json" > /dev/null || fail "El contrato no tiene el entorno $env."

  ref="$(jq -r --arg e "$env" '.environments[$e].ref // empty' <<< "$json")"
  url="$(jq -r --arg e "$env" '.environments[$e].url // empty' <<< "$json")"
  approval="$(jq -r --arg e "$env" '.environments[$e].approval // "none"' <<< "$json")"
  [ -n "$ref" ] && [ -n "$url" ] || fail "Al entorno $env le falta ref o url."
  case "$url" in https://*) ;; *) fail "La url de $env no es https." ;; esac

  # Production always deploys with an approval of Core (WFA-01.1, level 3), whatever the contract says.
  if [ "$env" = production ] && [ "$approval" != core ]; then
    fail "Producción solo despliega con aprobación de Core (approval: core, WFA-01.1); el contrato dice «$approval»."
  fi
  if [ "$approval" = core ] && [ -z "${APPROVAL_ID:-}" ] && [ -z "${ROLLBACK_OF:-}" ]; then
    fail "Falta approval_id: $env solo despliega con una aprobación de Core para este commit (WFA-01.1). Pídela con approval.request y lanza el workflow con ella."
  fi

  # What runs is what the contract says deploys: the published tag, or that branch.
  if [ "$ref" = tag ]; then
    [ "${GITHUB_REF_TYPE:-}" = tag ] || fail "$env despliega una etiqueta publicada y esta ejecución es de la rama ${GITHUB_REF_NAME:-}: lánzalo sobre la etiqueta (gh workflow run … --ref <etiqueta>)."
    tag="$GITHUB_REF_NAME"
    branch="${PLOI_BRANCH:-main}"
  else
    [ "${GITHUB_REF_TYPE:-}" = branch ] && [ "${GITHUB_REF_NAME:-}" = "$ref" ] \
      || fail "$env despliega la rama $ref y esta ejecución es de ${GITHUB_REF_TYPE:-?} ${GITHUB_REF_NAME:-?}."
    tag=""
    branch="$ref"
  fi

  path="$(jq -r '.health.path // empty' <<< "$json")"
  expect="$(jq -r '.health.expect // "version"' <<< "$json")"
  timeout="$(jq -r '.health.timeout_s // 60' <<< "$json")"
  [ -n "$path" ] || fail "Al contrato le falta health.path."

  # The version recorded in Core: the input, else the number of the tag (acme-v1.2.3 → 1.2.3), else the short commit.
  version="${VERSION:-}"
  if [ -z "$version" ] && [ -n "$tag" ]; then
    version="${tag##*v}"
    case "$version" in [0-9]*) ;; *) version="$tag" ;; esac
  fi
  [ -n "$version" ] || version="$(short "$GITHUB_SHA")"
  app="${APP:-$component}"

  # Core keeps the contract it receives (spec 003, Clarify 7), without the names of the secrets.
  public="$(jq -c 'del(.environments[]?.secrets)' <<< "$json")"

  jq -n --arg component "$component" --arg app "$app" --arg adapter "$adapter" --arg environment "$env" \
    --arg ref "$ref" --arg tag "$tag" --arg branch "$branch" --arg url "${url%/}" --arg approval "$approval" \
    --arg health_path "$path" --arg health_expect "$expect" --arg health_timeout "$timeout" \
    --arg version "$version" --arg commit "${GITHUB_SHA:?}" --arg approval_id "${APPROVAL_ID:-}" \
    --arg rollback_of "${ROLLBACK_OF:-}" --arg task "${TASK:-}" --argjson contract "$public" \
    '{component: $component, app: $app, adapter: $adapter, environment: $environment, ref: $ref, tag: $tag,
      branch: $branch, url: $url, approval: $approval, health_path: $health_path, health_expect: $health_expect,
      health_timeout: $health_timeout, version: $version, commit: $commit, approval_id: $approval_id,
      rollback_of: $rollback_of, task: $task, contract: $contract}' > "$STATE"

  note "Contrato correcto: $component ($adapter) a $env, $url, versión $version, commit $(short "$GITHUB_SHA"), aprobación: $approval."
  summary "- Contrato: $component ($adapter) a $env, versión $version, commit $(short "$GITHUB_SHA")."
}

# Ploi pulls the head of a branch: deploying is only safe when that head is the commit approved in this run.
cmd_branch_head() {
  local branch head
  branch="$(state_get branch)"
  head="$(git ls-remote --exit-code origin "refs/heads/$branch" | cut -f1)" \
    || fail "No encuentro la rama $branch en el repositorio."
  [ "$head" = "$GITHUB_SHA" ] \
    || fail "Ploi despliega la cabeza de $branch ($(short "$head")) y esta ejecución es de $(short "$GITHUB_SHA"): el servidor no recibiría el commit aprobado. No se despliega."
  note "La rama $branch está en $(short "$head"), el commit de esta ejecución."
}

cmd_version_file() {
  local dir="${1:-${OUTPUT_DIR:-}}"
  [ -d "$dir" ] || fail "No existe la carpeta publicada «$dir»."
  if [ -e "$dir/version.json" ]; then
    note "$dir/version.json ya existe: no se toca."
    return
  fi
  jq -n --arg component "$(state_get component)" --arg version "$(state_get version)" --arg commit "$GITHUB_SHA" \
    '{component: $component, version: $version, commit: $commit}' > "$dir/version.json"
  note "Escrito $dir/version.json con la versión $(state_get version)."
}

reason_text() {
  case "$1" in
    missing) printf 'falta approval_id' ;;
    not_found) printf 'esa aprobación no existe' ;;
    pending) printf 'la aprobación sigue pendiente: apruébala en el Hub y vuelve a lanzarlo' ;;
    rejected) printf 'la aprobación está rechazada' ;;
    expired) printf 'la aprobación caducó (24 horas)' ;;
    used) printf 'la aprobación ya se usó: cada una sirve para un despliegue' ;;
    mismatch) printf 'la aprobación es para otro repositorio, app, entorno o commit' ;;
    rollback_not_allowed) printf 'el rollback no cumple las condiciones de Core (al último despliegue correcto, antes de 24 horas)' ;;
    *) printf '%s' "$1" ;;
  esac
}

cmd_start() {
  local request response code id reason rule
  [ -f "$STATE" ] || fail "Falta el paso contract antes de deploy-start."
  [ -n "${CORE_TOKEN:-}" ] || fail "Falta el secreto RASGO_CORE_DEPLOY_TOKEN."
  request="$(mktemp)"
  response="$(mktemp)"
  jq --arg repository "${GITHUB_REPOSITORY:?}" \
    --arg run_url "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-0}" \
    '{repository: $repository, app, environment, commit_sha: .commit, run_url: $run_url, contract}
     + (if .approval_id != "" then {approval_id} else {} end)
     + (if .rollback_of != "" then {rollback_of} else {} end)
     + (if .task != "" then {task} else {} end)' "$STATE" > "$request"

  code="$(core_post deploy-start "$request" "$response")" \
    || fail "No llego a Core ($CORE_URL). Sin respuesta de Core no se despliega (RINF-54)."
  case "$code" in
    200 | 201)
      id="$(jq -r '.deployment_id // empty' "$response" 2> /dev/null || true)"
      [ -n "$id" ] || fail "Core respondió $code a deploy-start sin deployment_id. No se despliega."
      state_set deployment_id "$id"
      note "Core confirma el despliegue $id."
      summary "- Core: despliegue $id empezado."
      ;;
    403)
      reason="$(jq -r '.reason // "desconocido"' "$response" 2> /dev/null || printf 'desconocido')"
      rule="$(jq -r '.rule // "WFA-01.1"' "$response" 2> /dev/null || printf 'WFA-01.1')"
      fail "Core no confirma la aprobación: $(reason_text "$reason") ($rule). No se toca el servidor."
      ;;
    401) fail "Core no acepta el token de despliegue (401): revisa RASGO_CORE_DEPLOY_TOKEN. No se despliega." ;;
    *) fail "Core respondió $code a deploy-start. No se despliega." ;;
  esac
  rm -f "$request" "$response"
}

body_has_version() {
  local body="$1" commit version pattern served
  commit="$(state_get commit)"
  version="$(state_get version)"
  # A JSON body that names its commit (version.json) answers by the commit alone: the release before can carry the same
  # version number, as when rasgo-core records the API version and the health host is a static app.
  served="$(jq -r 'if type == "object" and has("commit") then .commit | tostring else empty end' "$body" 2>/dev/null || true)"
  if [ -n "$served" ]; then
    [ "$served" = "$commit" ] && return 0
    [ "${#served}" -ge 7 ] && [ "${commit#"$served"}" != "$commit" ] && return 0
    return 1
  fi
  grep -Fq "$commit" "$body" && return 0
  grep -Fq "$(short "$commit")" "$body" && return 0
  [ -n "$version" ] || return 1
  pattern="${version//./\\.}"
  grep -Eq "(^|[^0-9A-Za-z.])${pattern}([^0-9A-Za-z.]|$)" "$body"
}

cmd_health() {
  local target expect timeout interval deadline body code
  [ -f "$STATE" ] || fail "Falta el paso contract antes de la comprobación."
  target="$(state_get url)$(state_get health_path)"
  expect="$(state_get health_expect)"
  timeout="$(state_get health_timeout)"
  interval="${HEALTH_INTERVAL:-5}"
  deadline=$(($(date +%s) + timeout))
  body="$(mktemp)"
  while :; do
    code="$(curl -sS -L --max-time 10 -H 'Cache-Control: no-cache' -o "$body" -w '%{http_code}' "$target" 2> /dev/null)" || code=000
    case "$code" in '' | *[!0-9]*) code=000 ;; esac
    if [ "$expect" = status ]; then
      if [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
        state_set health ok
        note "$target responde $code."
        summary "- Salud: $target responde $code (solo el estado HTTP)."
        return
      fi
    elif [ "$code" = 200 ] && body_has_version "$body"; then
      state_set health ok
      note "$target ya sirve la versión $(state_get version) ($(short "$(state_get commit)"))."
      summary "- Salud: $target sirve la versión $(state_get version)."
      return
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep "$interval"
  done
  state_set health failed
  fail "$target no sirve la versión $(state_get version) tras ${timeout} s (último código: $code)."
}

cmd_finish() {
  local id result request response code
  if [ ! -f "$STATE" ]; then
    note "No hay despliegue que cerrar en Core: el contrato no llegó a leerse."
    return
  fi
  id="$(state_get deployment_id)"
  if [ -z "$id" ]; then
    note "No hay despliegue que cerrar en Core: deploy-start no llegó a crearlo."
    return
  fi
  [ -n "${CORE_TOKEN:-}" ] || fail "Falta el secreto RASGO_CORE_DEPLOY_TOKEN: el despliegue $id queda abierto en Core."
  # A rollback that serves the version it went back to closes as rolled_back; anything else that is not healthy failed.
  if [ "$(state_get health)" = ok ]; then
    if [ -n "$(state_get rollback_of)" ]; then result=rolled_back; else result=success; fi
  else
    result=failure
  fi
  if [ -n "${VERSIONS:-}" ]; then
    jq -e 'type == "object"' <<< "$VERSIONS" > /dev/null 2>&1 || fail "versions no es un objeto JSON: $VERSIONS"
  fi
  request="$(mktemp)"
  response="$(mktemp)"
  jq --arg result "$result" --arg finished_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson versions "${VERSIONS:-null}" \
    '{deployment_id, result: $result, version, finished_at: $finished_at}
     + (if $versions != null then {versions: $versions} else {} end)' "$STATE" > "$request"
  code="$(core_post deploy-finish "$request" "$response" --retry 3 --retry-connrefused)" \
    || fail "No llego a Core ($CORE_URL): el despliegue $id ($result) queda abierto en Core."
  case "$code" in
    200 | 201)
      note "Core registra el despliegue $id: $result."
      summary "- Core: despliegue $id cerrado como $result."
      ;;
    # 409: the deploy is no longer started, as when a retry arrives after Core already closed it. Nothing stays open.
    409)
      echo "::warning::Core ya tenía cerrado el despliegue $id (409): no se registra otra vez como $result."
      summary "- Core: el despliegue $id ya estaba cerrado."
      ;;
    404) fail "Core no conoce el despliegue $id (404): este despliegue ($result) no queda registrado." ;;
    *) fail "Core respondió $code a deploy-finish: el despliegue $id ($result) queda abierto en Core." ;;
  esac
  rm -f "$request" "$response"
}

main() {
  local command="${1:-}"
  shift || true
  case "$command" in
    require) cmd_require "$@" ;;
    contract) cmd_contract ;;
    branch-head) cmd_branch_head ;;
    version-file) cmd_version_file "$@" ;;
    start) cmd_start ;;
    health) cmd_health ;;
    finish) cmd_finish ;;
    *)
      note "Uso: core.sh require|contract|branch-head|version-file|start|health|finish"
      exit 2
      ;;
  esac
}

main "$@"
