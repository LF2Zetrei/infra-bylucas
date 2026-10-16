# infra-bylucas

Infrastructure as code for the `bylucas.eu` VPS (OVH).

| Folder | Tool | What it manages |
|---|---|---|
| [`terraform/`](terraform/README.md) | Terraform + OVH provider | DNS: `bylucas.eu` and `*.bylucas.eu` → VPS IP |
| [`ansible/`](ansible/README.md) | Ansible | Everything on the VPS: hardening, nginx + TLS, PostgreSQL, Docker, one systemd service + vhost per project |

Continuous deployment of each project's code lives in a separate repository,
[`LF2Zetrei/infra-github-actions`](https://github.com/LF2Zetrei/infra-github-actions)
(reusable GitHub Actions workflow called by every project).

```
DNS (terraform/)  →  server configuration (ansible/)  →  code delivery on git push (infra-github-actions)
```

## Secrets and local files

Nothing secret or machine-specific is committed. Each one has a committed
`*.example` template:

| Local file (git-ignored) | Template |
|---|---|
| `ansible/inventory.yml` | `ansible/inventory.example.yml` |
| `ansible/group_vars/all/vault.yml` (ansible-vault) | `ansible/group_vars/all/vault.yml.example` |
| `ansible/group_vars/all/private.yml` | `ansible/group_vars/all/private.yml.example` |
| `ansible/vault_pass.txt` | — |
| `terraform/terraform.tfvars` | `terraform/terraform.tfvars.example` |
| `terraform/terraform.tfstate` | — |

OVH API credentials are read from environment variables only
(see `terraform/README.md`). Keep a backup of the local files outside the repo.
