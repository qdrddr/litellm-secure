#!/usr/bin/env python3
"""Keep LiteLLM in-container PgBouncer alive outside nono Landlock (unsandboxed parent)."""
from __future__ import annotations

import argparse
import os
import signal
import sys
import time

from litellm.proxy.db.pgbouncer import (
    PgBouncerError,
    PgBouncerSettings,
    export_pooled_database_url,
    start_in_container_pgbouncer,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--pooled-url-file",
        required=True,
        help="Write the loopback DATABASE_URL for workers after the pooler is listening",
    )
    args = parser.parse_args()
    upstream = os.environ.get("DATABASE_URL")
    if not upstream:
        print("ERROR: DATABASE_URL unset", file=sys.stderr)
        return 1
    settings = PgBouncerSettings()
    if not settings.enabled:
        print("PgBouncer supervisor: LITELLM_PGBOUNCER_ENABLED is off, exiting", file=sys.stderr)
        return 0
    pooled = start_in_container_pgbouncer(settings, upstream)
    if isinstance(pooled, PgBouncerError):
        print(f"ERROR: {pooled.reason}", file=sys.stderr)
        return 1
    export_pooled_database_url(pooled)
    out_path = os.path.abspath(args.pooled_url_file)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(pooled)
        handle.write("\n")
    print(
        f"pgbouncer-supervisor: listening on 127.0.0.1:{settings.port}, pooled URL written to {out_path}",
        file=sys.stderr,
        flush=True,
    )

    def _stop(_signum: int, _frame: object) -> None:
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    raise SystemExit(main())
