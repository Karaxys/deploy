# Karaxys Deploy

Deployment orchestration for the Karaxys platform.

This repo owns Compose, Kubernetes, Helm, environment templates, deployment
scripts, observability, and runbooks. Application source code stays in the
service repos:

- `../karaxys_backend`
- `../dashboard`
- `../ebpf_tracer`

## Dev Compose

Start the remote/dev stack:

```sh
cp .env.example .env
make up
```

Services:

- `karaxys-api-server`
- `karaxys-runtime-analyzer`
- `karaxys-scanner-worker`
- `karaxys-dashboard`
- `mongodb`
- `valkey`
- `redpanda`
- `minio`

The runtime analyzer is part of the core dev stack. Do not run queued ingestion
without it; otherwise traffic can be accepted but never promoted into API
inventory.

Run the smoke test:

```sh
make smoke
```

## Production / self-host (published images)

The `compose/prod/` stack runs entirely from pre-built, hardened images pulled
from GHCR — no source checkout of the app repos is needed. Secrets are
**required**: the stack refuses to start until `.env` provides them, and only
the API (8081) and dashboard (7000) publish host ports.

```sh
make init        # generates compose/prod/.env with unique random secrets
make prod-up     # pulls images and starts the full stack
make prod-ps     # status
```

Then open the dashboard at http://localhost:7000 and log in with the admin
credentials printed by `make init`.

For an internet-facing deployment: set `KARAXYS_ENV=production` and real
(non-localhost, HTTPS) URLs in `compose/prod/.env`, and put a TLS reverse proxy
in front of the API and dashboard.

### Publishing images

CI builds, scans (Trivy, fails on CRITICAL/HIGH), and pushes images to GHCR.
Trigger by pushing a version tag (`git tag v0.1.0 && git push --tags`) or
manually (`gh workflow run "Publish Images" -R Karaxys/karaxys_backend`):
- backend services — `karaxys_backend/.github/workflows/publish-images.yml`
- dashboard — `dash/dashboard/.github/workflows/publish-image.yml`
- agent binaries (GitHub Releases) — `ebpf_tracer/.github/workflows/release-agent.yml`

### Public vs. private images

The source repos stay private; the **images** can be public independently
(GHCR visibility is separate from repo visibility).

**Public images (recommended — frictionless `make prod-up`).** After the first
publish run, make each package Public. This is UI-only — GitHub has no API for
it. For each `karaxys-*` package at
https://github.com/orgs/Karaxys/packages → **Package settings → Danger Zone →
Change visibility → Public**, and **Connect repository** to link it to its source.
Verify: `docker pull ghcr.io/karaxys/karaxys-api-server:latest` should work with
no login.

**Private images (keep them locked down).** Users authenticate before pulling:

- Compose — log in once, then `make prod-up`:
  ```sh
  echo "$GHCR_PAT" | docker login ghcr.io -u <user> --password-stdin
  ```
- Kubernetes — create a pull secret and reference it in the chart:
  ```sh
  kubectl create secret docker-registry ghcr \
    --docker-server=ghcr.io --docker-username=<user> --docker-password=$GHCR_PAT
  helm install karaxys deploy/charts/karaxys --set imagePullSecrets[0].name=ghcr ...
  ```
  (`imagePullSecrets` is already wired into every workload template.)

The `GHCR_PAT` needs only `read:packages` scope.

## Kubernetes (Helm)

For clusters, install the chart in `charts/karaxys`. Secrets are required and
validated at render time:

```sh
helm install karaxys deploy/charts/karaxys \
  --set secrets.secretKeyB64=$(openssl rand -base64 32) \
  --set secrets.apiKey=$(openssl rand -hex 24) \
  --set secrets.agentToken=$(openssl rand -hex 24) \
  --set secrets.redisPassword=$(openssl rand -hex 24) \
  --set secrets.mongoPassword=$(openssl rand -hex 24) \
  --set secrets.minioPassword=$(openssl rand -hex 24) \
  --set secrets.adminPassword='ChooseAStrongOne!'
```

The chart bundles single-node MongoDB/Valkey/Redpanda/MinIO StatefulSets (disable
them to use managed services), an Ingress for the API + dashboard, and an
optional eBPF agent **DaemonSet** (`--set agent.enabled=true`) that runs one
sensor per node.

## Windows Control Plane

Use Windows for browser, editor, SSH/Tailscale, API calls, and `kubectl`.
Linux-specific eBPF capture must run on a Linux VM or Linux Kubernetes node.
