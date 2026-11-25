#!/usr/bin/env bash
# =============================================================================
# Sunbird RC Credentialling - Helm v2 installer
#
# Usage:
#   export DB_PASSWORD='<strong-password>'      # or set global.db.password in global-values.yaml
#   ./install.sh install        # check + deploy everything (vault, db, identity, schema, credentials, oid4vc)
#   ./install.sh template       # render manifests only (dry run), no cluster changes
#   ./install.sh status         # pods, vault-setup job, vault seal status
#   ./install.sh uninstall      # remove release (volumes + vault-keys secret are kept)
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

  if ! kubectl get storageclass 2>/dev/null | grep -q '(default)'; then
    warn "no default StorageClass found - vault/db volumes may stay Pending"
  fi
}

build_dependencies() {
  if grep -q '^dependencies:' "$CHART/Chart.yaml" 2>/dev/null; then
    log "Building chart dependencies"
    helm dependency build "$CHART" >/dev/null
    ok "dependencies ready"
  fi
}

values_args() {
  echo -f "$SCRIPT_DIR/images.yaml" -f "$SCRIPT_DIR/global-resources.yaml" -f "$VALUES_FILE"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
cmd_template() {
  check_tools; check_files; prepare_password; build_dependencies
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

  log "Installing release '$RELEASE' in namespace '$NAMESPACE' (timeout $TIMEOUT)"
  log "This also runs the vault-setup Job (init, unseal, kv, token -> rc-secret)"
  # shellcheck disable=SC2046
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NAMESPACE" --create-namespace \
    $(values_args) ${EXTRA_VALUES[@]+"${EXTRA_VALUES[@]}"} \
    --timeout "$TIMEOUT"

  ok "helm release applied"
  cmd_status
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

  log "Service endpoints (cluster-internal)"
  echo "  http://${RELEASE}-identity-service.${NAMESPACE}:3332"
  echo "  http://${RELEASE}-credential-schema-service.${NAMESPACE}:3333"
  echo "  http://${RELEASE}-credentials-service.${NAMESPACE}:3000"
  echo "  http://${RELEASE}-oid4vc-service.${NAMESPACE}:3400"
}

cmd_uninstall() {
  check_tools
  log "Uninstalling release '$RELEASE' from '$NAMESPACE'"
  helm uninstall "$RELEASE" -n "$NAMESPACE"
  warn "Kept on purpose: PVCs (data-vault-0, data-db-0) and Secret vault-keys."
  warn "Deleting them PERMANENTLY destroys all data and vault keys:"
  echo "    kubectl delete pvc data-vault-0 data-db-0 -n $NAMESPACE"
  echo "    kubectl delete secret vault-keys -n $NAMESPACE"
}

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  install)   cmd_install ;;
  template)  cmd_template ;;
  status)    check_tools; cmd_status ;;
  uninstall) cmd_uninstall ;;
  *)         usage; exit 1 ;;
esac
