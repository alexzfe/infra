# infra

Everything that runs my public projects on one VPS, in code. If the server dies, this repo rebuilds it.

```
visitor ──HTTPS──▶ Cloudflare (CDN, TLS) ──tunnel──▶ cloudflared ─▶ nginx ─▶ app containers
                                                      └──────────── Hetzner CX23 ───────────┘
me / CI ──Tailscale SSH──▶ same box            (no inbound ports open to the internet)
```

| Piece | Where | Does |
|---|---|---|
| `sites.yml` | repo root | The list of apps and hostnames. Both Terraform and Ansible read it. |
| `terraform/` | Hetzner, Cloudflare, Tailscale | Server + deny-all firewall, tunnel + its routes, proxied DNS records, HSTS, the server's join key. State in R2. |
| `terraform/modules/hetzner-server` | | The only provider-specific code. Swap it to move to OVH or anywhere else. |
| `ansible/` | the VPS | Updates, OpenSSH off, Docker, nginx + cloudflared (`/opt/edge`), one compose project per app per env (`/opt/apps/<app>-<env>`). |
| `deploy-app` | `/usr/local/bin` on the VPS | `sudo deploy-app <app> <staging\|prod> <sha>`: pull, start, wait for health, roll back on failure. One deploy per app-env at a time. |
| `.github/workflows/infra.yml` | CI | PR → lint, `terraform plan`, `ansible --check --diff`. Merge → apply both. |
| `.github/workflows/drift.yml` | CI, nightly | Fails (and emails) if `terraform plan` or `ansible --check` would change anything. |
| `.github/workflows/deploy-app.yml` | CI, called by app repos | Joins the tailnet as `tag:ci`, runs `deploy-app`, smoke-tests the public URL. |
| `.github/workflows/backups.yml` | CI, daily | Fails (and GitHub emails) if the homeserver hasn't stored an app's backup in 26 hours. |
| `homeserver/` | copy to the homeserver | The nightly backup pull. Not managed by Ansible: installed by hand, see [Backups](#backups). |
| `templates/` | copy into app repos | `release.yml` (the release flow) and a static-site Dockerfile. |

Hostnames: `<app>.xlobax.com` is prod and `<app>-staging.xlobax.com` is staging (the website uses `xlobax.com` and
`staging.xlobax.com`). They stay one level deep because Cloudflare's free certificate only covers `*.xlobax.com`.

## Release flow (app repos)

```
feature branch ─PR─▶ main ──▶ build ghcr.io/alexzfe/<repo>:<sha> ──▶ staging (auto)
                                                                       │ test it
                                         git tag v1.2.0 && git push --tags
                                                                       ▼
                                                     prod runs the same image ──▶ GitHub Release
```

Roll back by re-running the prod deploy of the previous tag, or on the box: `sudo deploy-app arcade prod <old-sha>`.

## Tools

`mise install` installs the pinned Terraform, ansible-core, ansible-lint and shellcheck from `mise.toml`, then
`ansible-galaxy collection install -r ansible/requirements.yml`.

Everything is pinned: actions to commit SHAs, tools, the Ansible collection, providers (lock file) and the edge
images. [Renovate](https://github.com/apps/renovate) proposes bumps as PRs once a release is a week old
(`renovate.json`), so updates go through the same plan/check as any other change.

## One-time setup

### 1. Accounts and credentials

| What | Where | Used as |
|---|---|---|
| Hetzner API token (read & write) | Hetzner console → project → Security → API tokens | `HCLOUD_TOKEN` |
| Cloudflare API token: Zone › DNS › Edit, Zone › Zone Settings › Edit and Zone › Cache Rules › Edit on xlobax.com, Account › Cloudflare Tunnel › Edit | My Profile → API Tokens | `CLOUDFLARE_API_TOKEN` |
| Cloudflare API token: Zone › Cache Purge › Purge on xlobax.com only | My Profile → API Tokens | app repos' `CLOUDFLARE_PURGE_TOKEN` (apps with `edge_cache`) |
| R2 bucket `xlobax-tfstate` + an R2 API token (Object Read & Write, that bucket only) | R2 → Manage API tokens | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Tailscale OAuth client **infra**: scopes Auth Keys (write) + Devices Core (write), tag `tag:infra-ci` only. It mints `tag:server` keys because the policy makes `tag:infra-ci` an owner of `tag:server`; a client with both tags could only mint keys carrying both | Tailscale admin → Settings → OAuth clients | `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET` |
| Tailscale OAuth client **ci**: scope `auth_keys` (write), tag `tag:ci` | same | app repos' `TS_CI_OAUTH_*` |

Fill the account ID into `terraform/backend.hcl` and the account + zone IDs into `terraform/terraform.tfvars`.

If `xlobax.com` or `staging.xlobax.com` already has a record in Cloudflare, delete it first, or the first apply
fails on the conflict. The home `*.xlobax.com` wildcard can stay: explicit records win over it.

### 2. Tailscale policy

The full policy is in `tailscale-policy.hujson`; `wl-copy < tailscale-policy.hujson` and paste it into the admin console.

**Merge** this into the existing tailnet policy; don't replace it. If the policy is still the default allow-all,
the CI nodes could reach every home device, so give them explicit rules like these and make sure no broader rule
covers `tag:ci` / `tag:infra-ci`.

```jsonc
"tagOwners": {
  "tag:server":   ["autogroup:admin"],
  "tag:infra-ci": ["autogroup:admin"],
  "tag:ci":       ["autogroup:admin"],
  "tag:backup":   ["autogroup:admin"],
},
"grants": [
  { "src": ["tag:infra-ci", "tag:ci"], "dst": ["tag:server"], "ip": ["tcp:22"] },
  { "src": ["tag:backup"],             "dst": ["tag:server"], "ip": ["tcp:22"] },
],
"ssh": [
  { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:server"], "users": ["root", "deploy"] },
  { "action": "accept", "src": ["tag:infra-ci"],    "dst": ["tag:server"], "users": ["root"] },
  { "action": "accept", "src": ["tag:ci"],          "dst": ["tag:server"], "users": ["deploy"] },
  { "action": "accept", "src": ["tag:backup"],      "dst": ["tag:server"], "users": ["backup-pull"] },
],
```

`tag:ci` (app repos) gets in only as `deploy`, whose login shell (`deploy-shell`) accepts nothing but
`deploy-app <app> <env> <tag>`. `tag:infra-ci` (this repo) gets root because it runs Ansible. `tag:backup` (the
homeserver's backup puller) gets in only as `backup-pull`, whose login shell accepts nothing but
`backup-app <app> [stored]`.

### 3. First bring-up, from the laptop

```sh
export HCLOUD_TOKEN=… CLOUDFLARE_API_TOKEN=… AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…
export TAILSCALE_OAUTH_CLIENT_ID=… TAILSCALE_OAUTH_CLIENT_SECRET=…

terraform -chdir=terraform init -backend-config=backend.hcl
terraform -chdir=terraform apply
# wait about a minute for `xlobax-vps` to appear in the tailnet, then:
cd ansible && TUNNEL_TOKEN=$(terraform -chdir=../terraform output -raw tunnel_token) ansible-playbook site.yml
```

### 4. Hand over to CI

Push to `github.com/alexzfe/infra` (public). Then:

- Add the secrets `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
  `TS_INFRA_OAUTH_CLIENT_ID`, `TS_INFRA_OAUTH_SECRET`.
- Create a `production` environment.
- Protect `main`: require a PR and the `lint` and `plan` checks.

From then on, infra changes go through PRs like app code.

## Adding an app

1. Add it to `sites.yml` and merge. CI creates the DNS records, tunnel routes, nginx routes and compose files.
2. In the app repo, copy `templates/app-release.yml` to `.github/workflows/release.yml` and adjust the names and
   URLs. Add a Dockerfile that serves on `:8080` (`templates/static-site.Dockerfile` for static sites).
   With `edge_cache: true`, pass `purge_cache: true` to every deploy-app call and add the `CLOUDFLARE_PURGE_TOKEN`
   secret to the app repo, or the edge keeps serving the previous release.
3. Add the `TS_CI_OAUTH_CLIENT_ID` / `TS_CI_OAUTH_SECRET` secrets to the app repo.
4. **Home network:** add a `server=/<host>/#` line for both new hostnames to the Pi-hole split-horizon file
   (`homeserver:/docker/pihole/etc-dnsmasq.d/02-split-horizon.conf`), then `docker restart pihole`. Without it the
   site works everywhere except inside the house, where Pi-hole sends every `*.xlobax.com` name to the home server.
5. Merge to main and it's live on staging. Tag it and it's live on prod.

After the first push, check the image's package settings on GitHub: it must be public so the server can pull it
without credentials.

An app that keeps data, needs env vars, uploads big files or streams responses says so in `sites.yml`: `volume`,
`env`, `max_body_size`, `stream_paths` and the rest are described at the top of that file, and Settle uses them all.
A volume is `<app>-<env>-data`, created by Ansible and never removed by a deploy, a rollback or an app leaving
`sites.yml`. There are no secrets: `env` is for plain settings only, since this repo is public.

## Backups

Apps with `backup` in `sites.yml` (Settle) are backed up nightly to the homeserver. The homeserver pulls; the VPS
holds no homeserver credential, so a broken-into VPS can't reach or delete the backups.

```
homeserver ──tag:backup, Tailscale SSH as backup-pull──▶ VPS: sudo backup-app settle ─▶ docker compose exec … backup
     └── /srv/backups/settle/{daily,weekly}/   (14 daily, 8 weekly)
```

The puller is a second `tailscaled` on the homeserver, in userspace mode and tagged `tag:backup`, so the policy can
let it reach the VPS's SSH as `backup-pull` and nothing else, while the homeserver itself stays an ordinary device.
Once it has stored and checked an archive, it runs `backup-app <app> stored`, and the daily `backups` workflow fails
if that mark is older than 26 hours.

### Installing it on the homeserver (once)

As root on the homeserver, from a checkout of this repo:

```sh
install -m 0755 homeserver/pull-backup /usr/local/bin/
install -m 0644 homeserver/tailscaled-backup.service 'homeserver/pull-backup@.service' \
  'homeserver/pull-backup@.timer' /etc/systemd/system/
install -d -m 0700 /srv/backups
systemctl daemon-reload
systemctl enable --now tailscaled-backup.service
# Tailscale admin → Settings → Keys → auth key: tag tag:backup, not reusable, not ephemeral.
tailscale --socket=/run/tailscale-backup/tailscaled.sock up --hostname=homeserver-backup \
  --advertise-tags=tag:backup --auth-key=tskey-auth-…
systemctl start pull-backup@settle.service     # a first pull now; then check /srv/backups/settle/daily
systemctl enable --now pull-backup@settle.timer
```

`tailscaled-backup.service` expects `tailscaled` at `/usr/sbin/tailscaled` (Debian and Ubuntu packages); adjust
`ExecStart` if `command -v tailscaled` says otherwise. Change `BACKUP_DIR` in `pull-backup@.service` to keep the
archives elsewhere, and add the path to its `ReadWritePaths`.

### Restoring Settle

Settle's archive is its whole `/data`: the database snapshot, `uploads/` and `rendered/`. With the app stopped:

```sh
cd /opt/apps/settle-prod && docker compose stop
docker run --rm -i -v settle-prod-data:/data -w /data alpine \
  sh -c 'rm -rf /data/* && tar -xzf - && chown -R 1000:1000 /data' < settle-2026-10-23.tgz
docker compose start
```

## Moving off Hetzner

Replace `terraform/modules/hetzner-server` (or create the box by hand), join it to the tailnet as `xlobax-vps` with
tag `tag:server`, and run Ansible. Nothing else changes.

## Later

- Maybe a separate domain for public projects, which would remove the Pi-hole exception step.
- Rename the arcade's `catan` / `monopoly` slugs to their parody names.
- Uptime alerts.
