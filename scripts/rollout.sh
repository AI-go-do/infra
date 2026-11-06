#!/usr/bin/env bash
# 무중단 교체 (infra/README.md "무중단 배포")
#   scripts/rollout.sh dev core gateway     # 개발 서버의 core·gateway를 끊김 없이 새 이미지로
#   scripts/rollout.sh prod web             # 시연 서버의 web
#   FORCE=1 scripts/rollout.sh dev core     # 바뀐 게 없어도 새로 띄운다 (재시작용)
#
# 한 서비스마다:
#   1) 이미지·설정이 그대로면 건너뛴다
#   2) 옛 컨테이너는 둔 채 새 컨테이너를 하나 더 띄운다 (compose --scale N+1 --no-recreate)
#   3) 새 컨테이너 health를 edge 안에서 직접 부른다. 실패하면 새 것만 지우고 멈춘다 → 옛 것이 계속 서비스
#   4) 성공하면 옛 컨테이너를 SIGTERM으로 끈다. Spring Boot·nginx가 하던 요청을 마치고 내려간다(graceful)
#      그동안 edge는 꺼지는 컨테이너 대신 새 컨테이너로 보낸다
#
# 무중단 대상: core, gateway, web (상태를 메모리에 두지 않는 서비스)
# mcp·agent는 확인 토큰·채팅 작업을 메모리에 들고 있어서 두 개가 같이 돌면 섞인다 → 지금처럼 다시 만들기(짧게 끊김)
# 이미지 받기(pull)는 이 스크립트 앞에서 한다 (deploy.yml)
set -euo pipefail

T="${1:?쓰는 법: scripts/rollout.sh <dev|prod> <서비스...>}"; shift
[ "$#" -gt 0 ] || { echo "바꿀 서비스를 적어 주세요 (core gateway web)"; exit 1; }
cd "$(dirname "$0")/.."
[ -f ".env.$T" ] || { echo ".env.$T 파일이 없음"; exit 1; }
C=(docker compose -p "mspace-$T" --env-file ".env.$T")

# 새 컨테이너가 준비될 때까지 기다리는 최대 시간(초). core는 Flyway까지 돌아서 오래 걸릴 수 있다
WAIT="${ROLLOUT_WAIT:-180}"
# 옛 컨테이너가 하던 요청을 마칠 시간(초). Spring Boot 기본 graceful 대기(30초)보다 조금 길게
GRACE="${ROLLOUT_GRACE:-35}"

health_url() {   # $1 서비스, $2 IP
  case "$1" in
    core)    echo "http://$2:8080/actuator/health" ;;
    gateway) echo "http://$2:8001/actuator/health" ;;   # 게이트웨이 자기 health(관리 포트). 8000의 health는 core로 간다
    web)     echo "http://$2:80/" ;;
    *)       echo "무중단 대상이 아님: $1 (core gateway web만)" >&2; return 1 ;;
  esac
}
# 안쪽 주소를 부르는 wget. jre 이미지엔 curl이 없고, 맥에선 호스트에서 컨테이너 IP가 안 보여서 같은 네트워크 안에서 부른다.
# 보통은 edge 안에서, edge가 아직 없을 때(처음 옮길 때)는 edge 이미지로 잠깐 컨테이너를 띄워서
probe() {
  if [ -n "$(running edge)" ]; then "${C[@]}" exec -T edge wget -qO- -T 3 "$1"
  else docker run --rm --network "$NET" "$EDGE_IMAGE" wget -qO- -T 3 "$1"; fi
}
healthy() {      # $1 서비스, $2 IP
  local body
  body=$(probe "$(health_url "$1" "$2")" 2>/dev/null) || return 1
  case "$1" in web) [ -n "$body" ] ;; *) grep -q '"status":"UP"' <<<"$body" ;; esac
}
ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1" | awk '{print $1}'; }
running() { "${C[@]}" ps -q --status running "$1"; }

# 이미지나 compose 설정이 바뀌었나 (지금 떠 있는 컨테이너와 비교)
#  - 설정(.env 태그·환경 변수 등): compose가 컨테이너에 붙여 둔 config-hash 라벨과 지금 설정의 hash
#  - 이미지: 같은 태그(develop 등)를 새로 받았으면 그 태그가 가리키는 이미지 ID가 컨테이너 것과 달라진다
changed() {
  local s="$1" want_hash c ref
  [ "${FORCE:-}" = 1 ] && return 0
  want_hash=$("${C[@]}" config --hash "$s" | awk '{print $2}')
  for c in $(running "$s"); do
    [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$c")" = "$want_hash" ] || return 0
    ref=$(docker inspect -f '{{.Config.Image}}' "$c")
    [ "$(docker inspect -f '{{.Image}}' "$c")" = "$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null)" ] || return 0
  done
  return 1
}

NET="mspace-${T}_default"
EDGE_IMAGE=$("${C[@]}" config --images edge | head -n 1)
docker image inspect "$EDGE_IMAGE" >/dev/null 2>&1 || "${C[@]}" pull -q edge

roll() {
  local s="$1" old new n ip o
  health_url "$s" x >/dev/null                   # 무중단 대상인지 먼저 확인
  if ! changed "$s"; then echo "[$s] 이미지·설정 그대로: 건너뜀"; return 0; fi
  "${C[@]}" rm -f "$s" >/dev/null 2>&1 || true    # 멈춰 있는 옛 컨테이너가 있으면 치운다(아래 scale이 그걸 되살리지 않게)
  old=$(running "$s" | sort)
  if [ -z "$old" ]; then                         # 떠 있는 게 없으면 무중단일 게 없다. 그냥 띄운다
    echo "[$s] 떠 있는 컨테이너가 없음: 새로 띄움"
    "${C[@]}" up -d --no-deps "$s"
    new=$(running "$s" | head -n 1)
  else
    n=$(wc -l <<<"$old")
    echo "[$s] 옛 컨테이너 $n개는 둔 채 새 컨테이너 1개 추가"
    "${C[@]}" up -d --no-deps --no-recreate --scale "$s=$((n + 1))" "$s"
    new=$(comm -13 <(echo "$old") <(running "$s" | sort) | head -n 1)
  fi
  [ -n "$new" ] || { echo "[$s] 새 컨테이너를 찾지 못함"; exit 1; }

  local start=$SECONDS
  while :; do
    # 죽었거나, 죽고 다시 켜진 적이 있으면(restart: unless-stopped라 계속 되살아난다) 실패로 본다
    if [ "$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$new" 2>/dev/null)" != "running 0" ]; then
      echo "[$s] 새 컨테이너가 죽음: 새 것만 지우고 옛 것을 그대로 둔다"; docker logs --tail=50 "$new" || true
      docker rm -f "$new" >/dev/null || true; exit 1
    fi
    ip=$(ip_of "$new")
    if [ -n "$ip" ] && healthy "$s" "$ip"; then echo "[$s] 새 컨테이너 준비됨 ($((SECONDS - start))초)"; break; fi
    if [ $((SECONDS - start)) -ge "$WAIT" ]; then
      echo "[$s] ${WAIT}초 안에 준비 안 됨: 새 것만 지우고 옛 것을 그대로 둔다"; docker logs --tail=50 "$new" || true
      [ -n "$old" ] && { docker rm -f "$new" >/dev/null || true; }
      exit 1
    fi
    sleep 1
  done

  [ -n "$old" ] || return 0
  # 옛 것을 끄기 전에 잠깐 기다린다. edge가 DNS를 다시 묻고(2초), 켜지는 동안 연결이 안 돼 잠깐 빼 둔
  # 새 컨테이너를 다시 넣을(fail_timeout 2초) 시간. 바로 끄면 edge가 둘 다 죽었다고 보고 502를 낸다 (시험에서 확인)
  sleep "${ROLLOUT_SETTLE:-5}"
  for o in $old; do
    echo "[$s] 옛 컨테이너 끄기 ($(docker inspect -f '{{.Name}}' "$o" | tr -d /), 하던 요청은 마치고 내려감)"
    docker stop -t "$GRACE" "$o" >/dev/null
    docker rm "$o" >/dev/null
  done
}

# 0) 입구 edge 준비
if [ -z "$(running edge)" ]; then
  # 처음 한 번: 서버 포트를 옛 gateway에서 edge로 옮긴다.
  # 새 gateway(포트 없음)를 먼저 띄워 확인 → 옛 gateway를 끄면 포트가 풀림 → 바로 edge가 잡는다. 끊김은 그 사이 몇 초
  echo "edge가 없음: 서버 포트를 gateway에서 edge로 옮긴다 (처음 한 번)"
  FORCE=1 roll gateway
  "${C[@]}" up -d --no-deps edge
fi
"${C[@]}" up -d --no-deps edge                  # edge의 compose 설정이 바뀌었을 때만 다시 만든다
for i in $(seq 1 10); do "${C[@]}" exec -T edge wget -qO- -T 2 http://127.0.0.1:8099/edge-health >/dev/null 2>&1 && break; sleep 1; done
"${C[@]}" exec -T edge nginx -t -q                # edge/default.conf 문법 확인. 틀리면 여기서 멈춘다(지금 설정 그대로)
"${C[@]}" exec -T edge nginx -s reload            # 바뀐 설정 반영. 끊기지 않는다

for s in "$@"; do roll "$s"; done
echo "무중단 교체 끝 ($T: $*)"
