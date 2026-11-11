#!/usr/bin/env python3
"""Dynamic NONO / PHANTOM env handling for litellm-secure (no per-provider hardcoding)."""
from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path

NONO_INFRA = frozenset(
    {
        "NONO_PROFILE",
        "NONO_RUN_ARGS",
        "NONO_CREDENTIAL_PROXY",
        "NONO_CREDENTIAL_PROXY_HOST",
        "NONO_CREDENTIAL_PROXY_PORT",
        "NONO_LOCAL_CREDENTIAL_PROXY_PORT",
        "NONO_LOCAL_DB_PORT",
        "NONO_K8S_SIDECAR",
        "NONO_PROXY_PASS",
        "NONO_CREDENTIALS_PROFILE_PATH",
        "NONO_VERSION",
    }
)

# LiteLLM / container ops — not provider credentials.
_ENV_ALLOWLIST_EXACT = frozenset(
    {
        "DATABASE_URL",
        "DATABASE_HOST",
        "DATABASE_PORT",
        "POSTGRES_DB",
        "POSTGRES_USER",
        "POSTGRES_PASSWORD",
        "PATH",
        "HOME",
        "HOSTNAME",
        "LANG",
        "TZ",
        "PWD",
        "SHLVL",
        "PORT",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "NO_PROXY",
        "SSL_CERT_FILE",
        "PYTHONPATH",
        "VIRTUAL_ENV",
        "UVICORN_WORKERS",
    }
)

_ENV_ALLOWLIST_PREFIXES = (
    "LITELLM_",
    "STORE_",
    "DISABLE_",
    "PHANTOM_KEY_",
    "PHANTOM_URL_",
    "GPG_",
    "CI",
    "DEBIAN_",
    "PWD",
)


def looks_like_real_provider_key(value: str) -> bool:
    if not value:
        return False
    proxy_pass = os.environ.get("NONO_PROXY_PASS") or ""
    if proxy_pass and value == proxy_pass:
        return False
    return bool(re.match(r"^(sk-or-v1-|sk-ant-|sk-|AIza)", value))


def is_phantom_var(name: str) -> bool:
    return name.startswith("PHANTOM_KEY_") or name.startswith("PHANTOM_URL_")


def is_ops_env(name: str) -> bool:
    if name in _ENV_ALLOWLIST_EXACT:
        return True
    return any(name.startswith(p) for p in _ENV_ALLOWLIST_PREFIXES)


def is_nono_provider_secret(name: str) -> bool:
    if name.startswith("NONO_REAL_"):
        return True
    if name.startswith("NONO_") and name not in NONO_INFRA:
        return True
    return False


def is_leaked_provider_env(name: str) -> bool:
    if is_ops_env(name) or is_phantom_var(name) or name.startswith("NONO_"):
        return False
    if name == "OR_API_KEY":
        return True
    if name.endswith("_API_KEY"):
        return True
    return False


def suggested_nono_name(leaked: str) -> str:
    return f"NONO_{leaked} or NONO_REAL_{leaked}"


def api_key_to_base_url_var(env_var: str) -> str:
    if env_var.endswith("_API_KEY"):
        return f"{env_var[:-8]}_BASE_URL"
    return f"{env_var}_BASE_URL"


def load_credentials_profile() -> dict:
    path = os.environ.get(
        "NONO_CREDENTIALS_PROFILE_PATH", "/app/.nono/credentials-profile.json"
    )
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: cannot read credentials profile {path}: {exc}", file=sys.stderr)
        sys.exit(1)


def credential_proxy_enabled() -> bool:
    v = os.environ.get("NONO_CREDENTIAL_PROXY", "")
    return v.lower() in ("1", "true", "yes")


def preflight() -> int:
    if credential_proxy_enabled():
        for name, value in os.environ.items():
            if not value:
                continue
            if is_nono_provider_secret(name):
                print(
                    f"ERROR: {name} is set on litellm-secure. "
                    "In sidecar mode, provider secrets belong on nono-proxy only "
                    "(NONO_* / NONO_REAL_* in .env.secrets).",
                    file=sys.stderr,
                )
                return 1
    for name, value in os.environ.items():
        if not value or not is_leaked_provider_env(name):
            continue
        if credential_proxy_enabled() and not looks_like_real_provider_key(value):
            continue
        print(
            f"ERROR: {name} is set on the container. "
            f"Use {suggested_nono_name(name)} or PHANTOM_KEY_{name} "
            f"(phantom for the sandbox child) — not real upstream keys.",
            file=sys.stderr,
        )
        return 1
    return 0


def emit_phantom_exports() -> None:
    """PHANTOM_KEY_* -> export target; PHANTOM_URL_* -> export target."""
    for name, value in sorted(os.environ.items()):
        if not value:
            continue
        if name.startswith("PHANTOM_KEY_"):
            target = name[len("PHANTOM_KEY_") :]
            print(f"export {target}={shlex.quote(value)}")
        elif name.startswith("PHANTOM_URL_"):
            target = name[len("PHANTOM_URL_") :]
            print(f"export {target}={shlex.quote(value)}")


def emit_sidecar_provider_exports(local_port: str) -> None:
    if not os.environ.get("NONO_PROXY_PASS"):
        print("ERROR: NONO_CREDENTIAL_PROXY requires NONO_PROXY_PASS", file=sys.stderr)
        sys.exit(1)
    default_phantom = os.environ["NONO_PROXY_PASS"]
    profile = load_credentials_profile()
    custom = (profile.get("network") or {}).get("custom_credentials") or {}
    phantom_targets = {
        k[len("PHANTOM_KEY_") :]: v
        for k, v in os.environ.items()
        if k.startswith("PHANTOM_KEY_") and v
    }
    url_targets = {
        k[len("PHANTOM_URL_") :]: v
        for k, v in os.environ.items()
        if k.startswith("PHANTOM_URL_") and v
    }
    for route, spec in custom.items():
        if not isinstance(spec, dict):
            continue
        env_var = spec.get("env_var")
        if not env_var:
            continue
        if env_var not in phantom_targets:
            print(f"export {env_var}={shlex.quote(default_phantom)}")
        base_var = api_key_to_base_url_var(env_var)
        if base_var not in url_targets:
            print(f"export {base_var}={shlex.quote(f'http://127.0.0.1:{local_port}/{route}')}")


def map_nono_real_exports() -> None:
    """Sidecar nono-proxy: NONO_REAL_* -> NONO_* for env:// profile refs."""
    for name, value in sorted(os.environ.items()):
        if not value or not name.startswith("NONO_REAL_"):
            continue
        suffix = name[len("NONO_REAL_") :]
        print(f"export NONO_{suffix}={shlex.quote(value)}")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: litellm_nono_env.py preflight|emit-phantoms|emit-sidecar|map-nono-real", file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    if cmd == "preflight":
        return preflight()
    if cmd == "emit-phantoms":
        emit_phantom_exports()
        return 0
    if cmd == "emit-sidecar":
        local_port = os.environ.get("NONO_LOCAL_CREDENTIAL_PROXY_PORT", "18080")
        emit_phantom_exports()
        emit_sidecar_provider_exports(local_port)
        return 0
    if cmd == "map-nono-real":
        map_nono_real_exports()
        return 0
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
