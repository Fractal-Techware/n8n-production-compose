# Contributing

Thanks for helping improve this stack.

- **Bug reports** (a service does not start, HTTPS does not come up, a setting is wrong for a
  current n8n release): open an issue with your Docker and Compose versions, the host OS, the
  relevant part of `docker compose logs` and your `.env` **with the secrets removed**.
- **Pull requests**: a change to `compose.yaml`, the `Caddyfile` or a script needs a matching
  assertion — `tests/check_stack.py` for anything visible in `docker compose config`,
  `tests/e2e.sh` for behaviour you can only see on a running stack, `tests/scripts_test.sh` for
  script behaviour. New image versions must be pinned to an exact tag in `compose.yaml` and
  updated in `tests/check_stack.py`.
- Run `./run-tests.sh` before opening the PR; CI runs exactly the same checks.

Conventions: no secret ever gets a default value, `.env.example` ships with empty secrets, no
service other than Caddy publishes a host port, and every container keeps its non-root user,
read-only root filesystem, dropped capabilities and resource limits.

Never attach a real `.env`, encryption key, database dump or workflow credential to an issue.

By contributing you agree that your contribution is licensed under the MIT License.
