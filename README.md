# app-recipes

Install scripts for self-hosted apps on a fresh Ubuntu 24.04 server. One command installs one app, creates its admin account, and prints the generated credentials once.

These are the installers behind the one-click apps at [VMArea](https://vmarea.com). They run standalone on any server you control.

## Supported systems

- Ubuntu 24.04 LTS, x86_64
- Root access (`sudo`), outbound internet access, `python3` (included in Ubuntu Server)
- A fresh server. The installers assume they own the machine: they install packages, write service configuration and bind ports 80 and 443.

## Quick start

```bash
git clone https://github.com/VMArea/app-recipes.git
cd app-recipes
sudo ./install.sh --list
sudo ./install.sh wordpress
```

With a domain (the DNS record must already point at the server):

```bash
sudo ./install.sh wordpress --domain example.com
```

Options:

| Option | Meaning |
|---|---|
| `--domain <name>` | Serve the app on this domain with a Let's Encrypt certificate. |
| `--public-ip <ipv4>` | Address to advertise when the server is behind NAT. Default: the primary IPv4 address. |
| `--credentials-file <path>` | Write the credentials to this file (mode 0600) instead of printing them. |
| `--list` | List the apps. |

The script checks the OS, runs the app's installer under a time limit, waits for the app's health check, then prints the results. It does not configure a firewall; open the ports listed below yourself.

## Apps

Minimum spec is what each installer was tested with. Ports are the ones to open besides SSH; everything else listens on `127.0.0.1` only.

| App | Slug | Version | Minimum spec | Ports | Upstream licence |
|---|---|---|---|---|---|
| AnythingLLM | `anythingllm` | 1.18.0 | 2 vCPU, 2 GB, 15 GB | 80, 443 | MIT |
| Docker CE | `docker-ce` | 29.9.2 | 1 vCPU, 1 GB, 10 GB | none | Apache-2.0 |
| Ghost | `ghost` | 6.72.0 (MySQL 8.4.13) | 1 vCPU, 2 GB, 15 GB | 80, 443 | MIT (MySQL GPL-2.0) |
| Gitea | `gitea` | 28.2.0 | 1 vCPU, 1 GB, 10 GB | 80, 443 | MIT |
| Grafana + Prometheus | `grafana-prometheus` | Grafana OSS 13.2.4, Prometheus 3.15.1, node-exporter 1.12.1 | 1 vCPU, 2 GB, 15 GB | 80, 443 | AGPL-3.0-only (Grafana); Apache-2.0 (Prometheus, node-exporter) |
| LEMP stack | `lemp` | Ubuntu 24.04 packages | 1 vCPU, 1 GB, 10 GB | 80 | BSD-2-Clause (nginx); GPL-2.0 (MariaDB); PHP-3.01 (PHP) |
| LibreChat | `librechat` | 0.8.8 (FerretDB 2.7.0) | 2 vCPU, 4 GB, 20 GB | 80, 443 | MIT (FerretDB Apache-2.0) |
| Nextcloud | `nextcloud` | 35.0.2 (MariaDB 11.8.9, Redis 7.2.9) | 2 vCPU, 2 GB, 20 GB | 80, 443 | AGPL-3.0-or-later (MariaDB GPL-2.0, Redis 7.2.9 BSD-3-Clause) |
| Ollama + Open WebUI | `ollama-open-webui` | Open WebUI 0.12.3, Ollama 0.40.11 | 4 vCPU, 8 GB, 40 GB | 80, 443 | Open WebUI licence (BSD-3-Clause with a branding clause); MIT (Ollama) |
| Portainer CE | `portainer-ce` | 2.45.3 | 1 vCPU, 1 GB, 10 GB | 80, 443 | Zlib |
| Uptime Kuma | `uptime-kuma` | 2.5.7 | 1 vCPU, 1 GB, 10 GB | 80, 443 | MIT |
| Vaultwarden | `vaultwarden` | 1.37.4 | 1 vCPU, 1 GB, 10 GB | 80, 443 | AGPL-3.0-only |
| WireGuard (wg-easy) | `wg-easy` | 15.4.0 | 1 vCPU, 1 GB, 10 GB | 80, 443, 51820/udp | AGPL-3.0-only |
| WordPress | `wordpress` | 7.1.3 (WP-CLI 2.12.0) | 1 vCPU, 1 GB, 10 GB | 80 | GPL-2.0-or-later (WP-CLI MIT) |

Each `apps/<slug>/recipe.json` holds the full details, including the licence notes of every bundled component.

## Upstream licences and trademarks

The scripts in this repository are MIT licensed (see `LICENSE`). The apps they install are not ours and keep their own licences, listed above. Apps are installed unmodified from upstream: from the project's official container image, release archive, or the Ubuntu or Docker package repositories. Nothing is patched or rebranded.

Check an app's licence before you rely on it. Open WebUI's licence forbids altering or removing its name and logo, and the installer leaves its branding untouched. The AGPL apps (Grafana, Nextcloud, Vaultwarden, wg-easy) require you to offer the source of any modified version to users of the service.

All product names, logos and trademarks belong to their respective owners. Their use here identifies the software only and implies no affiliation with or endorsement by those owners.

## How credentials work

- Secrets are generated on the server from `/dev/urandom` when the installer runs. They are not in this repository and never leave the machine.
- When the installer finishes it prints the app URL and the generated credentials once. With `--credentials-file` they are written to that file with mode 0600 instead.
- The install log, `/var/log/vmarea-app-install.log` (mode 0600), does not contain them.
- Generated values are kept in `/var/lib/vmarea/recipe-secrets` (root only) so a repeat run reuses them instead of locking you out. Running the installer again prints the credentials again.
- The admin account is created by the installer, so there is no setup page waiting for the first visitor. Public sign-up is turned off where the app allows it.

## What the installers do

- Versions are pinned. Container images are pinned by tag and sha256 digest; the Docker repository key, the Caddy and WP-CLI downloads and the WordPress archive are checked against published fingerprints or checksums before use.
- Apps that need HTTPS sit behind Caddy: Let's Encrypt with `--domain`, a self-signed certificate on the bare IP otherwise. WordPress and LEMP use nginx with certbot; with a domain, a systemd timer retries every hour until DNS resolves. The Let's Encrypt path needs public DNS and is not part of the automated tests.
- Internal services (databases, metrics, admin APIs) listen on `127.0.0.1` or a private container network.
- Security updates are enabled with `unattended-upgrades` where the installer manages the host.
- A health check must pass before the installer reports success.
- Installers can be run again after a failure. There is no uninstaller; use a fresh server to start over.

## Contributing

See `CONTRIBUTING.md`. New apps need a pinned version, a checked licence and a test on a fresh server.

## Security

Report vulnerabilities to hello@vmarea.com. See `SECURITY.md`.

## Licence

MIT. Copyright (c) 2026 RENEWBYTE LABS LTD.
