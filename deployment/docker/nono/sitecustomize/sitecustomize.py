"""Pin Prisma query-engine listen port for nono Landlock profiles.

Prisma's get_open_port() binds ('', 0). Nono only allows explicit listen_port
entries, so ephemeral binds fail with EACCES. Set LITELLM_PRISMA_ENGINE_PORT
(and allow that port in the nono profile listen_port + open_port).
"""

from __future__ import annotations

import os


def _install_prisma_port_pin() -> None:
    raw = os.environ.get("LITELLM_PRISMA_ENGINE_PORT", "").strip()
    if not raw:
        return
    try:
        port = int(raw)
    except ValueError:
        return
    if port <= 0 or port > 65535:
        return

    try:
        import prisma.engine.utils as prisma_engine_utils
    except Exception:
        return

    prisma_engine_utils.get_open_port = lambda: port  # type: ignore[assignment]


def _install_redis_loopback_inet() -> None:
    """Prefer IPv4 when Redis targets loopback (TCP forward from nono entrypoint)."""
    try:
        import socket

        import redis.asyncio.connection as redis_async_conn
    except Exception:
        return

    _orig_connect = redis_async_conn.Connection._connect

    async def _connect_ipv4_first(self):  # type: ignore[no-untyped-def]
        host = getattr(self, "host", None) or ""
        if host in ("127.0.0.1", "localhost"):
            kwargs = getattr(self, "_connection_arguments", None)
            if callable(kwargs):
                args = kwargs()
                args.setdefault("family", socket.AF_INET)
        return await _orig_connect(self)

    redis_async_conn.Connection._connect = _connect_ipv4_first  # type: ignore[method-assign]


_install_prisma_port_pin()
_install_redis_loopback_inet()
