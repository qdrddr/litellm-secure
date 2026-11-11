# LiteLLM + Nono (proxy credential injection)

Thin Docker overlay on [LiteLLM](https://github.com/BerriAI/litellm). The proxy runs under [`nono run`](https://nono.sh/docs/cli/features/credential-injection) so **real provider API keys never enter the sandbox**.

## Quick start

```bash
cd deployment/docker
cp .env.example .env
cp config.example.yaml config.yaml
# Edit .env: LITELLM_MASTER_KEY, NONO_OPENAI_API_KEY (and other NONO_* as needed)
docker compose up -d --build
curl -sS http://localhost:4000/health/liveliness
```

Chat completion (requires a valid `NONO_OPENAI_API_KEY`):

```bash
curl -sS http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}]}'
```

## Security model

| Secret | Where it lives | Seen by LiteLLM? |
|--------|----------------|------------------|
| `NONO_OPENAI_API_KEY` (etc.) | Container env (supervisor) | No — resolved by nono via `env://` |
| `OPENAI_API_KEY` | Set by nono for the child | Phantom token only |
| `OPENAI_BASE_URL` | Set by nono | `http://127.0.0.1:PORT/openai` |
| `NONO_OPENROUTER_API_KEY` | Container env (supervisor) | No — same pattern as other providers |
| `OPENROUTER_API_KEY` / `OPENROUTER_BASE_URL` | Set by nono for child | Phantom token + loopback `/openrouter` |
| `LITELLM_MASTER_KEY` | Container env | Yes (proxy virtual-key auth) |

Postgres (optional):

```bash
docker compose -f docker-compose.yml -f docker-compose.with-db.yml --profile with-db up -d
```

Set `POSTGRES_PASSWORD`, `LITELLM_SALT_KEY`, and the other `POSTGRES_*` / `DATABASE_*` values in `.env` (see `.env.example`). Migrations run unsandboxed before `nono run` (`db` → IP for landlock). Keep `STORE_MODEL_IN_DB=False` so provider keys stay in config phantoms only.

Upstream requests: LiteLLM sends the phantom key to the localhost reverse proxy; nono injects `Authorization: Bearer sk-...` (or `x-api-key`) before TLS to the real provider.

**Do not** paste provider keys into the Admin UI or enable DB-stored credentials with real keys — they are decrypted inside the sandbox. Use `config.yaml` with `os.environ/OPENAI_API_KEY` and keep `STORE_MODEL_IN_DB=False` unless you extend the design.

**Do not** set `api_base: https://api.openai.com` in config — that bypasses nono routes. Omit `api_base` so LiteLLM uses nono-provided `OPENAI_BASE_URL` / `ANTHROPIC_BASE_URL`.

Credential injection requires `nono run` with Landlock (Docker Desktop on macOS, modern Linux). `NONO_K8S_PROXY` egress-only mode is **not** used here because it does not install phantom credentials.

## Files

- `Dockerfile.template` — install nono on `docker.litellm.ai/berriai/litellm`
- `nono/nono-entrypoint.sh` — stage config, `exec nono run`
- `nono/profiles/litellm.json` — filesystem allowlist + `custom_credentials` for OpenAI / Anthropic / Gemini
- `config.example.yaml` — models referencing `os.environ/*` phantoms

## Verification

See [scripts/README.md](scripts/README.md). Quick path:

```bash
./scripts/smoke-health.sh
./scripts/verify-phantom-env.sh
./scripts/verify-config-reject.sh
# With a real NONO_OPENAI_API_KEY:
./scripts/verify-chat-completion.sh
VERIFY_STREAM=1 ./scripts/verify-chat-completion.sh
```

Release tags: `v{litellm}-v{nono}` — `./scripts/publish-release.sh` + `scripts/build-and-push-image.sh`.
