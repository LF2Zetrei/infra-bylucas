# Terraform — OVH DNS zone

This folder manages **only the DNS** for the `bylucas.eu` domain at OVH:
two `A` records that point the root domain and **every** subdomain to the
VPS IP. It is the first link in the chain:

```
Browser ──DNS──▶ bylucas.eu / *.bylucas.eu ──▶ VPS IP            ← Terraform (here)
                                                 │
                                  nginx, systemd, TLS, DB...      ← infra/ansible
                                                 │
                                   up-to-date project code        ← infra/github-actions
```

The VPS itself and the domain name are bought/created **manually** in the
OVH control panel: the matching Terraform resources (`ovh_vps`,
`ovh_domain_name`) are unreliable in practice.

---

## Table of contents

1. [Layout](#1-layout)
2. [How the code works](#2-how-the-code-works)
3. [Authenticating against the OVH API](#3-authenticating-against-the-ovh-api)
4. [Terraform state](#4-terraform-state)
5. [Step-by-step usage](#5-step-by-step-usage)
6. [The wildcard: why, and what it implies](#6-the-wildcard-why-and-what-it-implies)
7. [Common scenarios](#7-common-scenarios)
8. [Things to watch out for](#8-things-to-watch-out-for)

---

## 1. Layout

```
terraform/
├── main.tf               # OVH provider + the 2 DNS records
├── variables.tf          # Input declarations: domain_name, vps_ip
├── outputs.tf            # Values printed after apply: root_domain, vps_ip
├── terraform.tfvars      # Actual variable values (NOT committed)
├── terraform.tfvars.example  # Committed template of terraform.tfvars
├── .terraform.lock.hcl   # Exact provider version + checksums (committed)
├── terraform.tfstate     # Terraform's view of the real infrastructure (NOT committed, local)
├── .terraform/           # Provider binary downloaded by "init" (NOT committed)
└── .gitignore
```

| File | Committed | Purpose |
|---|---|---|
| `main.tf`, `variables.tf`, `outputs.tf` | yes | The code |
| `terraform.tfvars.example` | yes | Template with dummy values |
| `terraform.tfvars` | no | `domain_name = "bylucas.eu"`, `vps_ip = "<IP>"` |
| `terraform.tfstate` | no | Maps Terraform resources ↔ record IDs at OVH |
| `.terraform.lock.hcl` | yes | Pins the provider (currently `ovh/ovh` 0.51.0) so every `init` gets the same version |

---

## 2. How the code works

### `main.tf`

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    ovh = { source = "ovh/ovh", version = "~> 0.44" }   # >= 0.44, < 1.0
  }
}

provider "ovh" {}   # empty: credentials come from environment variables
```

Two `ovh_domain_zone_record` resources, identical except for the subdomain:

| Resource | `zone` | `subdomain` | `fieldtype` | `ttl` | `target` | Resulting record |
|---|---|---|---|---|---|---|
| `ovh_domain_zone_record.root` | `var.domain_name` | `""` | `A` | 3600 | `var.vps_ip` | `bylucas.eu. 3600 IN A <IP>` |
| `ovh_domain_zone_record.wildcard` | `var.domain_name` | `"*"` | `A` | 3600 | `var.vps_ip` | `*.bylucas.eu. 3600 IN A <IP>` |

On every create/update, the provider calls the OVH API
(`POST/PUT /domain/zone/{zone}/record`) and then refreshes the zone so the
change is published on OVH's DNS servers.

TTL 3600 s = 1 h: after an IP change, some clients will keep the old IP
cached for up to an hour.

### `variables.tf`

| Variable | Type | Description | Current value |
|---|---|---|---|
| `domain_name` | string | Managed DNS zone | `bylucas.eu` |
| `vps_ip` | string | Public IPv4 of the VPS | see `terraform.tfvars` |

No defaults: Terraform reads them from `terraform.tfvars` (loaded
automatically), or prompts for them if the file is missing. They can also
be passed with `-var 'vps_ip=1.2.3.4'` or `TF_VAR_vps_ip`.

### `outputs.tf`

Printed at the end of `terraform apply` and by `terraform output`:
`root_domain` (the zone) and `vps_ip`.

---

## 3. Authenticating against the OVH API

### Create credentials

At https://api.ovh.com/createToken/ (or `https://eu.api.ovh.com/createToken/`):

- **Rights**: `GET`, `POST`, `PUT`, `DELETE` on `/domain/zone/*`
  (`DELETE` is needed for `terraform destroy`, or when a resource must be
  replaced, e.g. a `subdomain` change).
- **Validity**: "Unlimited", or a limited duration if you'd rather rotate.
- Optionally restrict by IP.

You get three values: Application Key, Application Secret, Consumer Key.

### Pass them to Terraform

The `provider "ovh" {}` block is **intentionally** empty: the provider
reads these environment variables itself, so no secret lives in the code.

```bash
export OVH_ENDPOINT="ovh-eu"
export OVH_APPLICATION_KEY="..."
export OVH_APPLICATION_SECRET="..."
export OVH_CONSUMER_KEY="..."
```

Tip: put them in a `.env` file (git-ignored) and run
`set -a; source .env; set +a` before each Terraform session.

---

## 4. Terraform state

`terraform.tfstate` is Terraform's memory: it links
`ovh_domain_zone_record.root` / `.wildcard` to the **numeric IDs** of the
records created at OVH. Without it, Terraform no longer knows it owns those
records and would try to **create them again** (duplicates).

- Backend: **local** (no `backend` block), file lives in this folder.
- Not committed (`.gitignore`): it only exists on the machine that ran the
  last `apply`. **Back it up** (copy outside the repo) — it is the only file
  that cannot be trivially rebuilt.
- It contains the variable values (IP, domain): no OVH secrets, but don't
  publish it.

If the state is lost, it can be rebuilt by importing (see §7).

---

## 5. Step-by-step usage

Prerequisites: Terraform ≥ 1.5 (`terraform version`), domain bought at OVH
and using **OVH's DNS servers**, VPS created and its IP known.

```bash
cd infra/terraform

# 1. Credentials
export OVH_ENDPOINT=ovh-eu OVH_APPLICATION_KEY=... OVH_APPLICATION_SECRET=... OVH_CONSUMER_KEY=...

# 2. Values (if the file doesn't exist yet), then set the real vps_ip
cp terraform.tfvars.example terraform.tfvars

# 3. Download the ovh/ovh provider into .terraform/ and create .terraform.lock.hcl
terraform init

# 4. Show what would change, without touching anything
terraform plan

# 5. Apply (asks for "yes")
terraform apply

# Check
dig +short bylucas.eu
dig +short anything.bylucas.eu      # must return the same IP thanks to the wildcard
```

Reading a `plan`:

| Symbol | Meaning |
|---|---|
| `+` create | Record not in state → will be created |
| `~` update in-place | e.g. new IP or TTL → modified without deletion |
| `-/+` replace | e.g. `zone` or `subdomain` changed → deleted then recreated |
| `No changes.` | OVH reality matches the code |

`terraform plan` also compares against the **real** state at OVH: if someone
edited the record by hand in the control panel, the plan shows it and
`apply` brings it back in line with the code.

---

## 6. The wildcard: why, and what it implies

Thanks to `*.bylucas.eu`, **no Terraform action is needed to add a
project**: `catlendar.bylucas.eu`, `monitor.bylucas.eu`,
`new-project.bylucas.eu`... all resolve to the VPS immediately. You only
declare the project on the Ansible side (nginx vhost + certificate).

Implications:

- Any made-up subdomain reaches the VPS. The nginx **catch-all** block
  (`return 444`, Ansible `nginx` role) drops requests whose host name is not
  declared by any project.
- Certificates are issued **one per subdomain** via the HTTP-01 challenge
  (no wildcard certificate, which would require a DNS-01 challenge).
- An explicit record (e.g. a `www` CNAME added by hand) takes precedence
  over the wildcard for that name.
- The wildcard covers one level only: `a.b.bylucas.eu` is not covered.

---

## 7. Common scenarios

### The VPS IP changes (new VPS, migration)

```bash
# edit vps_ip in terraform.tfvars
terraform plan     # should show 2 "~ update in-place" on target
terraform apply
```

Then put the same IP in `infra/ansible/inventory.yml` and in the GitHub
secret `VPS_HOST` if it holds an IP.

### State lost, records already exist at OVH

Get the record IDs (OVH API:
`GET /domain/zone/bylucas.eu/record?fieldType=A`), then:

```bash
terraform import ovh_domain_zone_record.root     bylucas.eu.<root_id>
terraform import ovh_domain_zone_record.wildcard bylucas.eu.<wildcard_id>
terraform plan     # should show "No changes."
```

### Add another record (MX, TXT, CNAME...)

Add a resource in `main.tf` following the same pattern:

```hcl
resource "ovh_domain_zone_record" "txt_verification" {
  zone      = var.domain_name
  subdomain = ""
  fieldtype = "TXT"
  ttl       = 3600
  target    = "\"google-site-verification=...\""
}
```

### Remove everything

`terraform destroy` deletes both `A` records (the domain stops resolving).
The domain and the zone itself remain at OVH.

---

## 8. Things to watch out for

- **Pre-existing records**: when a domain is bought, OVH often creates
  default `A` records (root, `www`) pointing at its parking servers.
  Terraform manages **only** its two records and does not delete others: if
  an old `A` remains on the root, the domain will resolve to **two IPs** in
  rotation. Check in the OVH control panel (DNS zone) that there is exactly
  one `A` on `bylucas.eu` and one on `*`.
- **Local-only files**: `terraform.tfvars` and `terraform.tfstate` are not
  in git. Back up the state outside the repo (see §4).
- **Provider upgrades**: `.terraform.lock.hcl` pins 0.51.0. To move to a
  newer 0.x allowed by `~> 0.44`, run `terraform init -upgrade` and commit
  the updated lock file.
- **Local state**: only one machine can safely manage the DNS. To work from
  several machines (or from CI), switch to a remote backend (e.g. an
  S3-compatible bucket on OVH Object Storage, with locking).
- **No IPv6**: only an `A` record is created. Add a matching `AAAA` (root +
  wildcard) if the VPS has IPv6 and nginx listens on IPv6
  (`listen [::]:80`), which the current vhosts don't.
- **This module does nothing on the VPS**: no SSH, no nginx, no certificates
  — that's the job of `infra/ansible/`.
