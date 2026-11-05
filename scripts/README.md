# scripts

| Script | Purpose |
|---|---|
| `gen_cert.sh` | Generates the CA and the wildcard TLS certificate in `certs/`. |
| `update_cert.sh` | Updates the MAS core and Manage public-certificate secrets with `oc set data`. |
| `test_cert.sh` | Checks over TLS that the MAS endpoints serve a certificate. |
| `get_sa_token.sh` | Creates the least-privilege ServiceAccount used by the pipeline and prints its long-lived token. |

## get_sa_token.sh

The pipeline logs in with `oc login --token=$OPENSHIFT_TOKEN`. This script creates a ServiceAccount that can update only the two secrets that `update_cert.sh` changes, and returns a token that doesn't expire.

### What it does

1. Checks that `oc` is installed and logged in.
2. Checks that the target secrets exist:
   - `<instance>-cert-public` in `mas-<instance>-core`
   - `<instance>-<workspace>-cert-public-81` in `mas-<instance>-manage`
3. Creates the namespace `cert-ops` and the ServiceAccount `cert-ops-sa`, unless they exist.
4. Applies a Role and RoleBinding in each MAS namespace. The Role allows `get`, `patch` and `update` on the one named secret.
5. Verifies the permissions with `oc auth can-i --as=...`.
6. Creates a `kubernetes.io/service-account-token` Secret named `cert-ops-sa-token`, unless it exists. OpenShift fills in the long-lived token.
7. Waits for the token to be populated, then prints it on **stdout**. All log messages go to **stderr**.

You can run the script again safely. Every step checks for existing resources or uses `oc apply`.

### Prerequisites

- `oc` CLI in `PATH`.
- You are logged in with rights to create namespaces, ServiceAccounts, Roles and RoleBindings. In practice that means `cluster-admin`.

  ```bash
  oc login --server=https://api.<cluster>:6443 -u kubeadmin -p <password>
  ```

- The target secrets already exist, because `oc set data` can't create them.

### Usage

```bash
# Defaults: INSTANCE_ID=dev, WORKSPACE_ID=dev
OPENSHIFT_TOKEN=$(./scripts/get_sa_token.sh)

# Custom instance and workspace
INSTANCE_ID=prod WORKSPACE_ID=main ./scripts/get_sa_token.sh
```

Run the script from any directory. It doesn't use relative paths.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `INSTANCE_ID` | `dev` | MAS instance ID. It sets the namespaces and secret names. |
| `WORKSPACE_ID` | `dev` | MAS workspace ID. It sets the Manage secret name. |
| `SA_NS` | `cert-ops` | Namespace that holds the ServiceAccount and token secret. |
| `SA_NAME` | `cert-ops-sa` | ServiceAccount name. |
| `WAIT_SECONDS` | `30` | How long to wait for the token to be populated. |

Keep `INSTANCE_ID` and `WORKSPACE_ID` the same as in `update_cert.sh`.

### Store the token in GitHub

Run the commands below after the script. They use the `gh` CLI. You can also add the secrets in the web UI under *Settings → Secrets and variables → Actions*.

```bash
OPENSHIFT_SERVER=$(oc whoami --show-server)
OPENSHIFT_TOKEN=$(./scripts/get_sa_token.sh)

gh secret set OPENSHIFT_SERVER --repo istrate/cert-ops --body "$OPENSHIFT_SERVER"
gh secret set OPENSHIFT_TOKEN  --repo istrate/cert-ops --body "$OPENSHIFT_TOKEN"
unset OPENSHIFT_TOKEN
```

### Test the token

Use a clean shell or a separate kubeconfig, so you don't keep the admin login.

```bash
oc login --server="$OPENSHIFT_SERVER" --token="$OPENSHIFT_TOKEN"
oc whoami                                    # system:serviceaccount:cert-ops:cert-ops-sa
oc get secret dev-cert-public -n mas-dev-core
oc get secret other-secret -n mas-dev-core   # Forbidden, as expected
```

### Revoke access

```bash
oc delete secret cert-ops-sa-token -n cert-ops    # invalidates the token
oc delete sa cert-ops-sa -n cert-ops              # removes the ServiceAccount entirely
```

If you delete the token secret and run the script again, you get a new token.

### Security notes

- A long-lived token never expires, so treat it like a password. Never commit it, and don't print it in CI logs.
- The Role names the two secrets explicitly, so a leaked token can't read or change anything else.
- Rotate the token regularly: delete the token secret, run the script, and update the `OPENSHIFT_TOKEN` GitHub secret.
- For a time-limited alternative, use `oc create token cert-ops-sa -n cert-ops --duration=720h`. The cluster may cap the maximum duration.
- If `oc login` fails with an unknown certificate authority error, the API server uses a private CA. Pass `--certificate-authority`, or use `--insecure-skip-tls-verify=true` in a lab only.
- On Windows, run the script from Git Bash or WSL.
