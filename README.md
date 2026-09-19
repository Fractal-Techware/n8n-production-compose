# Self-host n8n properly: a hardened Docker Compose stack with automatic HTTPS, generated secrets and tests that start it for real

[![test](https://github.com/Fractal-Techware/n8n-production-compose/actions/workflows/test.yml/badge.svg)](https://github.com/Fractal-Techware/n8n-production-compose/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![n8n 2.39.7](https://img.shields.io/badge/n8n-2.39.7-ea4b71)
![PostgreSQL 17.11](https://img.shields.io/badge/postgresql-17.11-336791?logo=postgresql&logoColor=white)
![Caddy 2.11.4](https://img.shields.io/badge/caddy-2.11.4-1f88c0)
![checks: 120](https://img.shields.io/badge/checks-120%20passing-brightgreen)

The n8n docs give you a `docker run` line. This gives you the deployment: **n8n 2.39.7 with an
external task runner, PostgreSQL 17 and Caddy terminating HTTPS**, in one Compose file where
every container is locked down and every secret is generated on your machine.

- **HTTPS that renews itself** — Caddy gets and renews a Let's Encrypt / ZeroSSL certificate for
  your domain, sets HSTS and `nosniff`, hides its `Server` header and never exposes `/metrics`
- **Nothing is reachable but Caddy** — n8n, the task runner and PostgreSQL sit on an `internal`
  Docker network; only ports 80 and 443 are published, and you can bind them to one interface
- **Every container hardened** — non-root user, read-only root filesystem, `no-new-privileges`,
  all capabilities dropped (Caddy gets `NET_BIND_SERVICE` back, and nothing else), CPU and
  memory limits, healthchecks and log rotation
- **No default passwords anywhere** — `scripts/init-secrets.sh` generates a 64-hex encryption
  key, database password and task-runner token into a `chmod 600` `.env`, and refuses to
  overwrite one (rotating the encryption key would orphan every stored credential)
- **`scripts/check-config.sh`** catches the mistakes that cost you an evening: a public URL that
  does not match the domain, plain `http`, a trailing slash, a weak or reused secret, a
  world-readable `.env`, a placeholder left in place
- **Production defaults for n8n itself** — execution timeouts, automatic pruning, a concurrency
  limit, secure cookies, `N8N_PROXY_HOPS=1`, telemetry off, file and env access restricted, the
  Code node isolated in the runner container, graceful shutdown
- **120 checks you can run** — including an end-to-end test that starts this exact stack, curls
  it over HTTPS and inspects the running containers

By [Fractal Techware](https://fractaltechware.gumroad.com/?utm_source=github&utm_medium=readme&utm_campaign=free-repo). MIT licensed.

## What's included

| File | What it does |
|---|---|
| [`compose.yaml`](compose.yaml) | The stack: PostgreSQL 17.11, n8n 2.39.7, the n8n task runner 2.39.7, Caddy 2.11.4 (plus a one-shot init container for Caddy's volumes) |
| [`Caddyfile`](Caddyfile) | Automatic HTTPS, security headers, streaming-friendly reverse proxy, `/metrics` blocked |
| [`.env.example`](.env.example) | Every setting you can change, with comments — secrets ship empty |
| [`scripts/init-secrets.sh`](scripts/init-secrets.sh) | Generates `.env` with random secrets, mode 600, never overwrites |
| [`scripts/check-config.sh`](scripts/check-config.sh) | Pre-flight check of `.env` and the stack; exit 0 means it is safe to start |
| [`tests/scripts_test.sh`](tests/scripts_test.sh) | 22 assertions on the two scripts (generation, refusal to overwrite, every rejection rule) |
| [`tests/check_stack.py`](tests/check_stack.py) | 69 assertions on the resolved `docker compose config`: pinned images, exposure, hardening, limits, n8n settings, no committed secrets |
| [`tests/e2e.sh`](tests/e2e.sh) | 29 assertions against a running stack: HTTPS, headers, `/healthz`, database isolation, container hardening, restart recovery |
| [`run-tests.sh`](run-tests.sh) | Everything CI runs (`--static` skips the end-to-end test) |

4 services · 1 Compose file · 2 scripts · 120 checks.

## Quick start (60 seconds)

```bash
git clone https://github.com/Fractal-Techware/n8n-production-compose.git
cd n8n-production-compose

./scripts/init-secrets.sh      # writes .env with generated secrets (mode 600)
$EDITOR .env                   # set N8N_DOMAIN, N8N_PUBLIC_URL, CADDY_TLS (your ACME email)
./scripts/check-config.sh      # must print "Configuration looks good"
docker compose up -d
```

Point your domain's A/AAAA record at the host and open ports 80 and 443 **before** the first
start: Caddy needs them to complete the ACME challenge. Then open `https://<your domain>` and
create the owner account.

**Store `N8N_ENCRYPTION_KEY` in your password manager now.** Without it, a database dump cannot
decrypt a single credential.

Trying it on a laptop first? Set `CADDY_TLS=internal`, `N8N_DOMAIN=localhost`,
`N8N_PUBLIC_URL=https://localhost` and `BIND_ADDRESS=127.0.0.1`; Caddy issues its own
certificate and your browser will warn once.

### Run the tests

```bash
./run-tests.sh --static     # ~10 seconds, no images pulled
./run-tests.sh              # adds the end-to-end test: starts the stack, ~4 minutes
```

The end-to-end test runs on a throwaway copy under its own project name and ports, so it never
touches your `.env`, your containers or your volumes.

### Day 2

```bash
docker compose logs -f n8n                 # logs
docker compose pull && docker compose up -d # upgrade (pin the new tags in compose.yaml first)
docker compose exec -T postgres pg_dump -U n8n n8n | gzip > n8n-$(date +%F).sql.gz
```

That `pg_dump` line plus your `N8N_ENCRYPTION_KEY` is the minimum viable backup — it is not a
tested restore procedure. Scheduled backups, restore verification and an upgrade runbook are in
the paid kit below.

## What this is not

Honest limits, so you know what you are adopting:

- **One host, one n8n process.** Fine for most teams; it is not queue mode, so executions are
  not spread over workers and a restart interrupts running executions.
- **No monitoring stack.** n8n's Prometheus endpoint stays off and unexposed; there is no
  Prometheus, Grafana or alerting here.
- **No backup/restore scripts** and no Kubernetes. See the kit if you need those.
- **Secrets live in `.env`**, not in a secret manager. It is mode 600 and gitignored.

Everything that *is* here is tested, pinned and meant for production use.

## Want the full kit?

This stack is the free, MIT-licensed sample of the
**[n8n Production Self-Hosting Kit](https://fractaltechware.gumroad.com/l/n8n-production-kit?utm_source=github&utm_medium=readme&utm_campaign=free-repo)**.

| | **Free** (this repo) | **Starter** $19 | **Pro** $49 | **Studio** $99 |
|---|:---:|:---:|:---:|:---:|
| Hardened single-instance stack (n8n + runner + PostgreSQL + Caddy) | yes | yes | yes | yes |
| Generated secrets, config check, HTTPS | yes | yes | yes | yes |
| Backup + restore scripts, install guide, upgrade runbook, security checklist, env reference | – | yes | yes | yes |
| Queue mode: main, webhook processors, workers with their own runners, Valkey | – | – | yes | yes |
| Prometheus scrape config, 16 alert rules with promtool tests, 20-panel Grafana dashboard | – | – | yes | yes |
| Scheduled backups with restore verification, scaling and logging guides | – | – | yes | yes |
| `ftw-n8n` Helm chart (HPA, PDBs, NetworkPolicies, ServiceMonitor, PrometheusRule) | – | – | – | yes |
| Git-based workflow promotion with CI, Kubernetes sizing guide, client delivery checklist | – | – | – | yes |
| License | MIT | own organization | own organization | client / agency use |

[See the full kit on Gumroad →](https://fractaltechware.gumroad.com/l/n8n-production-kit?utm_source=github&utm_medium=readme&utm_campaign=free-repo)
· More free, tested infrastructure repos at [github.com/Fractal-Techware](https://github.com/Fractal-Techware)

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Changes to the
stack need a matching assertion in `tests/`.

## License

[MIT](LICENSE) © Fractal Techware SRL. n8n itself is distributed under the
[Sustainable Use License](https://github.com/n8n-io/n8n/blob/master/LICENSE.md) — this repository
only configures it.
