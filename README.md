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
| `terraform/` | Hetzner, Cloudflare, Tailscale | Server + deny-all firewall, tunnel + its routes, proxied DNS records, the server's join key. State in R2. |
| `terraform/modules/hetzner-server` | | The only provider-specific code. Swap it to move to OVH or anywhere else. |
| `ansible/` | the VPS | Updates, OpenSSH off, Docker, nginx + cloudflared (`/opt/edge`), one compose project per app per env (`/opt/apps/<app>-<env>`). |
| `deploy-app` | `/usr/local/bin` on the VPS | `sudo deploy-app <app> <staging\|prod> <sha>`: pull, start, wait for health, roll back on failure. |
| `.github/workflows/infra.yml` | CI | PR → lint, `terraform plan`, `ansible --check --diff`. Merge → apply both. |
| `.github/workflows/deploy-app.yml` | CI, called by app repos | Joins the tailnet as `tag:ci`, runs `deploy-app`, smoke-tests the public URL. |
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

## One-time setup

### 1. Accounts and credentials

| What | Where | Used as |
|---|---|---|
| Hetzner API token (read & write) | Hetzner console → project → Security → API tokens | `HCLOUD_TOKEN` |
| Cloudflare API token: Zone › DNS › Edit on xlobax.com, Account › Cloudflare Tunnel › Edit | My Profile → API Tokens | `CLOUDFLARE_API_TOKEN` |
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
},
"grants": [
  { "src": ["tag:infra-ci", "tag:ci"], "dst": ["tag:server"], "ip": ["tcp:22"] },
],
"ssh": [
  { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:server"], "users": ["root", "deploy"] },
  { "action": "accept", "src": ["tag:infra-ci"],    "dst": ["tag:server"], "users": ["root"] },
  { "action": "accept", "src": ["tag:ci"],          "dst": ["tag:server"], "users": ["deploy"] },
],
```

`tag:ci` (app repos) gets in only as `deploy`, which may only run `deploy-app`. `tag:infra-ci` (this repo) gets root
because it runs Ansible.

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
3. Add the `TS_CI_OAUTH_CLIENT_ID` / `TS_CI_OAUTH_SECRET` secrets to the app repo.
4. **Home network:** add a `server=/<host>/#` line for both new hostnames to the Pi-hole split-horizon file
   (`homeserver:/docker/pihole/etc-dnsmasq.d/02-split-horizon.conf`), then `docker restart pihole`. Without it the
   site works everywhere except inside the house, where Pi-hole sends every `*.xlobax.com` name to the home server.
5. Merge to main and it's live on staging. Tag it and it's live on prod.

After the first push, check the image's package settings on GitHub: it must be public so the server can pull it
without credentials.

## Moving off Hetzner

Replace `terraform/modules/hetzner-server` (or create the box by hand), join it to the tailnet as `xlobax-vps` with
tag `tag:server`, and run Ansible. Nothing else changes.

## Later

- Maybe a separate domain for public projects, which would remove the Pi-hole exception step.
- Rename the arcade's `catan` / `monopoly` slugs to their parody names.
- Pin `cloudflared` to a version instead of `latest`.
- Backups for any app that keeps state, and uptime alerts.
