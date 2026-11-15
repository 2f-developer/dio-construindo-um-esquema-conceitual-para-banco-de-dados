#!/usr/bin/env bash
# Cria o banco a partir do esquema, para conferir que o modelo é implementável em MySQL 8.
# Os argumentos vão direto para o cliente mysql. Exemplo: ./testar.sh -u root -p
set -euo pipefail
cd "$(dirname "$0")"
mysql --default-character-set=utf8mb4 "$@" < sql/esquema.sql
mysql --default-character-set=utf8mb4 "$@" -N -e "SELECT CONCAT(COUNT(*), ' tabelas criadas') FROM information_schema.tables WHERE table_schema = 'oficina' AND table_type = 'BASE TABLE'"
