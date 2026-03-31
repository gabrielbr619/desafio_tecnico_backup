#!/bin/sh
# Entrypoint do container W-Core
# 1. Executa migrações pendentes (idempotente — seguro em múltiplos starts)
# 2. Inicia o servidor Phoenix

set -e

echo "[entrypoint] Executando migrações..."
/app/bin/w_core eval "WCore.Release.migrate()"

echo "[entrypoint] Iniciando W-Core..."
exec /app/bin/w_core start
