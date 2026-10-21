# mountOS deployment

Terraform and operator scripts that deploy a mountOS hub, its regions and its block storage on AWS, GCP or Azure.

mountOS is a distributed filesystem. This package provisions the cloud resources, seeds the secret stores and checks the running hub. The server binaries come from [mountos.sh/install](https://mountos.sh). Product documentation is at [mountos.io](https://mountos.io).

## What is in the package

| Path | Purpose |
| --- | --- |
| `clouds/aws/terraform`, `clouds/gcp/terraform`, `clouds/azure/terraform` | One self-contained Terraform root per cloud: network, KMS or key vault, database, compute, load balancers, DNS. |
| `clouds/azure/blockserv-only` | Azure root for block storage only, for a hub that runs on another cloud. |
| `bootstrap/` | Operator-side scripts that generate fresh keys and write them to the secret store. `keygen` is the key generator. |
| `verify.sh` | Read-only health checks against the running hub. |
| `block-roll.sh` | Rolls block storage members one at a time. |
| `answers.sample.env` | The settings that cannot be generated or derived. |
| `release.yaml` | Release manifest. One version pins the templates, the server binary and the helpers. |
| `demo/` | Templates for a development and demo fleet. Not for production. |

## Requirements

- Terraform.
- The command line tool of your cloud (`aws`, `gcloud` or `az`) with credentials for the target account.
- A public domain name for the hub. Set it as `HUB_DOMAIN`.
- A managed PostgreSQL database for the admin data, or let the package provision one.
- An encrypted remote backend for Terraform state.

## Quick start

Run all commands from the repository root. Select the cloud with `CLOUD=aws`, `CLOUD=gcp` or `CLOUD=azure`. The default comes from `CLOUD=` in `answers.env`, and AWS is the fallback.

1. Create `answers.env` from the sample.

   ```bash
   make interview
   ```

2. Edit `answers.env`. At minimum, set `HUB_DOMAIN` and the database settings.
3. In `clouds/<cloud>/terraform`, copy `backend.tf.sample` to `backend.tf` and `terraform.tfvars.sample` to `terraform.tfvars`. Fill in your values. Production state must use an encrypted remote backend.
4. Check the Terraform files. This needs no cloud credentials.

   ```bash
   make validate
   ```

5. Preview the changes, then apply them.

   ```bash
   make plan
   make apply
   ```

6. Generate fresh keys and write them to the hub secret store. Run this once, from the operator host.

   ```bash
   make bootstrap
   ```

7. Seed the region secret store and exchange the service verifiers between the hub and the region.

   ```bash
   make region-bootstrap
   ```

8. Check the running hub.

   ```bash
   make verify
   ```

The admin private key stays on the operator host in `secrets.local.json`. Keep it safe. Both `secrets.local.json` and `answers.env` are ignored by Git.

## Secret stores

The package writes initial values into a secret store that you own or that the cloud provides. It never installs or runs a HashiCorp Vault.

| `VAULT_PROVIDER` | Store |
| --- | --- |
| `aws` | AWS Secrets Manager. Recommended on AWS. |
| `gcp` | Google Secret Manager. |
| `azure` | Azure Key Vault. |
| `hashicorp` | Your own Vault. Set `VAULT_ADDR` and a short-lived bootstrap token. |

## Upgrade

1. Set `MOS_VERSION` in `answers.env`. An empty value means the latest release.
2. Run `make apply`. The instance group rolls the hub and the region nodes. No data is touched.

A plain `apply` replaces all changed block storage members at the same time. To keep the storage serving, roll them one at a time.

```bash
make block-roll
```

## Safety

- Every target is idempotent. Running a target again converges forward.
- The package has no destroy target. To decommission a hub, follow a manual runbook.
- The package ships no secrets and no state.

## Cloud verification level

| Cloud | Level |
| --- | --- |
| AWS | `terraform plan` runs against a full resource graph in a local AWS API emulator. |
| GCP, Azure | `terraform validate` and `tflint` only. Test with a real project or subscription before production use. |

On GCP and Azure, the database master password is a Terraform value (`random_password`), not a platform-managed secret.

## License

Apache License 2.0. See `LICENSE` and `NOTICE`.
