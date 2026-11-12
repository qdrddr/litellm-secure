#!/usr/bin/env python3
"""Dynamic NONO / PHANTOM env handling for litellm-secure (no per-provider hardcoding)."""
from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path

_FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


def _resolve_fixture(filename: str, env_override: str) -> Path:
    override = os.environ.get(env_override, "").strip()
    return Path(override) if override else _FIXTURES_DIR / filename


def _read_fixture_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: cannot read env fixture {path}: {exc}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data, dict):
        print(f"ERROR: env fixture {path} must be a JSON object", file=sys.stderr)
        sys.exit(1)
    return data


def load_nono_infra_env(path: Path | None = None) -> frozenset[str]:
    """NONO_* ops/runtime names — fixtures/nono_infra_env.json."""
    fixture = path or _resolve_fixture("nono_infra_env.json", "LITELLM_NONO_INFRA_FIXTURE")
    raw = _read_fixture_json(fixture)
    names = raw.get("env_vars")
    if not isinstance(names, list) or not names:
        print(f"ERROR: {fixture} must contain a non-empty env_vars array", file=sys.stderr)
        sys.exit(1)
    for name in names:
        if not isinstance(name, str) or not name.startswith("NONO_"):
            print(f"ERROR: invalid NONO infra env name in {fixture}: {name!r}", file=sys.stderr)
            sys.exit(1)
    return frozenset(names)


def load_container_env_allowlist(
    path: Path | None = None,
) -> tuple[frozenset[str], tuple[str, ...]]:
    """Exact + prefix ops allowlists — fixtures/litellm_container_env_allowlist.json."""
    fixture = path or _resolve_fixture(
        "litellm_container_env_allowlist.json",
        "LITELLM_CONTAINER_ENV_ALLOWLIST_FIXTURE",
    )
    raw = _read_fixture_json(fixture)
    exact = raw.get("allowlist_exact")
    prefixes = raw.get("allowlist_prefixes")
    if not isinstance(exact, list) or not exact:
        print(f"ERROR: {fixture} must contain a non-empty allowlist_exact array", file=sys.stderr)
        sys.exit(1)
    if not isinstance(prefixes, list) or not prefixes:
        print(
            f"ERROR: {fixture} must contain a non-empty allowlist_prefixes array",
            file=sys.stderr,
        )
        sys.exit(1)
    for name in exact:
        if not isinstance(name, str) or not name:
            print(f"ERROR: invalid allowlist_exact entry in {fixture}: {name!r}", file=sys.stderr)
            sys.exit(1)
    for prefix in prefixes:
        if not isinstance(prefix, str) or not prefix:
            print(
                f"ERROR: invalid allowlist_prefixes entry in {fixture}: {prefix!r}",
                file=sys.stderr,
            )
            sys.exit(1)
    return frozenset(exact), tuple(prefixes)


NONO_INFRA = load_nono_infra_env()
_ENV_ALLOWLIST_EXACT, _ENV_ALLOWLIST_PREFIXES = load_container_env_allowlist()


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


def _navigate_fixture(data: dict, dotted: str) -> object:
    cur: object = data
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            print(f"ERROR: fixture key {dotted!r} not found", file=sys.stderr)
            sys.exit(1)
        cur = cur[part]
    return cur


def _flatten_entrypoint_fixture(prefix: str, obj: object, out: dict[str, str]) -> None:
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "meta":
                continue
            child = f"{prefix}_{k}" if prefix else k
            _flatten_entrypoint_fixture(child, v, out)
    elif isinstance(obj, list):
        return
    elif isinstance(obj, (str, int, float, bool)):
        out[prefix] = str(obj)
    else:
        print(f"ERROR: unsupported fixture value at {prefix!r}", file=sys.stderr)
        sys.exit(1)


def emit_entrypoint_vars(fixture_path: str) -> int:
    """Flatten scalar fixture fields to ep_* shell assignments (safe for eval)."""
    raw = _read_fixture_json(Path(fixture_path))
    flat: dict[str, str] = {}
    _flatten_entrypoint_fixture("ep", raw, flat)
    for key in sorted(flat):
        print(f"{key}={shlex.quote(flat[key])}")
    return 0


def emit_entrypoint_list(fixture_path: str, dotted_key: str) -> int:
    cur = _navigate_fixture(_read_fixture_json(Path(fixture_path)), dotted_key)
    if not isinstance(cur, list):
        print(f"ERROR: {dotted_key} must be a list", file=sys.stderr)
        sys.exit(1)
    for item in cur:
        if not isinstance(item, str):
            print(f"ERROR: invalid list entry in {dotted_key}: {item!r}", file=sys.stderr)
            sys.exit(1)
        print(item)
    return 0


def emit_entrypoint_no_proxy_spec(fixture_path: str) -> int:
    """Print lines: ENV_VAR<space>default_port (for NO_PROXY loopback port suffix)."""
    raw = _read_fixture_json(Path(fixture_path))
    block = _navigate_fixture(raw, "no_proxy")
    if not isinstance(block, dict):
        print("ERROR: no_proxy must be an object", file=sys.stderr)
        sys.exit(1)
    ports = block.get("local_ports")
    if not isinstance(ports, list) or not ports:
        print("ERROR: no_proxy.local_ports must be a non-empty array", file=sys.stderr)
        sys.exit(1)
    for spec in ports:
        if not isinstance(spec, dict):
            print("ERROR: invalid no_proxy.local_ports entry", file=sys.stderr)
            sys.exit(1)
        env_var = spec.get("env_var")
        default = spec.get("default")
        if not isinstance(env_var, str) or not env_var:
            print(f"ERROR: invalid env_var in no_proxy.local_ports: {env_var!r}", file=sys.stderr)
            sys.exit(1)
        if default is None or default == "":
            print(f"ERROR: missing default for {env_var}", file=sys.stderr)
            sys.exit(1)
        print(f"{env_var} {default}")
    return 0


def emit_entrypoint_no_proxy_value(fixture_path: str) -> int:
    """Print NO_PROXY loopback prefix + 127.0.0.1:<port> entries (honours container env overrides)."""
    raw = _read_fixture_json(Path(fixture_path))
    block = _navigate_fixture(raw, "no_proxy")
    if not isinstance(block, dict):
        print("ERROR: no_proxy must be an object", file=sys.stderr)
        sys.exit(1)
    prefix = block.get("loopback_prefix")
    if not isinstance(prefix, str) or not prefix:
        print("ERROR: no_proxy.loopback_prefix required", file=sys.stderr)
        sys.exit(1)
    ports = block.get("local_ports")
    if not isinstance(ports, list) or not ports:
        print("ERROR: no_proxy.local_ports must be a non-empty array", file=sys.stderr)
        sys.exit(1)
    parts = [prefix]
    for spec in ports:
        if not isinstance(spec, dict):
            print("ERROR: invalid no_proxy.local_ports entry", file=sys.stderr)
            sys.exit(1)
        env_var = spec.get("env_var")
        default = spec.get("default")
        if not isinstance(env_var, str) or not env_var:
            print(f"ERROR: invalid env_var in no_proxy.local_ports: {env_var!r}", file=sys.stderr)
            sys.exit(1)
        port = os.environ.get(env_var, str(default) if default is not None else "")
        if not port:
            port = str(default) if default is not None else ""
        parts.append(f"127.0.0.1:{port}")
    print(",".join(parts))
    return 0


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
            "usage: litellm_nono_env.py preflight|emit-phantoms|emit-sidecar|verify-child|"
            "emit-entrypoint-vars|emit-entrypoint-list|emit-entrypoint-no-proxy-spec|"
            "emit-entrypoint-no-proxy-value",
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
    if cmd == "emit-entrypoint-vars":
        if len(sys.argv) < 3:
            print("usage: emit-entrypoint-vars <fixture.json>", file=sys.stderr)
            return 2
        return emit_entrypoint_vars(sys.argv[2])
    if cmd == "emit-entrypoint-list":
        if len(sys.argv) < 4:
            print("usage: emit-entrypoint-list <fixture.json> <dotted.key>", file=sys.stderr)
            return 2
        return emit_entrypoint_list(sys.argv[2], sys.argv[3])
    if cmd == "emit-entrypoint-no-proxy-spec":
        if len(sys.argv) < 3:
            print("usage: emit-entrypoint-no-proxy-spec <fixture.json>", file=sys.stderr)
            return 2
        return emit_entrypoint_no_proxy_spec(sys.argv[2])
    if cmd == "emit-entrypoint-no-proxy-value":
        if len(sys.argv) < 3:
            print("usage: emit-entrypoint-no-proxy-value <fixture.json>", file=sys.stderr)
            return 2
        return emit_entrypoint_no_proxy_value(sys.argv[2])
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
