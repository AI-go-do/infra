# infra

M-SPACE 서버 실행 설정 (담당: 재웅). 앱 코드는 각 저장소(mspace-core, mspace-web …)에 있고, 여기는 **서버에서 어떻게 띄우는지**만 둔다.

| 파일 | 하는 일 |
|---|---|
| `compose.yaml` | 입구 nginx → core → PostgreSQL, AI 비서(mcp·agent)는 안쪽에서만. 밖으로 열리는 포트는 nginx 하나 |
| `nginx/default.conf` | `/api` → core, 나머지 → 화면(web, 준비 중) |
| `scripts/backup.sh` | DB를 `backups/dev/`·`backups/prod/`에 날짜별로 백업, 7일 지난 건 삭제. 서버 cron으로 매일 실행 |
| `.env.example` | 환경별 값 목록 (값은 비움). 실제 값은 `.env.dev` / `.env.prod`, 커밋 금지 |

## 띄우기

```bash
cp .env.example .env.dev        # DB_PASSWORD 채우기
docker compose -p mspace-dev  --env-file .env.dev  up -d    # 개발 (8411, develop 이미지)
docker compose -p mspace-prod --env-file .env.prod up -d    # 시연 (8412, main 이미지)
curl localhost:8411/actuator/health
```

## 되돌리기

`.env.*`의 `CORE_TAG`(비서는 `ASSISTANT_TAG`)를 이전 이미지(`sha-xxxxxxx`)로 바꾸고 `docker compose ... up -d`.

## 백업

```bash
scripts/backup.sh prod                     # 지금 바로 한 번
crontab -e                                 # 매일 새벽 4시 자동
0 4 * * * cd ~/infra && scripts/backup.sh prod >> backups/backup.log 2>&1
```

복구 방법은 `scripts/backup.sh` 맨 아래 주석에 있다. 복구하면 지금 DB가 백업 시점으로 덮어써진다.
