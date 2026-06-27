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

## Windows Control Plane

Use Windows for browser, editor, SSH/Tailscale, API calls, and `kubectl`.
Linux-specific eBPF capture must run on a Linux VM or Linux Kubernetes node.
