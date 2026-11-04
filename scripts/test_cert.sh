#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

log_info() {
  echo -e "\033[32m[INFO] $1\033[0m"
}

log_error() {
  echo -e "\033[31m[ERROR] $1\033[0m"
}

log_warn() {
  echo -e "\033[33m[WARN] $1\033[0m"
}

# ==========================================
# CONFIGURATION
# ==========================================
INSTANCE_ID="${INSTANCE_ID:-dev}"
WORKSPACE_ID="${WORKSPACE_ID:-dev}"
CN="${CN:-apps.itz-83pcr7.hub04-lb.techzone.ibm.com}"

# Path to the CA certificate for verification
CA_CRT="${CA_CRT:-/home/runner/work/cert-ops/cert-ops/certs/ca.crt}"

# Target URLs based on your MAS convention
MANAGE_URL="https://${WORKSPACE_ID}.manage.${INSTANCE_ID}.${CN}"
CORE_API_URL="https://api.${INSTANCE_ID}.${CN}"

# Extract hostname/port from URLs for openssl
extract_host() {
  echo "$1" | awk -F/ '{print $3}'
}

test_endpoint_ssl() {
  local url="$1"
  local host
  host=$(extract_host "$url")
  
  log_info "==> Testing TLS certificate for: $url (Host: $host)..."

  if [ ! -f "$CA_CRT" ]; then
    log_warn "CA file not found at $CA_CRT. Performing basic connectivity and handshake check only..."
    # Basic handshake check without CA verification
    if echo | openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null | openssl x509 -noout -dates; then
      log_info "Successfully retrieved certificate for $host"
    else
      log_error "Failed to establish TLS connection to $host"
      return 1
    fi
  else
    log_info "Validating certificate chain against CA: $CA_CRT..."
    if openssl s_client -connect "${host}:443" -servername "$host" -CAfile "$CA_CRT" -brief </dev/null 2>&1 | grep -q "Verification: OK"; then
      log_info "Certificate verification PASSED for $host against CA."
    else
      log_warn "Certificate verification returned issues for $host. Inspecting details..."
      openssl s_client -connect "${host}:443" -servername "$host" -CAfile "$CA_CRT" </dev/null 2>&1 | grep -E "Verify return code|subject=|issuer="
      return 1
    fi
  fi
}

# ==========================================
# EXECUTION
# ==========================================
log_info "Starting certificate validation checks..."
log_info "Instance ID: $INSTANCE_ID"
log_info "Workspace ID: $WORKSPACE_ID"
log_info "Base CN: $CN"
log_info ""

# Test Core API URL
if [ -n "$CORE_API_URL" ]; then
  test_endpoint_ssl "$CORE_API_URL"
  log_info ""
fi

# Test Manage URL
if [ -n "$MANAGE_URL" ]; then
  test_endpoint_ssl "$MANAGE_URL"
  log_info ""
fi

log_info "All endpoint certificate checks completed successfully!"
