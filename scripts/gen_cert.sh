#!/bin/bash

# Define a reusable logging function for green messages
log_info() {
  echo -e "\033[32m[INFO] $1\033[0m"
}
          
# Check if openssl is installed
log_info "Checking if OpenSSL is installed..."
openssl version

# Generate the CA private key and certificate
log_info "Generating CA private key and certificate..."
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 -out ca.crt -subj "/CN=*.apps.itz-83pcr7.hub04-lb.techzone.ibm.com"
     
# Generate the TLS private key and CSR using certificate.conf
log_info "Generating TLS private key and CSR..."
openssl genrsa -out tls.key 2048
openssl req -new -key tls.key -out tls.csr -config certificate.conf
         
# Sign the TLS certificate with ca.crt
log_info "Signing the TLS certificate with the CA..."
openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out tls.crt -days 365 -sha256 -extfile certificate.conf -extensions v3_req
         
# View the certificate to verify it
log_info "Viewing the generated TLS certificate for verification..."
cat tls.crt | openssl x509 -text -noout
