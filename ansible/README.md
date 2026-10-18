# Ansible — full VPS configuration

This folder turns a blank Ubuntu VPS (at OVH) into a production server
ready to host every `*.bylucas.eu` project: security (SSH, firewall,
fail2ban, automatic updates), nginx reverse proxy + HTTPS, PostgreSQL,
Docker (Warp10, Minecraft), and **a systemd service + an nginx vhost + a TLS
certificate generated automatically for every project** declared in a
single variables file.

> Where it fits in the overall infrastructure:
>
> | Piece | Responsibility | How often |
> |---|---|---|
> | `infra/terraform/` | OVH DNS: `bylucas.eu` and `*.bylucas.eu` → VPS IP | Once (or when the IP changes) |
> | **`infra/ansible/`** (here) | Everything **installed/configured on the VPS** | When the VPS is created + for every new project |
> | `infra/github-actions/` | Shipping each project's **code** on every `git push` | On every push to `main` |
>
> Ansible builds **the container** (folder, `.env`, service, nginx,
> certificate). GitHub Actions fills in **the content** (code, dependencies,
> build) and restarts the service. Ansible never clones any code.

---

## Table of contents

1. [Layout](#1-layout)
2. [How Ansible connects to the VPS](#2-how-ansible-connects-to-the-vps)
3. [Variables and secrets](#3-variables-and-secrets)
4. [Playbook walkthrough, role by role](#4-playbook-walkthrough-role-by-role)
5. [The `app-deploy` role in detail](#5-the-app-deploy-role-in-detail)
6. [What the VPS looks like after a run](#6-what-the-vps-looks-like-after-a-run)
7. [Installation and first run](#7-installation-and-first-run)
8. [Everyday commands](#8-everyday-commands)
9. [Adding a new project](#9-adding-a-new-project)
10. [Idempotence: what is re-applied and what isn't](#10-idempotence-what-is-re-applied-and-what-isnt)
11. [Known pitfalls](#11-known-pitfalls)

---

## 1. Layout

```
ansible/
├── ansible.cfg                 # Ansible options (no host key checking, SSH pipelining)
├── inventory.yml               # THE target server: host "vps", IP, user, SSH key   (NOT committed)
├── inventory.example.yml       # Committed template of inventory.yml
├── playbook.yml                # Entry point: ordered list of roles to apply
├── requirements.yml            # Required Ansible Galaxy collections
├── .gitignore                  # inventory.yml, vault.yml, private.yml, vault_pass.txt, *.retry
├── group_vars/
│   └── all/                    # Loaded automatically for ALL hosts
│       ├── vars.yml            # Plain-text variables: projects, databases, services...
│       ├── private.yml         # Personal non-secret values (certbot_email)            (NOT committed)
│       ├── private.yml.example # Committed template of private.yml
│       ├── vault.yml           # Encrypted secrets (AES256, ansible-vault)             (NOT committed)
│       └── vault.yml.example   # Committed list of the expected vault keys, no values
└── roles/
    ├── ssh-hardening/          # Non-root user + sshd hardening
    ├── firewall/               # UFW: 22, 80, 443, 25565 open, everything else closed
    ├── unattended-upgrades/    # Automatic security updates
    ├── fail2ban/               # Ban IPs after failed SSH logins
    ├── nginx/                  # Nginx + Certbot + global hardening
    ├── postgresql/             # Local PostgreSQL + users/DBs + daily backup
    ├── swap/                   # 4 GB swap file
    ├── docker/                 # Docker Engine (official repository)
    ├── warp10/                 # Warp10 container (time series), localhost only
    ├── minecraft-homestead/    # Minecraft server container (public port 25565) + panel script/sudoers
    ├── app-deploy/             # Per-project systemd services + nginx + TLS
    └── ollama/                 # (NOT called by the playbook at the moment, see §11)
```

Each role follows the standard Ansible structure:

| Subfolder | Content |
|---|---|
| `tasks/main.yml` | The steps, executed in order |
| `defaults/main.yml` | Default values (lowest precedence, can be overridden in `group_vars` or with `-e`) |
| `handlers/main.yml` | Actions triggered by `notify` (reload/restart), run **once at the end of the play** (or at a `flush_handlers`) |
| `templates/*.j2` | Jinja2 files rendered with the variables and copied to the VPS |

---

## 2. How Ansible connects to the VPS

### `inventory.yml`

```yaml
all:
  hosts:
    vps:
      ansible_host: "<VPS IP>"
      ansible_user: lucas
      ansible_ssh_private_key_file: ~/.ssh/bylucas
```

- A single host named `vps`. The playbook targets `hosts: vps`.
- SSH connection as `lucas` using the private key `~/.ssh/bylucas` **on your
  local machine** (the "control node").
- Every task runs with `become: true` (sudo): `lucas` must be in the `sudo`
  group. If sudo asks for a password, add `-K` (`--ask-become-pass`).

### `ansible.cfg`

```ini
[defaults]
host_key_checking = False   # don't fail if the VPS SSH fingerprint changes (e.g. reinstalled VPS)

[ssh_connection]
pipelining = True           # run modules without copying temp files -> much faster
```

> `ansible.cfg` is only picked up when you run `ansible-playbook` **from
> this folder** (`infra/ansible/`). Always run commands from here.

### `requirements.yml`

Collections used by the roles (install once on your machine):

| Collection | Used for |
|---|---|
| `community.general` | `ufw` (firewall), `htpasswd` (nginx basic auth) |
| `community.postgresql` | `postgresql_user`, `postgresql_db` |
| `ansible.posix` | `authorized_key` (SSH key), `sysctl` (swappiness) |

`community.general.htpasswd` also needs the Python `passlib` library where
the module runs, i.e. on the VPS. If the htpasswd task fails, install
`python3-passlib` on the VPS.

---

## 3. Variables and secrets

### Where variables come from

Ansible automatically loads everything in `group_vars/all/` for every host.
Precedence (lowest to highest) as used here:

```
roles/*/defaults/main.yml   <   group_vars/all/*.yml   <   -e "..." on the command line
```

A role's `defaults` are **visible to the roles that follow it** in the same
play. That's why `ssh_user` (defined in
`roles/ssh-hardening/defaults/main.yml`) can be used in `docker`,
`app-deploy`, and so on.

### `group_vars/all/vars.yml` — the central file

This is **the only file to edit when adding a project**. It contains:

#### `projects` — the list of hosted projects

Each entry describes one project. Recognised fields:

| Field | Required | Types | Purpose |
|---|---|---|---|
| `name` | yes | all | Unique identifier. Becomes the systemd service name (`<name>.service`), the nginx file (`/etc/nginx/sites-available/<name>`), the htpasswd file. **Must match the GitHub Actions workflow's `project_name`.** |
| `type` | yes | — | `node`, `python`, `rust`, `springboot`, `c` or `static`. Selects the systemd template and the nginx vhost kind. |
| `path` | yes | all | Project folder on the VPS. For `static`: the folder **served** by nginx (e.g. `/var/www/landing`). Otherwise: the app folder (e.g. `/home/lucas/apps/catlendar`). **Must match the workflow's `remote_path`.** |
| `subdomain` | yes | all | Full host name served (nginx `server_name` + Certbot certificate). e.g. `catlendar.bylucas.eu`, or `bylucas.eu` for the root. |
| `port` | yes except static | non-static | Local port the app listens on. nginx does `proxy_pass http://localhost:<port>`. One distinct port per project. |
| `env_vars` | no | non-static (in practice) | `KEY: value` dictionary → rendered into `<path>/.env`. Sensitive values reference the vault: `"{{ vault_xxx }}"`. |
| `entrypoint` | no | `python` | Script run by the venv (default `app.py`). |
| `binary` | no | `rust`, `c` | Binary name (default = `name`). |
| `jar` | no | `springboot` | Jar name inside `target/` (default `app.jar`). |
| `basic_auth` | no | non-static | `true` = protect the site with an nginx login/password. |
| `basic_auth_user` | no | — | Default `lucas`. |
| `basic_auth_password` | if basic_auth | — | Always via the vault: `"{{ vault_xxx_password }}"`. |
| `proxy_timeout` | no | non-static | nginx timeout in seconds (default 60). Raise it for long-running requests. |
| `large_transfers` | no | non-static | `true` = stream big uploads/downloads through nginx: `client_max_body_size 4g`, `proxy_request_buffering off`, `proxy_buffering off`. Used by `monitoring` (Minecraft world upload/download). |

Currently declared projects:

| name | type | subdomain | port | Notes |
|---|---|---|---|---|
| `portfolio` | static | portfolio.bylucas.eu | — | served from `/var/www/portfolio` |
| `landing` | static | bylucas.eu | — | served from `/var/www/landing` |
| `warp10v2` | node | warp10.bylucas.eu | 3001 | talks to Warp10 on `localhost:8080`, tokens from the vault |
| `front-component` | node | front-component.bylucas.eu | 3002 | |
| `catTree` | node | catTree.bylucas.eu | 3003 | |
| `catlendar` | node | catlendar.bylucas.eu | 3004 | PostgreSQL DB `catlendar`, secrets from the vault |
| `monitoring` | node | monitor.bylucas.eu | 3005 | basic auth, 3600 s timeout, `large_transfers` |

#### `postgresql_app_users` — application databases

```yaml
postgresql_app_users:
  - name: catlendar                         # PostgreSQL role (user)
    password: "{{ vault_catlendar_password }}"
    db: catlendar                           # database created, owned by that role
```

One item = one user + one database. The app connects with
`postgresql://<name>:<password>@localhost:5432/<db>` (put it in its
`env_vars`).

#### Other variables

| Variable | Usage |
|---|---|
| `certbot_email` | Let's Encrypt email (expiry alerts). Defined in `group_vars/all/private.yml` (not committed), also passed to `monitoring` as `CERTBOT_EMAIL`. |
| `infra_services` | System services (`nginx`, `postgresql`, `fail2ban`, `docker`) written to `/etc/infra-manifest.json` for the monitoring tool. |
| `docker_containers` | Containers (`warp10`, `homestead`): written to the infra manifest + passwordless `docker restart` sudo rights for monitoring. |

### `group_vars/all/vault.yml` — secrets

File encrypted with AES256 by `ansible-vault`. It is decrypted in memory
when the playbook starts, thanks to `--ask-vault-pass` (or
`--vault-password-file`). Its variables are prefixed `vault_` by convention
and **referenced** from `vars.yml` — never put a plain-text secret in
`vars.yml`.

Variables currently expected by the code (they must all exist in the vault,
otherwise the playbook fails with `undefined variable`):

| Vault variable | Used by |
|---|---|
| `vault_warp10_write_token`, `vault_warp10_read_token` | `warp10v2` `.env` |
| `vault_catlendar_password` | PostgreSQL user `catlendar` + `DATABASE_URL` |
| `vault_catlendar_passcode`, `vault_catlendar_auth_secret` | `catlendar` `.env` |
| `vault_monitoring_password` | basic auth on `monitor.bylucas.eu` |
| `vault_curseforge_api_key` | `minecraft-homestead` role (modpack download) |

Useful commands:

```bash
ansible-vault view group_vars/all/vault.yml     # read
ansible-vault edit group_vars/all/vault.yml     # edit (opens $EDITOR, re-encrypts on save)
ansible-vault rekey group_vars/all/vault.yml    # change the vault password
```

To avoid typing the password every time: store it in `vault_pass.txt`
(git-ignored, `chmod 600`) and run with `--vault-password-file vault_pass.txt`.

### What is committed and what isn't

The git repository only contains code and templates. Machine-specific and
secret files stay local and must be **backed up separately** (password
manager, encrypted drive...):

| Local file (git-ignored) | Committed template | Content |
|---|---|---|
| `inventory.yml` | `inventory.example.yml` | VPS IP, SSH user and key path |
| `group_vars/all/vault.yml` | `group_vars/all/vault.yml.example` | All secrets (encrypted) |
| `group_vars/all/private.yml` | `group_vars/all/private.yml.example` | `certbot_email` |
| `vault_pass.txt` | — | Vault password |

On a fresh clone:

```bash
cp inventory.example.yml inventory.yml                          # then set the real IP
cp group_vars/all/private.yml.example group_vars/all/private.yml # then set the email
ansible-vault create group_vars/all/vault.yml                    # paste the keys from vault.yml.example with real values
                                                                 # (or restore your backed-up vault.yml)
```

The `.example` extension matters: Ansible only loads `.yml`, `.yaml`,
`.json` or extension-less files from `group_vars/`, so the templates are
never read as real variables.

---

## 4. Playbook walkthrough, role by role

`playbook.yml` applies the roles **in this order** on host `vps`, with
`become: true`:

```
ssh-hardening → firewall → unattended-upgrades → fail2ban → nginx
→ postgresql → swap → docker → warp10 → minecraft-homestead → app-deploy
```

Order matters: security first, then shared services (nginx, PostgreSQL,
Docker), and finally `app-deploy`, which relies on everything before it
(nginx installed, snippets in place, Certbot available, `ssh_user` defined...).

### 4.1 `ssh-hardening`

Defaults: `ssh_user: lucas`, `ssh_public_key_path: ~/.ssh/id_ed25519.pub`.

1. Creates user `lucas` (bash shell, home dir, `sudo` group) if missing.
2. Adds the public key **read on your local machine** (`ssh_public_key_path`)
   to `~lucas/.ssh/authorized_keys` on the VPS.
3. In `/etc/ssh/sshd_config`: `PermitRootLogin no`,
   `PasswordAuthentication no`, `PermitEmptyPasswords no`.
4. `Redémarrer sshd` handler if any line changed.

Result: login is key-only, and never as root.

### 4.2 `firewall` (UFW)

1. Installs `ufw`.
2. Policy: **deny all incoming**, allow all outgoing.
3. Opens: `OpenSSH` (22), `80/tcp`, `443/tcp`, `25565/tcp` (Minecraft).
4. Enables UFW.

SSH is allowed **before** enabling UFW so you don't lock yourself out.
PostgreSQL (5432), Warp10 (8080/8081) and the app ports (3001–3005) are
**not** opened: they are only reachable locally.

> ⚠️ Docker publishes ports by editing iptables directly, **bypassing UFW**.
> That's why Warp10 is published on `127.0.0.1:8080` (not `0.0.0.0`).
> Minecraft's port 25565 is meant to be public anyway.

### 4.3 `unattended-upgrades`

Installs `unattended-upgrades` + `apt-listchanges`, writes
`/etc/apt/apt.conf.d/20auto-upgrades` (package list refresh and security
updates **daily**), enables the service.

### 4.4 `fail2ban`

Defaults: `maxretry: 5`, `findtime: 600` (10 min), `bantime: 3600` (1 h).

Deploys `/etc/fail2ban/jail.local` with an `[sshd]` jail reading
`/var/log/auth.log`: 5 failed SSH logins within 10 min from one IP → IP
banned for 1 h. `Redémarrer fail2ban` handler when the config changes.

### 4.5 `nginx`

Defaults: `nginx_rate_limit_rps: 10`.

1. Installs `nginx`, `certbot`, `python3-certbot-nginx`.
2. **Catch-all** `/etc/nginx/sites-available/00-default-catchall` (enabled):
   `listen 80 default_server; return 444;` → any request whose `Host`
   matches no project is closed without a response. Essential with the
   `*.bylucas.eu` wildcard DNS (otherwise any invented subdomain would land
   on whichever site comes first).
3. **Snippet** `/etc/nginx/snippets/security-headers.conf` (included by each
   project vhost): `X-Frame-Options DENY`, `X-Content-Type-Options nosniff`,
   `Referrer-Policy strict-origin-when-cross-origin`, 2-year HSTS with
   `includeSubDomains`.
4. **Rate limiting** `/etc/nginx/conf.d/rate-limit.conf`: shared zone
   `global_limit` (10 MB, 10 req/s per IP). Used by the proxy vhosts with
   `burst=20 nodelay`.
5. Removes Ubuntu's default site (`sites-enabled/default`).
6. Starts/enables nginx and the `certbot.timer` (automatic certificate
   renewal, twice a day).

**Per-project** vhosts are not created here but in `app-deploy` (§5), using
this role's `project-site.conf.j2` and `static-site.conf.j2` templates.

### 4.6 `postgresql`

Defaults: `postgresql_backup_dir: /var/backups/postgresql`,
`postgresql_backup_retention_days: 14`, `postgresql_app_users: []`
(overridden in `vars.yml`). `postgresql_version` is defined but unused: the
version from the Ubuntu repositories is installed.

1. Installs `postgresql` + `python3-psycopg2` (needed by the Ansible modules).
2. Detects the actual config folder (`/etc/postgresql/<version>/main/`),
   taking the highest version present.
3. Forces `listen_addresses = 'localhost'` → PostgreSQL never listens on the
   public IP (restart handler if changed).
4. Starts/enables the service.
5. For each `postgresql_app_users` entry (as system user `postgres`):
   creates the role with its password (`no_log`), then the database it owns.
6. Deploys `/usr/local/bin/pg_backup.sh` and a **root cron at 03:00** that
   runs `pg_dumpall | gzip` → `/var/backups/postgresql/all-databases-YYYY-MM-DD.sql.gz`
   and deletes dumps older than 14 days.

> Backups stay **on the VPS**. If the VPS is lost, so are they: copy them
> elsewhere (rsync/rclone) if the data matters.

### 4.7 `swap`

Default: `swap_size: 4G`.

If `swapon --show` returns nothing (no active swap): `fallocate` a 4 GB
`/swapfile`, `chmod 600`, `mkswap`, `swapon`. Then, always: an `/etc/fstab`
line (persistent swap) and `vm.swappiness = 10` (swap used only as a last
resort). A safety net against the OOM killer on a ~7.6 GB VPS shared by many
services.

### 4.8 `docker`

Installs Docker Engine from the **official Docker repository** (GPG key in
`/etc/apt/keyrings/docker.asc`, `download.docker.com` repo for the detected
Ubuntu release): `docker-ce`, `docker-ce-cli`, `containerd.io`,
`docker-compose-plugin`. Enables the service and adds `lucas` to the
`docker` group (docker without sudo — effective on the next SSH login).

### 4.9 `warp10`

Defaults: `warp10_heap: 1g`, `warp10_version: 2.11.1-ng-2-ubuntu` (pinned,
never `latest`).

- Persistent data: `/var/warp10-data` mounted on `/data`.
- If no container named `warp10` exists: `docker run -d --name warp10
  --restart unless-stopped -p 127.0.0.1:8080:8080 -p 127.0.0.1:8081:8081`
  with the heap capped at 1 GB.
- Reachable **locally only** (by the `warp10v2` app via
  `WARP10_URL=http://localhost:8080`). No nginx vhost points to it.

### 4.10 `minecraft-homestead`

Defaults: `minecraft_heap: 4G`, `minecraft_cf_slug: homestead-cozy`,
`minecraft_cf_file_id` (commented out — set it to pin the modpack version).
The slug/file ID are only the **initial** values: afterwards the modpack is
changed from the monitoring dashboard (Minecraft panel).

- Persistent data: `/var/minecraft-homestead-data` → `/data`.
- Installs `zip`, `unzip`, `jq` (used by `minecraft-ctl`).
- Panel folders, owned by `lucas`, 0700: `/var/lib/minecraft-panel/`
  (`config.json` = current modpack, written by the monitoring app) and
  `/var/minecraft-uploads/` (uploaded world zip, waiting to be imported).
- `config.json` is created with `force: false`: **Ansible never overwrites
  a modpack chosen from the panel.**
- CurseForge API key copied to `/etc/minecraft/cf_api_key` (root, 0600), so
  it's no longer passed on an Ansible command line.
- `/usr/local/sbin/minecraft-ctl` (root, 0750, from `minecraft-ctl.j2`): the
  **only** root entry point of the panel. Fixed subcommands, no free
  arguments; values read from `config.json` (untrusted, written by the app)
  are re-validated by regex.

  | Subcommand | What it does |
  |---|---|
  | `start` / `stop` / `restart` | `docker start/stop/restart homestead` (60 s stop timeout so the world gets saved) |
  | `apply` | Recreates the container with the modpack of `config.json` (world volume kept) |
  | `apply-clean` | Same, after backing up the world and deleting `mods/`, `config/`, `.curseforge*` |
  | `create` | Creates the container only if it doesn't exist (used by Ansible) |
  | `export-world` | Streams a zip of the world to stdout (`save-off` + `save-all flush` via RCON during the copy) |
  | `import-world` | Validates `/var/minecraft-uploads/incoming.zip` (valid zip, no `..`/absolute paths, contains `level.dat`, ≤ 8 GB unzipped), stops the server, backs up the old world, swaps it in, `chown 1000:1000`, starts the server |

  World backups: `/var/minecraft-backups/world-<date>.tar.gz`, **5 kept**.
- `/etc/sudoers.d/minecraft-panel` (from `minecraft-sudoers.j2`, validated
  with `visudo -cf`): `lucas` may run exactly
  `minecraft-ctl start|stop|restart|apply|apply-clean|export-world|import-world`
  without a password (no wildcard, `create` excluded).
- Container: `minecraft-ctl create` → `itzg/minecraft-server:java17` with
  `TYPE=AUTO_CURSEFORGE`, `CF_SLUG` (+ `CF_FILE_ID`) from `config.json`,
  `MEMORY={{ minecraft_heap }}`, **public** port `25565`,
  `--restart unless-stopped`. An existing container is left untouched.
- The only service exposed directly to the Internet without nginx.

### 4.11 `app-deploy`

The core of the system, detailed below.

---

## 5. The `app-deploy` role in detail

Principle: **for every project in `projects`**, generate all the
infrastructure it needs so it goes live as soon as GitHub Actions drops the
code in place.

### Steps, in order

| # | Step | Applies to | Result on the VPS |
|---|---|---|---|
| 1 | Compute `projects_to_process` | — | All projects, or only those in `target_projects` if non-empty |
| 2 | Install `python3-venv` | global | Lets the CD create Python venvs |
| 3 | Install Node.js LTS (NodeSource) if `which node` fails | global | `/usr/bin/node`, `/usr/bin/npm` |
| 4 | Create the project folder | non-static | `<path>/` (owner `lucas`, 0755), empty at first |
| 5 | Render the `.env` | projects with `env_vars` | `<path>/.env` (owner `lucas`, **0600**), `no_log` |
| 6 | Render the systemd unit | non-static | `/etc/systemd/system/<name>.service` → daemon-reload handler |
| 7 | `enable` + `start` the service | non-static | Service enabled at boot. `failed_when: false`: failure is expected until the code has been shipped |
| 8 | Create the served folder | static | `<path>/` (e.g. `/var/www/landing`, owner `lucas`) |
| 9 | Render the htpasswd | `basic_auth: true` | `/etc/nginx/.htpasswd_<name>` (root:www-data, 0640) |
| 10 | Check whether the vhost is already managed by Certbot | all | `grep 'managed by Certbot'` in `sites-available/<name>` |
| 11 | Render the proxy vhost | non-static **and not yet Certbot-managed** | `/etc/nginx/sites-available/<name>` from `project-site.conf.j2` |
| 12 | Render the static vhost | static **and not yet Certbot-managed** | `/etc/nginx/sites-available/<name>` from `static-site.conf.j2` |
| 13 | Enable the vhost | all | Symlink `sites-enabled/<name>` → `sites-available/<name>` |
| 14 | `meta: flush_handlers` | — | Reloads nginx **right now** (Certbot needs the HTTP vhost live) |
| 15 | Certbot | all except subdomain = raw IP | `certbot --nginx -d <subdomain> --redirect`; skipped if `/etc/letsencrypt/live/<subdomain>/fullchain.pem` already exists |
| 16 | Projects manifest | **all** projects (not just targeted ones) | `/etc/services-manifest.json` |
| 17 | Infra manifest | — | `/etc/infra-manifest.json` (`infra_services` + `docker_containers`) |
| 18 | Monitoring sudoers | — | `/etc/sudoers.d/monitoring-restart` (0440, validated with `visudo -cf`) |

### systemd templates

They all share: `User=lucas`, `WorkingDirectory=<path>`,
`EnvironmentFile=<path>/.env`, `Restart=on-failure`, `RestartSec=5`,
`WantedBy=multi-user.target`. Only the command differs:

| type | Template | `ExecStart` |
|---|---|---|
| `node` | `systemd-node.service.j2` | `/usr/bin/npm run start` |
| `python` | `systemd-python.service.j2` | `<path>/venv/bin/python3 <entrypoint\|app.py>` |
| `rust` | `systemd-rust.service.j2` | `<path>/target/release/<binary\|name>` |
| `springboot` | `systemd-springboot.service.j2` (+ `After=postgresql.service`) | `/usr/bin/java -jar <path>/target/<jar\|app.jar>` |
| `c` | `systemd-c.service.j2` | `<path>/<binary\|name>` |

> ⚠️ `EnvironmentFile=<path>/.env` has **no** `-` prefix: if a project
> declares no `env_vars`, there is no `.env` and the service will refuse to
> start. Declare at least `env_vars: { PORT: "<port>" }` (needed anyway so
> the app listens on the right port).

### nginx vhosts

**Project with a process** (`project-site.conf.j2`):

```nginx
server {
    listen 80;
    server_name <subdomain>;
    location / {
        include /etc/nginx/snippets/security-headers.conf;
        limit_req zone=global_limit burst=20 nodelay;
        # if basic_auth: auth_basic + auth_basic_user_file /etc/nginx/.htpasswd_<name>
        proxy_pass http://localhost:<port>;
        proxy_set_header Host / X-Real-IP / X-Forwarded-For / X-Forwarded-Proto ...;
        proxy_read_timeout / proxy_send_timeout <proxy_timeout|60>s;
        # if large_transfers: client_max_body_size 4g;
        #                     proxy_request_buffering off; proxy_buffering off;
    }
}
```

**Static site** (`static-site.conf.j2`):

```nginx
server {
    listen 80;
    server_name <subdomain>;
    root <path>;
    index index.html;
    location / {
        include /etc/nginx/snippets/security-headers.conf;
        try_files $uri $uri.html $uri/ =404;   # supports the "clean" URLs of a Next.js export
    }
}
```

**Certbot then edits this file in place**: it adds a `listen 443 ssl` block
with the certificate paths and an 80 → 443 redirect (`--redirect`). Every
line it adds carries the comment `# managed by Certbot`.

### Why the "managed by Certbot" check is critical

If Ansible re-rendered the template after Certbot, it would wipe the HTTPS
blocks, and since the certificate already exists the Certbot step would be
skipped (`creates:`) → the site would stop answering on HTTPS. So the role
**never re-renders a vhost already edited by Certbot**.

Consequence: **changing an existing vhost** (e.g. adding `basic_auth`,
changing `port` or `proxy_timeout`) **has no effect** on a plain re-run.
Procedure:

```bash
# on the VPS
sudo rm /etc/nginx/sites-available/<name>
# on your machine
ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass -e '{"target_projects": ["<name>"]}'
# on the VPS: the certificate exists, so Certbot was skipped -> reinstall the HTTPS blocks
sudo certbot install --nginx --cert-name <subdomain>
```

(That `certbot install` command is precisely what the monitoring sudoers
allows without a password, see below.)

### Manifests and the "monitoring" sudoers

The `monitoring` app (`monitor.bylucas.eu`) runs as `lucas` and reads/acts
on the infrastructure:

- `/etc/services-manifest.json`: the full `projects` list (JSON). ⚠️
  `env_vars` are included **resolved**, i.e. with secrets in plain text, in
  a world-readable file (0644). See §11.
- `/etc/infra-manifest.json`: `{"infra_services": [...], "docker_containers": [...]}`.
- `/etc/sudoers.d/monitoring-restart` lets `lucas` run, without a password:
  - `systemctl restart <name>` for every non-static project;
  - `docker restart <container>` for every container in `docker_containers`;
  - `certbot install --nginx --cert-name <subdomain>` and
    `certbot renew --cert-name <subdomain> --force-renewal` for every
    subdomain.

This file is **also what lets GitHub Actions** run
`sudo systemctl restart <name>` without a password (same `lucas` user).

The Minecraft panel has its own, separate sudoers file
(`/etc/sudoers.d/minecraft-panel`), installed by the `minecraft-homestead`
role (see §4.10).

---

## 6. What the VPS looks like after a run

```
/etc/ssh/sshd_config                       # root and password login disabled
/etc/fail2ban/jail.local                   # sshd jail
/etc/apt/apt.conf.d/20auto-upgrades        # automatic updates
/etc/nginx/
├── conf.d/rate-limit.conf                 # global_limit zone
├── snippets/security-headers.conf
├── sites-available/
│   ├── 00-default-catchall                # return 444
│   └── <name>                             # one per project (+ Certbot blocks)
├── sites-enabled/                         # symlinks
└── .htpasswd_<name>                       # projects with basic_auth
/etc/letsencrypt/live/<subdomain>/         # certificates
/etc/systemd/system/<name>.service         # one per non-static project
/etc/sudoers.d/monitoring-restart
/etc/sudoers.d/minecraft-panel             # minecraft-ctl subcommands for lucas
/etc/minecraft/cf_api_key                  # CurseForge API key (root, 0600)
/usr/local/sbin/minecraft-ctl              # root entry point of the Minecraft panel
/etc/services-manifest.json
/etc/infra-manifest.json
/usr/local/bin/pg_backup.sh                # + root crontab 03:00
/var/backups/postgresql/                   # daily dumps, 14 days
/var/www/<static-project>/                 # filled by the CD (content of out/)
/home/lucas/apps/<project>/                # filled by the CD (code) + .env (Ansible)
/var/warp10-data/                          # Warp10 data
/var/minecraft-homestead-data/             # Minecraft world, mods, server.properties
/var/lib/minecraft-panel/config.json       # current modpack (written by the panel)
/var/minecraft-uploads/                    # uploaded world zip before import
/var/minecraft-backups/                    # world backups (5 kept)
/swapfile                                  # 4 GB
```

Listening ports:

| Port | Service | Exposed? |
|---|---|---|
| 22 | sshd | public (UFW) + fail2ban |
| 80 / 443 | nginx | public (UFW) |
| 25565 | Minecraft (Docker) | public |
| 5432 | PostgreSQL | localhost |
| 8080 / 8081 | Warp10 (Docker) | 127.0.0.1 |
| 3001–3005 | node apps | blocked from outside by UFW, reached only through nginx |

Path of an HTTPS request to `https://catlendar.bylucas.eu`:

```
DNS *.bylucas.eu (Terraform) -> VPS IP
 -> UFW (443 allowed)
 -> nginx: server_name catlendar.bylucas.eu (otherwise catch-all 444)
    -> security headers + rate limit (+ basic auth if enabled)
    -> proxy_pass http://localhost:3004
 -> catlendar.service (systemd, user lucas, .env loaded) -> npm run start
    -> PostgreSQL localhost:5432 (catlendar database)
```

---

## 7. Installation and first run

### On your machine (control node)

```bash
pip install ansible --break-system-packages     # or: pipx install ansible
cd infra/ansible
ansible-galaxy collection install -r requirements.yml
```

### One-time manual step (fresh VPS)

Ansible needs an existing user reachable by key. Once, using the root access
provided by OVH:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/bylucas                 # key used by inventory.yml
ssh root@<IP> "useradd -m -s /bin/bash -G sudo lucas && passwd lucas"
ssh-copy-id -i ~/.ssh/bylucas.pub lucas@<IP>
```

The `ssh-hardening` role then deploys the key `~/.ssh/id_ed25519.pub`
(variable `ssh_public_key_path`): either you also have that key, or override
the variable to point to `~/.ssh/bylucas.pub` (see §11).

### Overall order on a fresh VPS

1. Create the VPS at OVH (manual), note the IP.
2. `infra/terraform`: `terraform apply` → DNS points to the new IP.
3. Put the IP in `inventory.yml`.
4. Manual step above (user `lucas` + key).
5. `ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass` (wait
   for DNS propagation first, otherwise Certbot fails; just re-run).
6. Push each project to `main` (or re-run its GitHub Actions workflow) to
   ship the code. The services start.
7. Restore data (PostgreSQL dump, `/var/warp10-data`, Minecraft world) if
   this is a rebuild.

---

## 8. Everyday commands

Always from `infra/ansible/`:

```bash
# Full run (safe to replay)
ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass

# Dry run: shows what would change, modifies nothing
ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass --check --diff

# Only process one or more projects in app-deploy
ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass -e '{"target_projects": ["catlendar"]}'

# Test connectivity
ansible -i inventory.yml vps -m ping

# List tasks without running them
ansible-playbook -i inventory.yml playbook.yml --list-tasks
```

`inventory.yml` is not declared in `ansible.cfg`, hence `-i inventory.yml`
on every command (or add `inventory = inventory.yml` under `[defaults]` in
`ansible.cfg`).

> `target_projects` only filters the `app-deploy` role. Every other role
> (SSH, firewall, nginx, PostgreSQL...) is replayed every time, which is
> safe since they are idempotent.

---

## 9. Adding a new project

1. **Pick** a unique `name`, a `subdomain` under `*.bylucas.eu` (no DNS
   action needed: the wildcard covers it) and a free `port` (next: 3006).
   Use lowercase for the subdomain (see §11).
2. **If it needs secrets**: `ansible-vault edit group_vars/all/vault.yml`
   and add `vault_<project>_xxx: "..."`.
3. **If it needs a database**: add an entry to `postgresql_app_users` and a
   `DATABASE_URL` in the project's `env_vars`.
4. **Declare the project** in `projects` (`group_vars/all/vars.yml`):

   ```yaml
   - name: my-api
     type: python
     path: /home/lucas/apps/my-api
     entrypoint: main.py
     subdomain: api.bylucas.eu
     port: 3006
     env_vars:
       PORT: "3006"
       SECRET_KEY: "{{ vault_my_api_secret_key }}"
   ```

5. **Run**:

   ```bash
   ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass -e '{"target_projects": ["my-api"]}'
   ```

   → folder, `.env`, service (failing "normally" since there's no code yet),
   vhost, HTTPS certificate, restart sudo rights.
6. **Add** `.github/workflows/deploy.yml` to the project's repo with
   `project_name: my-api`, `project_type: python`,
   `remote_path: /home/lucas/apps/my-api` (see `infra/github-actions/README.md`).
7. **`git push` to `main`** → code arrives, service starts, site is live.

Changing an existing project: changing `env_vars` → a targeted re-run is
enough (the `.env` is rewritten) **but you must then restart the service**
(`sudo systemctl restart <name>` or a push), because no handler does it.
Changing the vhost → see the Certbot procedure in §5.

Removing a project: removing it from `projects` **deletes nothing** on the
VPS. Do it by hand: `systemctl disable --now <name>`, delete the unit,
`sites-enabled/<name>`, `sites-available/<name>`, the folder,
`certbot delete --cert-name <subdomain>`, then re-run the playbook to
regenerate the manifests and the sudoers.

---

## 10. Idempotence: what is re-applied and what isn't

| Item | On playbook re-run |
|---|---|
| Packages, config files, templates (except vhosts) | Compared, rewritten only if different |
| Project `.env` files | Rewritten if values change (no automatic restart) |
| systemd units | Rewritten if the template changes → daemon-reload, **no restart** |
| Project services | `state: started`: started if stopped, never restarted |
| nginx vhosts | **Never** rewritten once managed by Certbot |
| Certificates | Never re-requested if they exist (`creates:`); renewed by `certbot.timer` |
| PostgreSQL users/DBs | Created if missing; password updated if it changes |
| Warp10 / Minecraft containers | Created **only if they don't exist**. Changing `warp10_version`, `warp10_heap`... has no effect while the container exists → `docker rm -f <name>` then re-run (data lives in the `/var/...-data` volumes) |
| Minecraft modpack / heap | `config.json` is never overwritten (`force: false`) → change the modpack from the panel. `minecraft_heap` is baked into `minecraft-ctl`: after a re-run, click "Appliquer" in the panel to recreate the container with the new heap |
| Swap | Created only if no swap is active |
| Node.js | Installed only if `node` is missing (never upgraded) |

---

## 11. Known pitfalls

- **Deployed key vs. connection key**: the inventory connects with
  `~/.ssh/bylucas`, but `ssh-hardening` installs `~/.ssh/id_ed25519.pub`.
  If that file doesn't exist on your machine, the task fails. Align them
  (e.g. `ssh_public_key_path: ~/.ssh/bylucas.pub` in `vars.yml`).
- **Secrets in `/etc/services-manifest.json`**: the manifest contains the
  whole resolved `projects` list (Warp10 tokens, DB password, `AUTH_SECRET`,
  basic auth password...) with mode 0644. If monitoring only needs
  names/ports/subdomains, filter the fields, or make the file 0640 with a
  dedicated group.
- **Local-only files**: `inventory.yml`, `vault.yml`, `private.yml` and
  `vault_pass.txt` are not in git (see §3). Losing them means rebuilding
  every secret by hand — keep a backup outside the repo.
- **`ollama` role**: present but **missing from `playbook.yml`**, so it never
  runs. To enable it, add it to the role list (before `app-deploy`). Note
  that in this role the `lineinfile` task adding `OLLAMA_HOST` fights with
  the `copy` task rewriting the same file: on every run each undoes the
  other and Ollama gets restarted. Better put `OLLAMA_HOST` directly in the
  `copy` content.
- **`subdomain` set to a raw IP**: Certbot is skipped (test use only).
- **DNS propagation**: Certbot (HTTP-01 challenge) fails if the subdomain
  doesn't resolve to the VPS yet. Just re-run.
- **Let's Encrypt limits**: one certificate per subdomain; too many failed
  attempts in a short time trigger a rate limit (1 h).
- **Uppercase in `subdomain`**: `catTree.bylucas.eu` works (DNS is
  case-insensitive), but Certbot lowercases domain names
  (`/etc/letsencrypt/live/catree.bylucas.eu/`). The path checked by
  `creates:` (`catTree...`) therefore never matches: Certbot runs on every
  play (it keeps the existing certificate, harmless), and the sudoers
  `--cert-name catTree.bylucas.eu` entries don't match the real certificate
  name. Use lowercase subdomains.
- **`large_transfers` on the existing `monitoring` vhost**: the vhost was
  already Certbot-managed, so the playbook didn't re-render it. The three
  lines were added by hand in the `location /` of the 443 block on
  2026-10-18 (backup: `/root/monitoring.nginx.bak-20261018-154609`), then
  `sudo nginx -t && sudo systemctl reload nginx`. On a fresh VPS the
  template handles it.
- **Docker and UFW**: a `-p 8080:8080` (without `127.0.0.1:`) would be
  publicly exposed despite UFW. Always prefix internal services with
  `127.0.0.1:`.
