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

  # Fetch the certificate presented by the server via TLS handshake
  local cert_output
  cert_output=$(echo | openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null || true)

  if echo "$cert_output" | grep -q "BEGIN CERTIFICATE"; then
    log_info "Successfully established TLS connection and retrieved certificate for $host"
    
    # Extract and log certificate details (ignoring strict root CA validation errors)
    local subject issuer dates
    subject=$(echo "$cert_output" | openssl x509 -noout -subject 2>/dev/null || echo "subject=N/A")
    issuer=$(echo "$cert_output" | openssl x509 -noout -issuer 2>/dev/null || echo "issuer=N/A")
    dates=$(echo "$cert_output" | openssl x509 -noout -dates 2>/dev/null || echo "dates=N/A")
    
    log_info "  $subject"
    log_info "  $issuer"
    log_info "  $dates"
    log_info "TLS check PASSED for $host."
  else
    log_error "Failed to establish TLS connection or retrieve certificate from $host"
    return 1
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
