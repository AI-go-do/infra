#!/usr/bin/env bash
# DB 백업: 지금 DB를 통째로 떠서 backups/ 에 날짜별 파일로 남기고, 7일 지난 건 지운다.
#   사용: scripts/backup.sh dev    (mspace-dev,  .env.dev)
#         scripts/backup.sh prod   (mspace-prod, .env.prod)
#   매일 새벽 4시 자동 실행(서버 crontab -e):
#   0 4 * * * cd ~/infra && scripts/backup.sh prod >> backups/backup.log 2>&1
set -euo pipefail

ENV_NAME="${1:?dev 또는 prod를 넣어 주세요}"
cd "$(dirname "$0")/.."                      # infra 폴더 기준으로 실행

ENV_FILE=".env.${ENV_NAME}"
[ -f "$ENV_FILE" ] || { echo "$ENV_FILE 이 없습니다"; exit 1; }
set -a; . "./$ENV_FILE"; set +a              # DB_NAME, DB_USERNAME 읽기

KEEP_DAYS="${KEEP_DAYS:-7}"
OUT_DIR="backups/${ENV_NAME}"
mkdir -p "$OUT_DIR"
OUT="${OUT_DIR}/${DB_NAME}-$(date +%Y%m%d-%H%M%S).sql.gz"

# db 컨테이너 안에서 pg_dump를 돌린다 (DB 포트를 밖에 안 열어도 됨)
# --clean --if-exists: 복구할 때 기존 테이블을 지우고 다시 만든다
docker compose -p "mspace-${ENV_NAME}" --env-file "$ENV_FILE" exec -T db \
  pg_dump -U "$DB_USERNAME" -d "$DB_NAME" --clean --if-exists \
  | gzip > "${OUT}.tmp"
mv "${OUT}.tmp" "$OUT"                       # 끝까지 성공한 것만 이름을 붙인다

# 빈 파일이면 실패로 본다
[ "$(gzip -dc "$OUT" | wc -c)" -gt 0 ] || { echo "백업이 비었습니다: $OUT"; exit 1; }

find "$OUT_DIR" -name '*.sql.gz' -mtime +"$KEEP_DAYS" -delete
echo "$(date '+%F %T') 백업 완료: $OUT ($(du -h "$OUT" | cut -f1))"

# 복구 (조심: 지금 DB 내용이 백업 시점으로 바뀐다):
#   gzip -dc backups/prod/파일.sql.gz | docker compose -p mspace-prod --env-file .env.prod exec -T db psql -U "$DB_USERNAME" -d "$DB_NAME"
