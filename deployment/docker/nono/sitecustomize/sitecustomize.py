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


_install_prisma_port_pin()
