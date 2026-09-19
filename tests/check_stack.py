#!/usr/bin/env python3
"""Static assertions on the resolved Compose stack (stdlib only, no PyYAML).

Reads `docker compose config --format json` — the fully resolved configuration Docker itself
would run — and asserts the properties this stack promises: pinned images, no published ports
except Caddy's, an internal backend network, hardened containers, healthchecks, resource limits
and no secrets committed to the repository.

    python3 tests/check_stack.py            # run-tests.sh generates a .env and calls this
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
N8N_VERSION = "2.39.7"
EXPECTED_IMAGES = {
    "postgres": "postgres:17.11-alpine",
    "n8n": f"n8nio/n8n:{N8N_VERSION}",
    "n8n-runner": f"n8nio/runners:{N8N_VERSION}",
    "caddy": "caddy:2.11.4",
    "caddy-init": "caddy:2.11.4",
}
# Services that run the hardened profile: read-only root, non-root user, no-new-privileges,
# all capabilities dropped, a healthcheck and a memory limit.
HARDENED = {"postgres": "70:70", "n8n": "1000:1000", "n8n-runner": "1000:1000",
            "caddy": "1000:1000"}

failures = []


def check(condition, message):
    print(f"  {'ok  ' if condition else 'FAIL'} {message}")
    if not condition:
        failures.append(message)


def compose_cmd():
    """`docker compose` (v2 plugin) if it works, otherwise the standalone `docker-compose`."""
    for cmd in (["docker", "compose"], ["docker-compose"]):
        probe = subprocess.run(cmd + ["version"], capture_output=True)
        if probe.returncode == 0:
            return cmd
    sys.exit("Docker Compose is required (https://docs.docker.com/compose/install/)")


def main():
    env_file = os.environ.get("ENV_FILE", os.path.join(ROOT, ".env"))
    out = subprocess.run(
        compose_cmd() + ["--env-file", env_file, "config", "--format", "json"],
        cwd=ROOT, capture_output=True, text=True,
    )
    if out.returncode != 0:
        print(out.stderr.strip())
        sys.exit("docker compose config failed")
    cfg = json.loads(out.stdout)
    services = cfg["services"]

    print("==> services and images")
    check(set(services) == set(EXPECTED_IMAGES), f"services are {sorted(EXPECTED_IMAGES)}")
    for name, image in EXPECTED_IMAGES.items():
        svc = services.get(name, {})
        check(svc.get("image") == image, f"{name}: image pinned to {image}")
    check(not any(":latest" in s.get("image", "") or ":" not in s.get("image", "")
                  for s in services.values()), "no :latest or untagged image")

    print("==> container hardening")
    for name, user in HARDENED.items():
        svc = services.get(name, {})
        check(svc.get("read_only") is True, f"{name}: read-only root filesystem")
        check(svc.get("user") == user, f"{name}: runs as {user} (non-root)")
        check("no-new-privileges:true" in (svc.get("security_opt") or []),
              f"{name}: no-new-privileges")
        check(svc.get("cap_drop") == ["ALL"], f"{name}: all capabilities dropped")
        check(bool(svc.get("healthcheck", {}).get("test")), f"{name}: has a healthcheck")
        limits = ((svc.get("deploy") or {}).get("resources") or {}).get("limits") or {}
        check(bool(limits.get("memory")) and bool(limits.get("cpus")),
              f"{name}: cpu and memory limits set ({limits.get('cpus')} / {limits.get('memory')})")
        check(svc.get("restart") == "unless-stopped", f"{name}: restart policy")
    check(services["caddy"].get("cap_add") == ["NET_BIND_SERVICE"],
          "caddy: only NET_BIND_SERVICE added back")
    check(services["caddy-init"].get("cap_add") == ["CHOWN"] and
          services["caddy-init"].get("restart") == "no",
          "caddy-init: one-shot, CHOWN only")

    print("==> network exposure")
    for name, svc in services.items():
        ports = svc.get("ports") or []
        if name == "caddy":
            published = sorted(str(p.get("published")) for p in ports)
            check(published == ["443", "80"], f"caddy publishes 80 and 443 only ({published})")
        else:
            check(not ports, f"{name}: publishes no host port")
    check(cfg["networks"]["backend"].get("internal") is True,
          "backend network is internal (no route to the host or the internet)")
    check(sorted(services["postgres"]["networks"]) == ["backend"],
          "postgres is on the backend network only")
    check(sorted(services["caddy"]["networks"]) == ["edge"], "caddy is on the edge network only")
    check(sorted(services["n8n"]["networks"]) == ["backend", "edge"],
          "n8n bridges backend and edge, but publishes nothing")
    check(sorted(services["n8n-runner"]["networks"]) == ["backend"],
          "the task runner is on the backend network only")

    print("==> n8n configuration")
    env = services["n8n"]["environment"]
    expected_env = {
        "DB_TYPE": "postgresdb",
        "N8N_PROTOCOL": "https",
        "N8N_PROXY_HOPS": "1",
        "N8N_SECURE_COOKIE": "true",
        "N8N_DIAGNOSTICS_ENABLED": "false",
        "N8N_BLOCK_ENV_ACCESS_IN_NODE": "true",
        "N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES": "true",
        "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS": "true",
        "N8N_UNVERIFIED_PACKAGES_ENABLED": "false",
        "EXECUTIONS_DATA_PRUNE": "true",
        "N8N_RUNNERS_MODE": "external",
    }
    for key, value in expected_env.items():
        check(env.get(key) == value, f"n8n: {key}={value}")
    check(bool(env.get("N8N_ENCRYPTION_KEY")) and bool(env.get("DB_POSTGRESDB_PASSWORD")),
          "n8n: encryption key and database password come from .env")
    check(env.get("N8N_RUNNERS_AUTH_TOKEN") ==
          services["n8n-runner"]["environment"].get("N8N_RUNNERS_AUTH_TOKEN") and
          bool(env.get("N8N_RUNNERS_AUTH_TOKEN")),
          "n8n and the task runner share the generated broker token")
    check(int(env.get("EXECUTIONS_TIMEOUT", 0)) > 0, "n8n: executions have a timeout")
    check(services["n8n"].get("stop_grace_period") is not None,
          "n8n: graceful shutdown period set")
    check(services["n8n"]["depends_on"]["postgres"]["condition"] == "service_healthy",
          "n8n waits for a healthy postgres")

    print("==> persistence")
    volumes = set(cfg.get("volumes", {}))
    check({"postgres_data", "n8n_data", "caddy_data"} <= volumes,
          "named volumes for the database, n8n state and Caddy certificates")

    print("==> no secrets in the repository")
    secret_re = re.compile(r"^(N8N_ENCRYPTION_KEY|POSTGRES_PASSWORD|N8N_RUNNERS_AUTH_TOKEN)=.+$", re.M)
    for path in ("compose.yaml", ".env.example", "Caddyfile", "README.md"):
        text = open(os.path.join(ROOT, path)).read()
        check(not secret_re.search(text), f"{path}: no filled-in secret")
    check(".env" in open(os.path.join(ROOT, ".gitignore")).read(), ".gitignore excludes .env")

    print()
    if failures:
        print(f"{len(failures)} check(s) failed")
        sys.exit(1)
    print("stack checks passed")


if __name__ == "__main__":
    main()
