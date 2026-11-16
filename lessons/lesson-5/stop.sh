#!/usr/bin/env bash
# Stop and remove the ShopStream observability stack (exits 0 even if nothing runs).
docker compose -p shopstream-otel down --remove-orphans 2>/dev/null && echo "[INFO] stack stopped" || echo "[INFO] nothing to stop"
exit 0
