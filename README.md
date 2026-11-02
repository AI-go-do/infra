# infra

M-SPACE 서버 실행 설정 (담당: 재웅). 앱 코드는 각 저장소(mspace-core, mspace-web …)에 있고, 여기는 **서버에서 어떻게 띄우는지**만 둔다.

| 파일 | 하는 일 |
|---|---|
| `compose.yaml` | 입구 nginx → core → PostgreSQL. 밖으로 열리는 포트는 nginx 하나 |
| `nginx/default.conf` | `/api` → core, 나머지 → 화면(web, 준비 중) |
| `.env.example` | 환경별 값 목록 (값은 비움). 실제 값은 `.env.dev` / `.env.prod`, 커밋 금지 |

## 띄우기

```bash
cp .env.example .env.dev        # DB_PASSWORD 채우기
docker compose -p mspace-dev  --env-file .env.dev  up -d    # 개발 (8411, develop 이미지)
docker compose -p mspace-prod --env-file .env.prod up -d    # 시연 (8410, main 이미지)
curl localhost:8411/actuator/health
```

## 되돌리기

`.env.*`의 `CORE_TAG`를 이전 이미지(`sha-xxxxxxx`)로 바꾸고 `docker compose ... up -d`.
