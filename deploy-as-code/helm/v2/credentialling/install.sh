#!/usr/bin/env bash
# =============================================================================
# Sunbird RC Credentialling - Helm v2 installer
#
# Usage:
#   export DB_PASSWORD='<strong-password>'      # or set global.db.password in global-values.yaml
#   ./install.sh install                     # deploy everything
#   ./install.sh install <chart|group> ...   # deploy only these (already deployed ones stay)
#   ./install.sh remove  <chart|group> ...   # remove only these (others keep running)
#   ./install.sh template [chart|group ...]  # render manifests only (dry run)
#   ./install.sh status                      # pods, vault seal status, nginx IP
#   ./install.sh test [all|core|identity|schema|credentials|oid4vc]
#                                            # API tests (official Postman collection, needs node)
#   ./install.sh uninstall                   # remove release (volumes + vault-keys kept)
#
# Charts: vault db identity-service credential-schema-service credentials-service
#         oid4vc-service nginx
# Groups: all | core (vault db identity-service) | infra (vault db)
#         services (identity, schema, credentials, oid4vc) | public (nginx)
# Examples:
#   ./install.sh install core
#   ./install.sh install credentials-service nginx
#   ./install.sh remove oid4vc-service
#
# Optional env vars:
#   RELEASE (default rc)   NAMESPACE (default sunbird)   TIMEOUT (default 15m)
#   VALUES_FILE (default ./global-values.yaml)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="${RELEASE:-rc}"
NAMESPACE="${NAMESPACE:-sunbird}"
TIMEOUT="${TIMEOUT:-15m}"
VALUES_FILE="${VALUES_FILE:-$SCRIPT_DIR/global-values.yaml}"

log()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32m  ✓\033[0m $*"; }
warn() { echo -e "\033[1;33m  !\033[0m $*"; }
die()  { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

# Umbrella chart lives in this folder (Chart.yaml next to this script).
# Falls back to the old ./helm_charts layout until the files are moved up.
if [[ -f "$SCRIPT_DIR/Chart.yaml" ]]; then
  CHART="$SCRIPT_DIR"
elif [[ -f "$SCRIPT_DIR/helm_charts/Chart.yaml" ]]; then
  CHART="$SCRIPT_DIR/helm_charts"
else
  die "Chart.yaml not found next to install.sh"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
EXTRA_VALUES=()

# -----------------------------------------------------------------------------
# Checks
# -----------------------------------------------------------------------------
check_tools() {
  log "Checking tools"
  for t in helm kubectl; do
    command -v "$t" >/dev/null 2>&1 || die "$t is not installed"
  done
  ok "helm $(helm version --short 2>/dev/null), kubectl present"
}

check_files() {
  log "Checking values files"
  for f in "$SCRIPT_DIR/images.yaml" "$SCRIPT_DIR/global-resources.yaml" "$VALUES_FILE"; do
    [[ -f "$f" ]] || die "missing $f"
  done
  ok "images.yaml, global-resources.yaml, $(basename "$VALUES_FILE")"
}

# DB password: from $DB_PASSWORD (preferred, never written to git) or the values file
prepare_password() {
  log "Checking DB password"
  if [[ -n "${DB_PASSWORD:-}" ]]; then
    local pw_file="$TMP_DIR/db-password.yaml"
    umask 077
    # JSON string is valid YAML and safely escapes any special characters
    printf 'global:\n  db:\n    password: %s\n' \
      "$(printf '%s' "$DB_PASSWORD" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      > "$pw_file"
    EXTRA_VALUES+=(-f "$pw_file")
    ok "using DB_PASSWORD from environment"
  elif grep -q '<DB_PASSWORD>' "$VALUES_FILE"; then
    die "DB password not set. Run: export DB_PASSWORD='<strong-password>'  (or set global.db.password in $(basename "$VALUES_FILE"))"
  else
    ok "using global.db.password from $(basename "$VALUES_FILE")"
  fi
}

check_cluster() {
  log "Checking cluster access (context: $(kubectl config current-context 2>/dev/null || echo none))"
  kubectl version --request-timeout=15s >/dev/null 2>&1 \
    || die "cannot reach the cluster API (private AKS? connect VPN / jump box first)"
  ok "cluster reachable"

  local missing=0
  for check in "create statefulsets" "create deployments" "create secrets" "create roles" "create rolebindings" "create persistentvolumeclaims" "create jobs"; do
    if kubectl auth can-i $check -n "$NAMESPACE" >/dev/null 2>&1; then
      ok "can $check in $NAMESPACE"
    else
      warn "NOT allowed: $check in $NAMESPACE"; missing=1
    fi
  done
  [[ $missing -eq 0 ]] || die "missing permissions in namespace $NAMESPACE (ask cluster admin)"

  # capture first: "grep -q" + pipefail would report a false failure
  local sc_list
  sc_list="$(kubectl get storageclass 2>/dev/null || true)"
  if echo "$sc_list" | grep -q '(default)'; then
    ok "default StorageClass: $(echo "$sc_list" | awk '/\(default\)/{print $1}')"
  else
    warn "no default StorageClass found - vault/db volumes may stay Pending"
  fi
}

build_dependencies() {
  # only needed for dependencies downloaded from a repository (local ./charts need nothing)
  if grep -q '^\s*repository:' "$CHART/Chart.yaml" 2>/dev/null; then
    log "Building chart dependencies"
    helm dependency build "$CHART" >/dev/null
    ok "dependencies ready"
  fi
}

# A first install that failed cannot be upgraded cleanly. Remove the failed
# release first. Data is safe: PVCs and the vault-keys / vault-token Secrets
# are not managed by Helm and are kept.
handle_failed_release() {
  local st rev
  # "|| true": no release yet -> helm status fails; must not stop the script (set -e + pipefail)
  st="$(helm status "$RELEASE" -n "$NAMESPACE" 2>/dev/null | awk '/^STATUS:/{print $2}' || true)"
  rev="$(helm status "$RELEASE" -n "$NAMESPACE" 2>/dev/null | awk '/^REVISION:/{print $2}' || true)"
  [[ -z "$st" ]] && return 0
  case "$st" in
    failed)
      if [[ "$rev" == "1" ]]; then
        warn "previous first install of '$RELEASE' failed - removing it before reinstalling"
        warn "kept: PVCs (db, vault data) and Secrets vault-keys, vault-token"
        helm uninstall "$RELEASE" -n "$NAMESPACE" --wait >/dev/null
        ok "failed release removed"
      fi
      ;;
    pending-install|pending-upgrade|pending-rollback)
      die "release '$RELEASE' is stuck in '$st'. If no install is running, run: helm uninstall $RELEASE -n $NAMESPACE   (data is kept)"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Chart selection: all, single charts, or groups
# -----------------------------------------------------------------------------
ALL_CHARTS="vault db identity-service credential-schema-service credentials-service oid4vc-service nginx"

# group name -> charts
expand_group() {
  case "$1" in
    all)      echo "$ALL_CHARTS" ;;
    core)     echo "vault db identity-service" ;;
    services) echo "identity-service credential-schema-service credentials-service oid4vc-service" ;;
    infra)    echo "vault db" ;;
    public)   echo "nginx" ;;
    *)        echo "$1" ;;
  esac
}

in_list() { [[ " $2 " == *" $1 "* ]]; }

# charts currently deployed in the release (from its manifest)
deployed_charts() {
  helm get manifest "$RELEASE" -n "$NAMESPACE" 2>/dev/null \
    | sed -n 's|^# Source: [^/]*/charts/\([^/]*\)/.*|\1|p' | sort -u | tr '\n' ' ' || true
}

# select_charts <mode: install|remove> [chart|group ...]
# Sets <chart>.enabled for EVERY chart so the result is explicit:
#   install: selected charts on, already-deployed charts stay on, rest off
#   remove : selected charts off, other deployed charts stay on
select_charts() {
  local mode="$1"; shift
  local selected="" item c deployed
  if [[ $# -eq 0 ]]; then
    [[ "$mode" == "remove" ]] && die "say which chart(s) to remove, e.g. ./install.sh remove oid4vc-service"
    selected="$ALL_CHARTS"
  else
    for item in "$@"; do
      for c in $(expand_group "$item"); do
        in_list "$c" "$ALL_CHARTS" || die "unknown chart or group '$c'. Charts: $ALL_CHARTS. Groups: all core services infra public"
        selected="$selected $c"
      done
    done
  fi
  deployed="$(deployed_charts)"

  log "Charts ($mode)"
  for c in $ALL_CHARTS; do
    local on=false
    if [[ "$mode" == "install" ]]; then
      { in_list "$c" "$selected" || in_list "$c" "$deployed"; } && on=true
    else
      in_list "$c" "$selected" || { in_list "$c" "$deployed" && on=true; }
    fi
    EXTRA_VALUES+=(--set "${c}.enabled=${on}")
    if [[ "$on" == true ]]; then ok "$c"; else echo "    - $c (off)"; fi
  done
}

values_args() {
  echo -f "$SCRIPT_DIR/images.yaml" -f "$SCRIPT_DIR/global-resources.yaml" -f "$VALUES_FILE"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
cmd_template() {
  check_tools; check_files; prepare_password; build_dependencies
  select_charts install "$@"
  log "Linting chart"
  # shellcheck disable=SC2046
  helm lint "$CHART" $(values_args) ${EXTRA_VALUES[@]+"${EXTRA_VALUES[@]}"}
  local out="$SCRIPT_DIR/rendered.yaml"
  log "Rendering manifests -> $out"
  # shellcheck disable=SC2046
  helm template "$RELEASE" "$CHART" -n "$NAMESPACE" $(values_args) ${EXTRA_VALUES[@]+"${EXTRA_VALUES[@]}"} > "$out"
  ok "rendered $(grep -c '^kind:' "$out") resources (contains secrets - do not commit rendered.yaml)"
}

cmd_install() {
  check_tools; check_files; prepare_password; check_cluster; build_dependencies

  handle_failed_release
  select_charts install "$@"

  log "Installing release '$RELEASE' in namespace '$NAMESPACE' (timeout $TIMEOUT)"
  log "This also runs the vault-setup Job (init, unseal, kv, token -> Secret vault-token)"
  # shellcheck disable=SC2046
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NAMESPACE" --create-namespace \
    $(values_args) ${EXTRA_VALUES[@]+"${EXTRA_VALUES[@]}"} \
    --timeout "$TIMEOUT"

  ok "helm release applied"
  wait_for_rollout
  cmd_status
}

# wait until new pods of every deployment / statefulset are ready
wait_for_rollout() {
  log "Waiting for pods to roll out (max 5 min each)"
  local r
  for r in $(kubectl get deploy,statefulset -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE" -o name 2>/dev/null); do
    if kubectl rollout status "$r" -n "$NAMESPACE" --timeout=300s >/dev/null 2>&1; then
      ok "${r#*/} ready"
    else
      warn "${r#*/} not ready yet (check: kubectl get pods -n $NAMESPACE)"
    fi
  done
}

cmd_status() {
  log "Pods in $NAMESPACE"
  kubectl get pods -n "$NAMESPACE" -o wide || true

  log "Vault seal status"
  kubectl exec -n "$NAMESPACE" vault-0 -c vault -- vault status 2>/dev/null \
    | grep -E 'Initialized|Sealed' || warn "vault-0 not reachable yet"

  log "Vault keys secret"
  if kubectl get secret vault-keys -n "$NAMESPACE" >/dev/null 2>&1; then
    ok "vault-keys exists (BACK IT UP - needed to unseal vault)"
  else
    warn "vault-keys not created yet (check: kubectl logs job/vault-setup -n $NAMESPACE --all-containers)"
  fi

  log "Public entry point (nginx)"
  local ip
  ip="$(kubectl get svc "${RELEASE}-nginx" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    ok "EXTERNAL-IP $ip  -> point DNS for the host in global-values.yaml to this IP"
    echo "  test: curl http://$ip/identity-service/health"
  else
    warn "no external IP yet (nginx disabled, or Azure still assigning - check again in a minute)"
  fi

  log "Service endpoints (cluster-internal)"
  echo "  http://${RELEASE}-identity-service.${NAMESPACE}:3332"
  echo "  http://${RELEASE}-credential-schema-service.${NAMESPACE}:3333"
  echo "  http://${RELEASE}-credentials-service.${NAMESPACE}:3000"
  echo "  http://${RELEASE}-oid4vc-service.${NAMESPACE}:3400"
}

# -----------------------------------------------------------------------------
# API tests: runs tests/adopter-testing.postman_collection.json with Newman
#   ./install.sh test [all|core|identity|schema|credentials|oid4vc]
#   BASE_URL   default http://<global.host>
#   COLLECTION default tests/adopter-testing.postman_collection.json (see tests/README.md)
# -----------------------------------------------------------------------------
cmd_test() {
  local set="${1:-all}"
  local host base results collection stamp code fail=0 svc
  host="$(awk '/^global:/{g=1} g && /^  host:/{gsub(/"/,"",$2); print $2; exit}' "$VALUES_FILE" 2>/dev/null || true)"
  base="${BASE_URL:-http://${host:-dev.sunbirded.org}}"; base="${base%/}"
  results="$SCRIPT_DIR/test-results"
  collection="${COLLECTION:-$SCRIPT_DIR/tests/adopter-testing.postman_collection.json}"
  mkdir -p "$results"

  local f_id="0. Identity Service - CRUD & Utils"
  local f_schema="1. Credential Schema - CRUD"
  local f_creds="2. Credentials Service - CRUD"
  local f_oid="3. OID4VC Service"
  local folders=()
  # later folders use ids created by earlier ones, so dependencies are included
  case "$set" in
    all)         folders=("$f_id" "$f_schema" "$f_creds" "$f_oid") ;;
    core)        folders=("$f_id" "$f_schema" "$f_creds") ;;
    identity)    folders=("$f_id") ;;
    schema)      folders=("$f_id" "$f_schema") ;;
    credentials) folders=("$f_id" "$f_schema" "$f_creds") ;;
    oid4vc)      folders=("$f_oid") ;;
    *) die "unknown test set '$set' (all | core | identity | schema | credentials | oid4vc)" ;;
  esac

  log "Checking tools"
  command -v npx >/dev/null 2>&1 || die "node/npx not installed (brew install node)"
  ok "node $(node --version)"

  log "Checking services at $base"
  for svc in identity-service credential-schema-service credentials-service oid4vc-service; do
    code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$base/$svc/health" || true)"
    if [[ "$code" == "200" ]]; then ok "$svc /health 200"; else warn "$svc /health $code"; fail=1; fi
  done
  [[ $fail -eq 0 ]] || die "some services are not healthy - check: ./install.sh status"

  [[ -f "$collection" ]] || die "test collection not found: $collection"
  ok "collection $(basename "$collection")"

  local folder_args=() f
  for f in "${folders[@]}"; do folder_args+=(--folder "$f"); done
  stamp="$(date +%Y%m%d-%H%M%S)"

  log "Running tests ($set) - first run downloads newman, may take a minute"
  for f in "${folders[@]}"; do echo "    - $f"; done

  local rc=0
  npx -y newman@6 run "$collection" \
    "${folder_args[@]}" \
    --env-var "identity_base=$base/identity-service" \
    --env-var "schema_base=$base/credential-schema-service" \
    --env-var "credential_base=$base/credentials-service" \
    --env-var "oid4vc_base=$base/oid4vc-service" \
    --timeout-request 60000 \
    --reporters cli,json,junit \
    --reporter-json-export "$results/result-$stamp.json" \
    --reporter-junit-export "$results/result-$stamp.xml" || rc=$?

  echo
  if [[ $rc -eq 0 ]]; then
    echo -e "\033[1;32mALL TESTS PASSED\033[0m"
  else
    echo -e "\033[1;31mSOME TESTS FAILED\033[0m (see the table above)"
  fi
  echo "  Reports: $results/result-$stamp.json / .xml"
  return $rc
}

# remove only some charts from the release (others keep running)
cmd_remove() {
  check_tools; check_files; prepare_password; check_cluster; build_dependencies
  helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 || die "release '$RELEASE' is not installed"
  select_charts remove "$@"
  log "Updating release '$RELEASE' (removing selected charts)"
  # shellcheck disable=SC2046
  helm upgrade "$RELEASE" "$CHART" --namespace "$NAMESPACE" \
    $(values_args) ${EXTRA_VALUES[@]+"${EXTRA_VALUES[@]}"} --timeout "$TIMEOUT"
  ok "done (volumes of vault/db are kept if those were removed)"
  cmd_status
}

cmd_uninstall() {
  check_tools
  log "Uninstalling release '$RELEASE' from '$NAMESPACE'"
  helm uninstall "$RELEASE" -n "$NAMESPACE"
  warn "Kept on purpose: PVCs (data-vault-0, data-db-0) and Secrets vault-keys, vault-token."
  warn "Deleting them PERMANENTLY destroys all data and vault keys:"
  echo "    kubectl delete pvc data-vault-0 data-db-0 -n $NAMESPACE"
  echo "    kubectl delete secret vault-keys vault-token -n $NAMESPACE"
}

usage() {
  # print the header comment block
  awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
}

CMD="${1:-}"; [[ $# -gt 0 ]] && shift
case "$CMD" in
  install)   cmd_install "$@" ;;
  template)  cmd_template "$@" ;;
  remove)    cmd_remove "$@" ;;
  test)      cmd_test "$@" ;;
  status)    check_tools; cmd_status ;;
  uninstall) cmd_uninstall ;;
  *)         usage; exit 1 ;;
esac
