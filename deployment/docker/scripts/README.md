# Verification (plan checklist)

Run from `deployment/docker` with the stack up unless noted.

| # | Script | What it checks |
|---|--------|----------------|
| — | `./scripts/smoke-health.sh` | Health + `/v1/models` |
| 1 | `./scripts/verify-direct-keys.sh` | Mode 1: no `SBX_REAL_*` in sandboxed child; phantoms + loopback `*_BASE_URL` |
| 2 | `./scripts/verify-chat-completion.sh` | Chat completion (set real `SBX_REAL_*` in `.env.secrets`) |
| 3 | `./scripts/verify-config-reject.sh` | Entrypoint rejects direct `api_base` (no running stack required) |
| 4 | `VERIFY_STREAM=1 ./scripts/verify-chat-completion.sh` | SSE streaming through nono reverse proxy |
| 5 | `./scripts/verify-sidecar-keys.sh` | Mode 2: no `SBX_REAL_*` on litellm; keys on `litellm-nono-proxy` |
| — | `./scripts/e2e-both-modes.sh` | Build tag `litellm-secure:local` then direct + sidecar health, admin login, chat |

Nono audit lines (`ALLOW REVERSE openai …`) appear in container logs during #2 / #4; credential values are never logged.
