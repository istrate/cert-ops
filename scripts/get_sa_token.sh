#!/bin/bash
#
# Creates (idempotently) a least-privilege ServiceAccount for cert-ops and
# prints its long-lived token to stdout.
#
# All log messages go to stderr, so the token can be captured safely:
#   OPENSHIFT_TOKEN=$(./get_sa_token.sh)
#
# Prerequisite: `oc` is logged in as a user allowed to create namespaces,
# ServiceAccounts, Roles and RoleBindings (e.g. cluster-admin).
#
# For the Tekton pipeline (runs inside the cluster, no token needed), grant the
# `pipeline` ServiceAccount of the namespace that runs the PipelineRuns the
# same least-privilege RBAC and skip the token:
#   SA_NS=cert-ops SA_NAME=pipeline CREATE_TOKEN=false ./get_sa_token.sh

set -euo pipefail

log_info() {
  echo -e "\033[32m[INFO] $1\033[0m" >&2
}

log_error() {
  echo -e "\033[31m[ERROR] $1\033[0m" >&2
}

# ==========================================
# CONFIGURATION (override with environment variables)
# ==========================================
INSTANCE_ID="${INSTANCE_ID:-dev}"
WORKSPACE_ID="${WORKSPACE_ID:-dev}"

SA_NS="${SA_NS:-cert-ops}"
SA_NAME="${SA_NAME:-cert-ops-sa}"
TOKEN_SECRET="${SA_NAME}-token"
ROLE_NAME="cert-ops-secret-updater"

# Same naming conventions as update_cert.sh
CORE_NS="mas-${INSTANCE_ID}-core"
MANAGE_NS="mas-${INSTANCE_ID}-manage"
CORE_SECRET="${INSTANCE_ID}-cert-public"
WS_SECRET="${INSTANCE_ID}-${WORKSPACE_ID}-cert-public-81"

WAIT_SECONDS="${WAIT_SECONDS:-30}"

# Set to "false" to only create the ServiceAccount and RBAC (no token secret)
CREATE_TOKEN="${CREATE_TOKEN:-true}"

# ==========================================
# VALIDATION
# ==========================================
if ! command -v oc >/dev/null 2>&1; then
  log_error "'oc' CLI not found in PATH"
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  log_error "Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

log_info "==> Logged in as: $(oc whoami)"
log_info "==> Server: $(oc whoami --show-server)"

log_info "==> Checking that the target secrets exist..."
oc get secret "$CORE_SECRET" -n "$CORE_NS" >/dev/null
oc get secret "$WS_SECRET" -n "$MANAGE_NS" >/dev/null

# ==========================================
# NAMESPACE AND SERVICE ACCOUNT
# ==========================================
if oc get namespace "$SA_NS" >/dev/null 2>&1; then
  log_info "==> Namespace $SA_NS already exists"
else
  log_info "==> Creating namespace $SA_NS..."
  oc create namespace "$SA_NS" >&2
fi

if oc get serviceaccount "$SA_NAME" -n "$SA_NS" >/dev/null 2>&1; then
  log_info "==> ServiceAccount $SA_NAME already exists"
else
  log_info "==> Creating ServiceAccount $SA_NAME in $SA_NS..."
  oc create serviceaccount "$SA_NAME" -n "$SA_NS" >&2
fi

# ==========================================
# RBAC: restricted to the two secrets updated by update_cert.sh
# ==========================================
log_info "==> Applying Roles and RoleBindings..."
cat <<EOF | oc apply -f - >&2
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}
  namespace: ${CORE_NS}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["${CORE_SECRET}"]
  verbs: ["get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${ROLE_NAME}
  namespace: ${CORE_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${ROLE_NAME}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${SA_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}
  namespace: ${MANAGE_NS}
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["${WS_SECRET}"]
  verbs: ["get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${ROLE_NAME}
  namespace: ${MANAGE_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${ROLE_NAME}
subjects:
- kind: ServiceAccount
  name: ${SA_NAME}
  namespace: ${SA_NS}
EOF

# ==========================================
# VERIFY PERMISSIONS
# ==========================================
SA_USER="system:serviceaccount:${SA_NS}:${SA_NAME}"
log_info "==> Verifying permissions of $SA_USER..."

if [ "$(oc auth can-i patch "secret/${CORE_SECRET}" -n "$CORE_NS" --as="$SA_USER")" != "yes" ] ||
   [ "$(oc auth can-i patch "secret/${WS_SECRET}" -n "$MANAGE_NS" --as="$SA_USER")" != "yes" ]; then
  log_error "ServiceAccount cannot patch the target secrets"
  exit 1
fi

if [ "$CREATE_TOKEN" = "false" ]; then
  log_info "==> CREATE_TOKEN=false: ServiceAccount $SA_USER is ready, no token created."
  exit 0
fi

# ==========================================
# LONG-LIVED TOKEN SECRET
# ==========================================
if oc get secret "$TOKEN_SECRET" -n "$SA_NS" >/dev/null 2>&1; then
  log_info "==> Token secret $TOKEN_SECRET already exists"
else
  log_info "==> Creating token secret $TOKEN_SECRET..."
  cat <<EOF | oc apply -f - >&2
apiVersion: v1
kind: Secret
metadata:
  name: ${TOKEN_SECRET}
  namespace: ${SA_NS}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF
fi

# The token controller populates the secret asynchronously
log_info "==> Waiting up to ${WAIT_SECONDS}s for the token to be populated..."
TOKEN=""
for ((i = 0; i < WAIT_SECONDS; i++)); do
  TOKEN=$(oc get secret "$TOKEN_SECRET" -n "$SA_NS" \
    -o go-template='{{if .data.token}}{{.data.token | base64decode}}{{end}}')
  if [ -n "$TOKEN" ]; then
    break
  fi
  sleep 1
done

if [ -z "$TOKEN" ]; then
  log_error "Token was not populated in secret $TOKEN_SECRET after ${WAIT_SECONDS}s"
  exit 1
fi

log_info "==> Token retrieved. Use it as the OPENSHIFT_TOKEN GitHub secret."
log_info "==> OPENSHIFT_SERVER value: $(oc whoami --show-server)"

# Only the token goes to stdout
echo "$TOKEN"
