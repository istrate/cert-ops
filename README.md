[![certmg-github-actions](https://github.com/istrate/cert-ops/actions/workflows/certmg-github-actions.yml/badge.svg?event=push)](https://github.com/istrate/cert-ops/actions/workflows/certmg-github-actions.yml)
# cert-ops

## 1. What the project does

cert-ops automates TLS certificate rotation for an IBM Maximo Application Suite (MAS) deployment on OpenShift. The OpenShift cluster is an IBM TechZone instance. On every push to GitHub, a pipeline does four things:

1. It generates a new CA and a new wildcard server certificate.
2. It logs in to the OpenShift cluster.
3. It overwrites the MAS public-certificate secrets with the new material.
4. It checks over TLS that the MAS endpoints now serve the new certificate.

## 2. Repository layout

```
cert-ops/
├── README.md                         # This guide + workflow status badge
├── .github/workflows/
│   ├── certmg-github-actions.yml     # The CI/CD pipeline (orchestrator)
│   └── README.md                     # Placeholder: "cert-management flow"
├── certs/
│   ├── certificate.conf              # OpenSSL config (DN, SAN, key usage)
│   └── README.md                     # Placeholder: output directory for generated certs
└── scripts/
    ├── gen_cert.sh                   # Step 1: generate CA + TLS cert
    ├── update_cert.sh                # Step 2: push certs into OpenShift secrets
    └── test_cert.sh                  # Step 3: verify endpoints serve new cert
```

The design separates three concerns:

- **Configuration** is in `certs/`.
- **Logic** is in `scripts/`.
- **Orchestration** is in `.github/workflows/`.

The scripts are plain Bash, so you can run them locally or from any other CI system.

## 3. Flow overview

```mermaid
flowchart LR
  A[git push] --> B[GitHub Actions runner]
  B --> C[Install oc + login<br/>OPENSHIFT_SERVER/TOKEN]
  C --> D[gen_cert.sh<br/>CA, key, CSR, signed cert]
  D --> E[update_cert.sh<br/>oc set data on 2 secrets]
  E --> F[MAS core + Manage routes<br/>pick up new cert]
  F --> G[test_cert.sh<br/>openssl s_client check]
```

## 4. Step-by-step implementation

### Step 1 – Create the repo and CI badge

- Create the GitHub repo `istrate/cert-ops` and add this `README.md` with the Actions status badge.
- The badge points at the `certmg-github-actions.yml` workflow and filters on `event=push`.

### Step 2 – Define the certificate template ([`certs/certificate.conf`](certs/certificate.conf))

This is an OpenSSL request config. It has four sections:

| Section | Purpose |
|---|---|
| `[ req ]` | Sets a 2048-bit key and `prompt = no`, so no interactive questions. It also points at the DN and extension sections. |
| `[ req_distinguished_name ]` | Subject: C=RO, ST=Bucuresti, L=Sector 5, O=Home, OU=Lab, and CN=`*.apps.itz-83pcr7.hub04-lb.techzone.ibm.com`. |
| `[ v3_req ]` | `CA:FALSE`, key usage (`digitalSignature`, `keyEncipherment`, `nonRepudiation`), EKU `serverAuth`, and a SAN reference. |
| `[ alt_names ]` | SANs for `*.apps.<cluster-domain>` and `apps.<cluster-domain>`. |

The SAN list is essential because modern clients ignore the CN. The wildcard covers every MAS route, such as `api.dev.apps…` and `dev.manage.dev.apps…`. The bare domain is added separately, since a wildcard does not match it.

### Step 3 – Write the generator ([`scripts/gen_cert.sh`](scripts/gen_cert.sh))

The script runs these steps:

1. It defines a green `log_info` helper and prints `openssl version` as a sanity check.
2. **CA.** `openssl genrsa -out ca.key 2048`, then `openssl req -x509 -new -nodes … -days 365 -out ca.crt`. This produces a self-signed CA.
3. **Server key and CSR.** `genrsa -out tls.key 2048`, then `req -new -key tls.key -out tls.csr -config certificate.conf`.
4. **Signing.** `openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out tls.crt -days 365 -sha256 -extfile certificate.conf -extensions v3_req`. The `-extfile` and `-extensions` options carry the SAN and key usage into the final cert. Without them, `x509 -req` drops the CSR extensions.
5. It prints the cert with `openssl x509 -text -noout` so the details appear in the CI log.

The outputs are `ca.key`, `ca.crt`, `tls.key`, `tls.csr`, `tls.crt` and `ca.srl`. They land in the current directory, which is `certs/` because the workflow sets `working-directory`.

### Step 4 – Write the cluster updater ([`scripts/update_cert.sh`](scripts/update_cert.sh))

The script uses `set -e`, so it stops on the first error. Its steps:

1. **Parameterise MAS naming conventions** with environment-variable defaults:
   - `INSTANCE_ID` (default `dev`) and `WORKSPACE_ID` (default `dev`).
   - Namespaces: `mas-<instance>-core` and `mas-<instance>-manage`.
   - Secrets: `<instance>-cert-public` (core) and `<instance>-<workspace>-cert-public-81` (Manage workspace).
2. **Validate** that `tls.crt`, `tls.key` and `ca.crt` exist in the working directory. It exits with an error if any is missing.
3. **Update the two existing secrets** in place:
   ```
   oc set data secret/<name> -n <ns> \
     --from-file=tls.crt=… --from-file=tls.key=… --from-file=ca.crt=…
   ```
   It updates the secrets rather than recreating them, so ownership, labels and annotations that MAS relies on are preserved.

### Step 5 – Write the verifier ([`scripts/test_cert.sh`](scripts/test_cert.sh))

The script also uses `set -e`. Its steps:

1. It builds the target URLs from the MAS convention:
   - Manage: `https://<ws>.manage.<inst>.<CN>`
   - Core API: `https://api.<inst>.<CN>`
2. `extract_host` pulls the hostname from each URL with `awk -F/`.
3. `test_endpoint_ssl` runs `echo | openssl s_client -connect host:443 -servername host`. This is a real TLS handshake with SNI.
4. If the output contains `BEGIN CERTIFICATE`, it prints the subject, issuer and validity dates and reports PASSED. Otherwise it logs an error and returns 1, which fails the CI job.
5. Chain validation errors are deliberately ignored (`|| true`). The CA is private, so the test only proves that a certificate is served.

### Step 6 – Wire it together in GitHub Actions ([`certmg-github-actions.yml`](.github/workflows/certmg-github-actions.yml))

- **Trigger:** `on: [push]`.
- **Runner:** `ubuntu-latest`, with `defaults.run.working-directory: ./certs`. This is why the scripts use relative file names and are called as `../scripts/…`.
- **Steps:**
  1. `actions/checkout@v6`.
  2. `redhat-actions/oc-installer@v1` installs the `oc` CLI (`latest`, or pin a version such as 4.20).
  3. `oc login --server=$OPENSHIFT_SERVER --token=$OPENSHIFT_TOKEN`.
  4. `chmod +x ../scripts/gen_cert.sh && ../scripts/gen_cert.sh`.
  5. The same pattern for `update_cert.sh`.
  6. The same pattern for `test_cert.sh`.

### Step 7 – Configure GitHub secrets and cluster access (prerequisites)

> **Note:** To get the service token without doing the cluster setup by hand, log in with `oc` as a cluster-admin and run [`scripts/get_sa_token.sh`](scripts/get_sa_token.sh). It creates the ServiceAccount and the Roles, then prints the long-lived token. Use the printed token as the `OPENSHIFT_TOKEN` secret. See [`scripts/README.md`](scripts/README.md) for usage and options.
>
> ```bash
> OPENSHIFT_TOKEN=$(./scripts/get_sa_token.sh)
> ```

1. In the repo, go to *Settings → Secrets and variables → Actions* and add:
   - `OPENSHIFT_SERVER`, the API URL such as `https://api.<cluster>:6443`.
   - `OPENSHIFT_TOKEN`, a token for a ServiceAccount or user.
2. On the cluster, create a ServiceAccount whose Role or RoleBinding allows `get`, `patch` and `update` on secrets. This must cover `mas-<inst>-core` and `mas-<inst>-manage`. Use its token instead of a personal `oc whoami -t` token, which expires.
3. The target secrets must already exist. `oc set data` fails if they don't.
4. Update the CN and SANs in `certificate.conf`, the CN in `gen_cert.sh`, and the default `CN` in `test_cert.sh` if you point this at a different cluster.

### Step 8 – Run and observe

1. Push a commit. The workflow runs and the README badge shows pass or fail.
2. Read the logs. They print the OpenSSL text dump, `Successfully updated both existing secrets…`, and the per-endpoint PASSED lines.

## 5. Known issues and suggested improvements

| Area | Observation | Recommendation |
|---|---|---|
| Trigger | `on: [push]` rotates production certs on every push, including doc edits. | Use `workflow_dispatch` plus a `schedule` cron (e.g. every 60 days), or filter on `paths:`. |
| Secrets handling | The CA key and server key are created on the runner and never uploaded. This is good, but a new CA is made on each run, so clients that trusted the old CA break. | Keep a persistent CA in a secret store (Vault or GitHub Secrets) and issue only leaf certs. Alternatively, use cert-manager or a real CA. |
| `gen_cert.sh` | There is no `set -e`, so a failed `openssl` call doesn't stop the script. The CA subject is a wildcard CN with no CA extensions. | Add `set -euo pipefail`. Give the CA a proper CN and `basicConstraints=CA:TRUE`. |
| `update_cert.sh` | `CERT_DIR` is defined with a hardcoded runner path but never used. | Remove it, or use it. |
| Timing | The test runs right after the update, but routes and pods may need time to reload. | Add `oc rollout status` or a retry loop in `test_cert.sh`. |
| `test_cert.sh` | It only checks that a certificate is served. It doesn't compare it to the newly generated one. | Compare fingerprints (`openssl x509 -fingerprint`) with `tls.crt`. |
| Config duplication | The cluster domain appears in three files. | Move it to one variable (workflow `env:` or a GitHub variable). |
| Docs and typos | Both sub-READMEs are one-line placeholders, and the workflow `run-name` says "certifcate". | Document the flow, prerequisites and secrets. Fix the typo. |
| Validity | Certificates last 365 days with no expiry monitoring. | Add a scheduled expiry check. |
| `oc login` | There is no `--insecure-skip-tls-verify` option or CA handling. Self-signed API certs will fail. | Add it only if the cluster needs it. |
