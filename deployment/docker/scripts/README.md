# Verification (plan checklist)

Run from `deployment/docker` with the stack up unless noted.

| # | Script | What it checks |
|---|--------|----------------|
| — | `./scripts/smoke-health.sh` | Health + `/v1/models` |
| 1 | `./scripts/verify-phantom-env.sh` | Child `OPENAI_API_KEY` ≠ `NONO_OPENAI_API_KEY`; `OPENAI_BASE_URL` on loopback |
| 2 | `./scripts/verify-chat-completion.sh` | Chat completion (set real `NONO_OPENAI_API_KEY`) |
| 3 | `./scripts/verify-config-reject.sh` | Entrypoint rejects direct `api_base` (no running stack required) |
| 4 | `VERIFY_STREAM=1 ./scripts/verify-chat-completion.sh` | SSE streaming through nono reverse proxy |
| 5 | `./scripts/verify-sidecar-keys.sh` | Mode 2: no `NONO_*` on litellm; keys on `litellm-nono-proxy` |
| — | `./scripts/e2e-both-modes.sh` | Build tag `litellm-secure:local` then direct + sidecar health, admin login, chat |

Nono audit lines (`ALLOW REVERSE openai …`) appear in container logs during #2 / #4; credential values are never logged.
