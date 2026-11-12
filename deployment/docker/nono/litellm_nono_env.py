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
        "NONO_PROXY_TOKEN",
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


def is_sbx_provider_secret(name: str) -> bool:
    return name.startswith("SBX_REAL_")


def is_legacy_provider_secret_name(name: str) -> bool:
    """Deprecated NONO_* / NONO_REAL_* LLM key names (use SBX_REAL_*)."""
    if name.startswith("NONO_REAL_"):
        return True
    if name.startswith("NONO_") and name not in NONO_INFRA and name.endswith("_API_KEY"):
        return True
    return False


def is_leaked_provider_env(name: str) -> bool:
    if (
        is_ops_env(name)
        or is_phantom_var(name)
        or name.startswith("NONO_")
        or is_sbx_provider_secret(name)
    ):
        return False
    if name == "OR_API_KEY":
        return True
    if name.endswith("_API_KEY"):
        return True
    return False


def suggested_sbx_secret_name(leaked: str) -> str:
    return f"SBX_REAL_{leaked}"


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


def _profile_provider_secret_names(profile_path: str) -> set[str]:
    try:
        profile = json.loads(Path(profile_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return set()
    custom = (profile.get("network") or {}).get("custom_credentials") or {}
    names: set[str] = set()
    for spec in custom.values():
        if not isinstance(spec, dict):
            continue
        secret_name = credential_key_env_name(str(spec.get("credential_key", "")))
        if secret_name:
            names.add(secret_name)
    return names


def _deny_vars_coverage(profile: dict, required: set[str]) -> set[str]:
    env = profile.get("environment") or {}
    deny = env.get("deny_vars") or []
    covered: set[str] = set()
    if not isinstance(deny, list):
        return covered
    for pattern in deny:
        if not isinstance(pattern, str):
            continue
        if pattern.endswith("*") and pattern.count("*") == 1:
            prefix = pattern[:-1]
            for name in required:
                if name.startswith(prefix):
                    covered.add(name)
        elif pattern in required:
            covered.add(pattern)
    return covered


def preflight() -> int:
    for name, value in os.environ.items():
        if value and is_legacy_provider_secret_name(name):
            print(
                f"ERROR: {name} is deprecated. "
                f"Rename to {suggested_sbx_secret_name(name.removeprefix('NONO_REAL_').removeprefix('NONO_'))} "
                "in .env.secrets.",
                file=sys.stderr,
            )
            return 1
    if not credential_proxy_enabled():
        profile_path = os.environ.get(
            "NONO_PROFILE_PATH", "/app/.config/nono/profiles/litellm.json"
        )
        try:
            profile = json.loads(Path(profile_path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"ERROR: cannot read profile for preflight: {exc}", file=sys.stderr)
            return 1
        required = _profile_provider_secret_names(profile_path)
        covered = _deny_vars_coverage(profile, required)
        if required and covered != required:
            missing = ", ".join(sorted(required - covered))
            print(
                "ERROR: litellm profile environment.deny_vars must list every "
                f"custom_credentials env:// name ({missing}).",
                file=sys.stderr,
            )
            return 1
    if credential_proxy_enabled():
        for name, value in os.environ.items():
            if not value:
                continue
            if is_sbx_provider_secret(name):
                print(
                    f"ERROR: {name} is set on litellm-secure. "
                    "In sidecar mode, SBX_REAL_* provider secrets belong on nono-proxy only "
                    "(.env.secrets).",
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
            f"Use {suggested_sbx_secret_name(name)} or PHANTOM_KEY_{name} "
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


def _read_proc_environ(pid: int) -> dict[str, str]:
    raw = Path(f"/proc/{pid}/environ").read_bytes()
    out: dict[str, str] = {}
    for item in raw.split(b"\0"):
        if not item or b"=" not in item:
            continue
        key, value = item.split(b"=", 1)
        out[key.decode()] = value.decode()
    return out


def _litellm_child_pid() -> int | None:
    proc = Path("/proc")
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            cmd = (entry / "cmdline").read_bytes().replace(b"\0", b" ")
        except OSError:
            continue
        if b"/app/.venv/bin/litellm" in cmd and b"--config" in cmd:
            return int(entry.name)
    return None


def credential_key_env_name(credential_key: str) -> str | None:
    if credential_key.startswith("env://"):
        return credential_key[len("env://") :]
    return None


def verify_sandboxed_child_env(
    profile_path: str | None = None,
) -> int:
    """Direct mode: litellm child must not inherit supervisor SBX_REAL_* provider secrets."""
    pid = _litellm_child_pid()
    if pid is None:
        print("ERROR: litellm child process not found", file=sys.stderr)
        return 1

    child = _read_proc_environ(pid)
    supervisor = dict(os.environ)

    if credential_proxy_enabled():
        print("SKIP: verify-child is for direct mode (NONO_CREDENTIAL_PROXY set)")
        return 0

    path = profile_path or os.environ.get(
        "NONO_PROFILE_PATH", "/app/.config/nono/profiles/litellm.json"
    )
    try:
        profile = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: cannot read profile {path}: {exc}", file=sys.stderr)
        return 1

    custom = (profile.get("network") or {}).get("custom_credentials") or {}
    provider_secret_names: set[str] = set()
    for name, value in child.items():
        if is_sbx_provider_secret(name) and value:
            print(f"FAIL: sandboxed child has {name}", file=sys.stderr)
            return 1

    checked_route = False
    for _route, spec in custom.items():
        if not isinstance(spec, dict):
            continue
        env_var = spec.get("env_var")
        cred_key = spec.get("credential_key", "")
        secret_name = credential_key_env_name(str(cred_key))
        if not env_var or not secret_name:
            continue
        provider_secret_names.add(secret_name)
        if child.get(secret_name):
            print(
                f"FAIL: sandboxed child inherited supervisor secret {secret_name} "
                "(litellm profile environment.deny_vars should strip it)",
                file=sys.stderr,
            )
            return 1
        real = supervisor.get(secret_name, "")
        if not real:
            continue
        checked_route = True
        phantom = child.get(env_var, "")
        base_var = api_key_to_base_url_var(env_var)
        base_url = child.get(base_var, "")
        print(f"{secret_name}: supervisor set; child {env_var} prefix {phantom[:20]}...")
        print(f"  {base_var}: {base_url or '<unset>'}")
        if phantom == real:
            print(
                f"FAIL: child {env_var} equals supervisor {secret_name} (real key leaked)",
                file=sys.stderr,
            )
            return 1
        if not phantom:
            print(
                f"FAIL: child missing {env_var} while {secret_name} is configured",
                file=sys.stderr,
            )
            return 1
        if not base_url.startswith(("http://127.0.0.1:", "http://localhost:")):
            print(
                f"FAIL: {base_var} should target nono loopback proxy, got {base_url!r}",
                file=sys.stderr,
            )
            return 1

    if not checked_route:
        print(
            "WARN: no configured SBX_REAL_* provider keys on supervisor; "
            "set at least one to verify phantom injection",
            file=sys.stderr,
        )
    print("OK: direct mode — sandboxed child does not inherit provider secrets")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(
            "usage: litellm_nono_env.py preflight|emit-phantoms|emit-sidecar|verify-child",
            file=sys.stderr,
        )
        return 2
    cmd = sys.argv[1]
    if cmd == "preflight":
        return preflight()
    if cmd == "verify-child":
        profile = sys.argv[2] if len(sys.argv) > 2 else None
        return verify_sandboxed_child_env(profile)
    if cmd == "emit-phantoms":
        emit_phantom_exports()
        return 0
    if cmd == "emit-sidecar":
        local_port = os.environ.get("NONO_LOCAL_CREDENTIAL_PROXY_PORT", "18080")
        emit_phantom_exports()
        emit_sidecar_provider_exports(local_port)
        return 0
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
