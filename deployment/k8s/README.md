# Kubernetes / Talos

Same threat model as [deployment/docker](../docker/README.md): **real provider keys only as `SBX_REAL_*` on the credential proxy**, LiteLLM sees phantoms and loopback `*_BASE_URL`.

## Recommended: sidecar pod (mode 2)

Matches `docker-compose.with-nono-proxy.yml`. Two containers share the pod network namespace (one IP); **nono proxy listens on 4010**, LiteLLM on **4000** — both can bind in the same pod/namespace.

| Container | Image | Secrets |
|-----------|--------|---------|
| `nono-proxy` | `ghcr.io/nolabs-ai/nono:0.81.0` | `SBX_REAL_*`, `nono proxy --pass …` |
| `litellm-secure` | `bbkudk/litellm-secure:<tag>` | `LITELLM_MASTER_KEY`, DB URL — **no** `SBX_REAL_*` |

Environment on **litellm-secure** (Talos / strict nodes):

```yaml
NONO_CREDENTIAL_PROXY: "1"
NONO_CREDENTIAL_PROXY_HOST: "127.0.0.1"
NONO_CREDENTIAL_PROXY_PORT: "4010"
NONO_LOCAL_CREDENTIAL_PROXY_PORT: "18080"
NONO_PROFILE: litellm-sandbox
NONO_PROXY_PASS: "<same as nono-proxy --pass>"
```

**nono-proxy** container (same pod):

```text
nono proxy --listen 0.0.0.0 --port 4010 --pass "$NONO_PROXY_PASS" --profile /profiles/litellm-credentials.json
```

Mount `deployment/docker/nono/profiles/litellm-credentials.json`. Put `SBX_REAL_*` in a Kubernetes Secret and inject only into `nono-proxy`.

Postgres: external or in-cluster Service; set `DATABASE_HOST` to that DNS name. The entrypoint still TCP-forwards DB to `127.0.0.1` for Landlock `open_port`.

See [litellm-secure-sidecar.yaml](./litellm-secure-sidecar.yaml) for a minimal starting manifest (edit images, secrets, and storage).

## Mode 1 (single container)

Works on hosts with working Landlock in Docker/crun (e.g. many Linux worker nodes). Set `SBX_REAL_*` via Secret on the litellm pod, profile `litellm`, **do not** set `NONO_CREDENTIAL_PROXY`.

On Talos or other strict environments where a standalone `nono` image is easier to operate than combined credential injection, prefer **sidecar mode** above — same pattern as [CLIProxyAPI-secure](https://github.com/qdrddr/CLIProxyAPI-secure) (`NONO_K8S_PROXY` there is for **egress** filtering, not credential injection).

## Checks

After deploy, confirm litellm child env (from `verify-sidecar-keys.sh` logic): `OPENROUTER_BASE_URL` like `http://127.0.0.1:18080/openrouter`, child `OPENROUTER_API_KEY` must not equal sidecar `SBX_REAL_OPENROUTER_API_KEY`.
