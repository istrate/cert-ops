#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

log_info() {
  echo -e "\033[32m[INFO] $1\033[0m"
}

log_error() {
  echo -e "\033[31m[ERROR] $1\033[0m"
}
# ==========================================
# CONFIGURATION
# ==========================================
# Set your Instance ID and Workspace ID here, or pass them as environment variables
INSTANCE_ID="${INSTANCE_ID:-dev}"
WORKSPACE_ID="${WORKSPACE_ID:-dev}"

# Path to the directory containing your certificate files
CERT_DIR="$(pwd)"

# Target Namespace for MAS Core
NAMESPACE="mas-${INSTANCE_ID}-core"

# Secret Names based on MAS naming conventions
SECRET_CORE="${INSTANCE_ID}-cert-public"
SECRET_WORKSPACE="${INSTANCE_ID}-${WORKSPACE_ID}-cert-public-81"

# Certificate File Paths
TLS_CRT="${CERT_DIR}/tls.crt"
TLS_KEY="${CERT_DIR}/tls.key"
CA_CRT="${CERT_DIR}/ca.crt"

# ==========================================
# VALIDATION
# ==========================================
log_info"==> Validating certificate files in '${CERT_DIR}'..."
ls -al
for file in "$TLS_CRT" "$TLS_KEY" "$CA_CRT"; do
  if [ ! -f "$file" ]; then
    log_error "Error: Required file '$file' not found!" >&2
    exit 1
  fi
done

log_info "==> Target Namespace: $NAMESPACE"
log_info"==> Instance ID: $INSTANCE_ID"
log_info "==> Workspace ID: $WORKSPACE_ID"
log_info ""

# ==========================================
# UPDATE EXISTING SECRETS USING oc set data
# ==========================================

# 1. Update Core Public Certificate Secret
log_info "==> Updating existing core secret: $SECRET_CORE in namespace $NAMESPACE..."
oc set data secret/"$SECRET_CORE" \
  --namespace="$NAMESPACE" \
  --from-file=tls.crt="$TLS_CRT" \
  --from-file=tls.key="$TLS_KEY" \
  --from-file=ca.crt="$CA_CRT"

# 2. Update Workspace Public Certificate Secret
log_info "==> Updating existing workspace secret: $SECRET_WORKSPACE in namespace $NAMESPACE..."
oc set data secret/"$SECRET_WORKSPACE" \
  --namespace="$NAMESPACE" \
  --from-file=tls.crt="$TLS_CRT" \
  --from-file=tls.key="$TLS_KEY" \
  --from-file=ca.crt="$CA_CRT"

log_info ""
log_info "Successfully updated both existing secrets with tls.crt, tls.key, and ca.crt!"
