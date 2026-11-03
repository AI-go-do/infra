#!/usr/bin/env bash
# DB 복구: 백업 파일로 DB를 통째로 되돌린다. 지금 DB 내용은 사라진다.
#   사용: scripts/restore.sh prod backups/prod/mspace-20261103-040000.sql.gz
set -euo pipefail

ENV_NAME="${1:?dev 또는 prod를 넣어 주세요}"
FILE="${2:?복구할 백업 파일을 넣어 주세요}"
cd "$(dirname "$0")/.."

ENV_FILE=".env.${ENV_NAME}"
[ -f "$ENV_FILE" ] || { echo "$ENV_FILE 이 없습니다"; exit 1; }
[ -f "$FILE" ] || { echo "$FILE 이 없습니다"; exit 1; }
gzip -t "$FILE" || { echo "백업 파일이 깨졌습니다: $FILE"; exit 1; }
set -a; . "./$ENV_FILE"; set +a              # DB_NAME, DB_USERNAME 읽기

read -r -p "mspace-${ENV_NAME}의 ${DB_NAME}을 ${FILE} 시점으로 되돌립니다. 맞으면 ${ENV_NAME} 입력: " answer
[ "$answer" = "$ENV_NAME" ] || { echo "취소했습니다"; exit 1; }

dc() { docker compose -p "mspace-${ENV_NAME}" --env-file "$ENV_FILE" "$@"; }
sql() { dc exec -T db psql -U "$DB_USERNAME" -d postgres -v ON_ERROR_STOP=1 -q "$@"; }

NEW_DB="${DB_NAME}_restore"
OLD_DB="${DB_NAME}_before_$(date +%Y%m%d_%H%M%S)"

# 1) 지금 DB는 그대로 두고, 빈 새 DB에 먼저 넣어 본다 (백업 뒤에 생긴 테이블이 섞이지 않게)
sql -c "DROP DATABASE IF EXISTS \"${NEW_DB}\"" -c "CREATE DATABASE \"${NEW_DB}\" OWNER \"${DB_USERNAME}\""
# SQL 오류가 하나라도 나면 멈추고 전부 되돌린다. 이때 지금 DB는 손대지 않은 상태
gzip -dc "$FILE" | dc exec -T db psql -U "$DB_USERNAME" -d "$NEW_DB" -v ON_ERROR_STOP=1 --single-transaction -q >/dev/null

# 2) 다 들어갔으면 앱을 잠깐 멈추고 이름만 바꿔 끼운다. 옛 DB는 지우지 않고 남겨 둔다
dc stop core mcp agent
trap 'dc start core mcp agent' EXIT
sql -c "ALTER DATABASE \"${DB_NAME}\" RENAME TO \"${OLD_DB}\"" \
    -c "ALTER DATABASE \"${NEW_DB}\" RENAME TO \"${DB_NAME}\""

echo "$(date '+%F %T') 복구 완료: $FILE → ${DB_NAME} (이전 DB는 ${OLD_DB}로 남김, 확인 뒤 DROP DATABASE로 지우기)"
