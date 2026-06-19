# spire-dev

A single-container [SPIRE](https://spiffe.io/docs/latest/spire-about/) deployment for development and integration tests. Server + agent + bootstrap + JWKS publishing in one image, configured by environment variables, attesting peer containers via docker labels.

The image is meant for the case where you want to **issue real SVIDs to your services in `docker-compose`** — to test SPIFFE-aware code paths end-to-end — without standing up the full SPIRE production topology.

```yaml
services:
  spire:
    image: paulocosta56/spire-dev:1.13.0
    pid: host
    environment:
      SPIRE_TRUST_DOMAIN: test.local
      SPIRE_WORKLOADS: web api db
    volumes:
      - spire-sockets:/run/spire/sockets
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "8080:8080"   # JWKS endpoint (optional, expose if external)

  web:
    image: my/web
    labels: { io.spiffe.workload: web }
    volumes: [ "spire-sockets:/run/spire/sockets:ro" ]
    depends_on: { spire: { condition: service_healthy } }

  api:
    image: my/api
    labels: { io.spiffe.workload: api }
    volumes: [ "spire-sockets:/run/spire/sockets:ro" ]
    depends_on: { spire: { condition: service_healthy } }

  db:
    image: my/db
    labels: { io.spiffe.workload: db }
    volumes: [ "spire-sockets:/run/spire/sockets:ro" ]
    depends_on: { spire: { condition: service_healthy } }

volumes:
  spire-sockets:
```

`web`, `api`, and `db` receive distinct SVIDs — `spiffe://test.local/web`, `…/api`, `…/db` — via the Workload API at `/run/spire/sockets/agent.sock`. The JWT bundle is published as plain JWKS at `http://spire:8080/jwks.json`.

## What's inside

| Component | Purpose |
| --- | --- |
| `spire-server` (upstream `ghcr.io/spiffe/spire-server`) | Mints SVIDs. Bound to `127.0.0.1:8081`, in-memory CA, sqlite datastore. |
| `spire-agent` (upstream `ghcr.io/spiffe/spire-agent`) | Serves the Workload API on the unix socket. Uses the docker workload attestor. |
| `bootstrap` (in `run.sh`) | Waits for the server to be ready, mints a join token, registers one entry per declared workload, then exec's the agent. |
| `busybox httpd` + `jq` poller | Periodically extracts JWT signing keys from the trust bundle and serves them as a standard JWKS document at `/jwks.json`. |

Everything runs in one container under one entrypoint — restart the container and you get a fresh CA, fresh SVIDs, fresh JWKS.

## Configuration

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `SPIRE_TRUST_DOMAIN` | yes | — | Trust domain (e.g. `test.local`). |
| `SPIRE_WORKLOADS` | yes | — | Space-separated workload names. Each `<name>` becomes a SPIFFE ID `spiffe://${SPIRE_TRUST_DOMAIN}/<name>` and a docker-label selector. |
| `SPIRE_WORKLOAD_LABEL` | no | `io.spiffe.workload` | Docker label key used as the selector. Override to namespace your labels. |
| `SPIRE_JWKS_PORT` | no | `8080` | HTTP port for `/jwks.json`. |
| `SPIRE_JWKS_REFRESH_INTERVAL` | no | `30` | Seconds between JWKS regeneration. |

## Workload integration

A workload becomes attestable by:

1. Mounting the shared socket volume read-only:
   ```yaml
   volumes:
     - spire-sockets:/run/spire/sockets:ro
   ```
2. Setting a docker label whose key matches `SPIRE_WORKLOAD_LABEL` (default `io.spiffe.workload`) and whose value is one of the names in `SPIRE_WORKLOADS`:
   ```yaml
   labels:
     io.spiffe.workload: web
   ```
3. Reading `/run/spire/sockets/agent.sock` with any SPIFFE Workload API client (`spire-agent api fetch ...`, [`go-spiffe`](https://github.com/spiffe/go-spiffe), [`py-spiffe`](https://github.com/HewlettPackard/py-spiffe), etc.).

`pid: host` is required on the **spire** service because the docker workload attestor needs to read `/proc/<caller_pid>/cgroup` to map a connection back to its container. Workloads don't need `pid: host` themselves.

## The JWKS endpoint

`http://<host>:8080/jwks.json` returns the JWT trust bundle in standard JWKS format:

```json
{
  "keys": [
    { "kty": "EC", "kid": "...", "crv": "P-256", "x": "...", "y": "..." }
  ]
}
```

Any JWT library (`jose`, `jsonwebtoken`, `pyjwt`) can consume this URL to validate JWT-SVIDs issued by this server. The file is regenerated from `spire-server bundle show` every `SPIRE_JWKS_REFRESH_INTERVAL` seconds.

If you don't need JWKS publication, ignore the port — the endpoint runs internally but doesn't need to be exposed.

## Health checks

The image ships a `HEALTHCHECK` that probes both processes' `/ready` endpoints (server `:9091`, agent `:9092`). You don't need to add one in compose — `depends_on: { spire: { condition: service_healthy } }` works out of the box.

Override only if your stack needs a different `interval`/`start_period` (defaults: `3s` / `30s`).

## Versioning

Image tags track the upstream SPIRE release the image is built from. On every push to `main`, CI extracts the version from the Dockerfile's `FROM ghcr.io/spiffe/spire-server:<version>` line and publishes:

- `paulocosta56/spire-dev:<full>`  — e.g. `1.15.1`, exact pin
- `paulocosta56/spire-dev:<major>.<minor>` — e.g. `1.15`, moving
- `paulocosta56/spire-dev:<major>` — e.g. `1`, moving
- `paulocosta56/spire-dev:latest` — moving

No separate git tag is needed. The flow is:

1. Dependabot opens a daily PR bumping both `FROM` lines together (grouped via `.github/dependabot.yml`).
2. CI runs the integration tests on the PR.
3. You merge the PR.
4. CI on `main` reads the new version straight from the Dockerfile and pushes the full tag set above to Docker Hub.

## Limitations

- **Tests and dev only.** The server's CA key lives in process memory and the sqlite datastore lives inside the container — restart and everything rotates. Use real SPIRE for production.
- **Workload registration is static.** The set of workloads is fixed at container start by `SPIRE_WORKLOADS`. New workloads brought up later have to wait for a restart (or for the agent's sync to pick up entries you add via `spire-server entry create` against the admin socket).
- **Workloads come up after the spire container** in compose; the agent picks up their docker labels on its next sync cycle, so a workload that fetches an SVID the instant it starts may need to retry.

## License

MIT — see `LICENSE`.

## Contributing

Source: <https://github.com/paulo-raca/spire-dev>. CI runs on every push and verifies that workloads get the right SVID and the JWKS endpoint serves valid keys before tagging an image. Issues and PRs welcome.
