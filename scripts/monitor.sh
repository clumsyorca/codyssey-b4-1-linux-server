#!/usr/bin/env bash
#
# monitor.sh — 시스템 관제 자동화 스크립트
#
#   배치 경로 : $AGENT_HOME/bin/monitor.sh
#   소유자    : agent-dev   그룹 : agent-core   권한 : 750
#   실행 주체 : agent-admin (crontab, 매분)
#
#   [동작]
#     1) Health Check  — 프로세스 / 포트. 실패 시 exit 1 (서비스 중단 = 사고)
#     2) 상태 점검      — 방화벽. 비활성이면 [WARNING] 만 출력하고 계속 진행
#     3) 자원 수집      — CPU / MEM / DISK 사용률
#     4) 임계값 경고    — CPU>20%, MEM>10%, DISK>80%
#     5) 로그 기록      — $AGENT_LOG_DIR/monitor.log 에 1 줄 append
#     6) 용량 관리      — 10MB 초과 시 회전, 최대 10 개 보관
#
#   set -e 는 쓰지 않는다. 각 점검의 실패를 직접 해석해서
#   "중단할 실패"와 "경고만 할 실패"를 구분해야 하기 때문.
#
set -u

# ────────────────────────────────────────────────────────────────
# 0. 환경 변수 로드
#    cron 은 로그인 셸이 아니라서 ~/.profile 을 읽지 않는다.
#    따라서 agent.env 를 스크립트가 직접 읽어야 한다.
# ────────────────────────────────────────────────────────────────
ENV_FILE=/home/agent-admin/agent-app/agent.env
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"

PROC_NAME="agent_app"
LOG_FILE="$AGENT_LOG_DIR/monitor.log"

CPU_THRESHOLD=20
MEM_THRESHOLD=10
DISK_THRESHOLD=80

MAX_SIZE=$((10 * 1024 * 1024))   # 10 MB
MAX_FILES=10                     # monitor.log + .1 ~ .9

# ────────────────────────────────────────────────────────────────
# 1. 로그 파일 회전 (용량 관리)
#    monitor.log 가 10MB 를 넘으면
#      .9 삭제 → .8→.9 → ... → .1→.2 → monitor.log→.1
#    로그를 방치하면 디스크가 차서 서버가 죽는다. 흔한 장애 원인.
# ────────────────────────────────────────────────────────────────
rotate_log() {
    # 로그 파일이 아직 없으면 회전할 것도 없다. return 0 = 정상 종료.
    [ -f "$LOG_FILE" ] || return 0

    # stat -c %s : 파일 크기를 바이트 단위 숫자로 출력한다.
    local size
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null) || return 0

    # -lt = less than(미만). 10MB 미만이면 아무것도 하지 않고 빠져나간다.
    [ "$size" -lt "$MAX_SIZE" ] && return 0

    # 여기부터가 실제 회전.
    #   .9 삭제 → .8을 .9로 → .7을 .8로 → ... → .1을 .2로 → 원본을 .1로
    #   번호가 밀려나다 9를 넘으면 사라지므로 총 10개(원본 + .1~.9)만 남는다.
    local last=$((MAX_FILES - 1))          # 9
    rm -f "${LOG_FILE}.${last}"            # 가장 오래된 것 폐기

    local i
    for (( i = last - 1; i >= 1; i-- )); do    # 8, 7, 6 ... 1 순서로
        if [ -f "${LOG_FILE}.${i}" ]; then
            mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
        fi
    done

    mv "$LOG_FILE" "${LOG_FILE}.1"         # 현재 로그를 .1 로 밀어낸다
    echo "[INFO] Log rotated (size ${size} bytes exceeded ${MAX_SIZE})"
}

# ────────────────────────────────────────────────────────────────
# 2. CPU 사용률
#
#   [원리]
#   리눅스는 /proc/stat 파일에 "CPU 가 무엇을 하며 보냈는지"를 적어둔다.
#
#     $ head -1 /proc/stat
#     cpu  12345 678 9012 345678 901 0 234 0
#           user nice sys  idle  io  ...
#
#   이 숫자들은 모두 "부팅 이후 누적 시간"이다.
#   따라서 한 번만 읽으면 현재 부하가 아니라 켜진 뒤 평균이 나온다.
#   1 초 간격으로 두 번 읽어 그 "차이"를 봐야 현재 부하를 알 수 있다.
#
#     CPU 사용률 = (1 - 쉰 시간 증가분 / 총 시간 증가분) x 100
# ────────────────────────────────────────────────────────────────

# 지금 이 순간의 "쉰 시간"과 "총 시간"을 한 쌍으로 출력한다.
cpu_snapshot() {
    local cpu user nice sys idle iowait irq softirq steal rest

    # read : 한 줄을 읽어 변수들에 순서대로 나눠 담는다.
    #        변수가 모자라면 마지막 변수(rest)가 나머지를 전부 가져간다.
    # -r   : 역슬래시를 특수문자로 해석하지 않는다(원문 그대로).
    # <    : 키보드가 아니라 이 파일에서 읽어온다.
    read -r cpu user nice sys idle iowait irq softirq steal rest < /proc/stat

    # $(( )) 안은 산술 계산. 없으면 "idle + iowait" 라는 글자로 취급된다.
    #   쉰 시간  = idle(놀았음) + iowait(디스크 기다리느라 못 했음)
    #   총 시간  = 모든 항목의 합
    local idle_time=$(( idle + iowait ))
    local total_time=$(( user + nice + sys + idle + iowait + irq + softirq + steal ))

    echo "$idle_time $total_time"
}

get_cpu_usage() {
    local idle_before total_before idle_after total_after

    # $( )  : 명령을 실행하고 그 출력을 값으로 가져온다.
    # <<<   : 파일 대신 "이 문자열"을 read 에 넣는다.
    #         cpu_snapshot 이 "345678 369038" 을 출력하면
    #         idle_before=345678 , total_before=369038 이 된다.
    read -r idle_before total_before <<< "$(cpu_snapshot)"

    sleep 1                                   # 1 초 기다렸다가

    read -r idle_after total_after <<< "$(cpu_snapshot)"   # 다시 측정

    # 계산에 awk 를 쓰는 이유:
    #   bash 의 $(( )) 는 정수만 다룬다.  $((7/2)) → 3  (소수점 버림)
    #   "9.2%" 같은 값을 내려면 소수 계산이 되는 awk 가 필요하다.
    #
    #   -v 이름="값"  : bash 변수를 awk 안으로 넘긴다.
    #   BEGIN { }     : 입력 파일 없이 이 블록만 실행한다.
    #   %.1f          : 소수점 1 자리로 출력한다.
    awk -v ib="$idle_before" -v tb="$total_before" \
        -v ia="$idle_after"  -v ta="$total_after" 'BEGIN {
        total_diff = ta - tb        # 1 초 동안 흐른 총 시간
        idle_diff  = ia - ib        # 그중 쉰 시간

        # 시간이 흐르지 않았으면(측정 실패) 0 을 반환해 0 나누기를 피한다.
        if (total_diff <= 0) { printf "0.0"; exit }

        # 쉰 비율을 1 에서 빼면 일한 비율. 100 을 곱해 퍼센트로.
        printf "%.1f", (1 - idle_diff / total_diff) * 100
    }'
}

# ────────────────────────────────────────────────────────────────
# 3. 메모리 사용률
#
#   MemFree 가 아니라 MemAvailable 을 쓴다.
#   리눅스는 남는 메모리를 디스크 캐시로 활용하는데, 이 캐시는 필요하면
#   즉시 반환되므로 사실상 여유 메모리다. MemFree 는 이것을 "사용 중"으로
#   세기 때문에 실제보다 훨씬 높게 나온다.
#   MemAvailable 은 커널이 "지금 당장 쓸 수 있는 양"을 계산해 둔 값이다.
# ────────────────────────────────────────────────────────────────
get_mem_usage() {
    # awk 는 파일을 한 줄씩 읽으며 /패턴/ 에 맞는 줄에서 { 동작 } 을 수행한다.
    #   $2 = 그 줄의 두 번째 칸(= 숫자 값, 단위 kB)
    #   END { } = 파일을 다 읽은 뒤 마지막에 한 번 실행
    awk '/^MemTotal:/     { total = $2 }
         /^MemAvailable:/ { avail = $2 }
         END {
             if (total > 0) printf "%.1f", (total - avail) / total * 100
             else           printf "0.0"
         }' /proc/meminfo
}

# ────────────────────────────────────────────────────────────────
# 4. 디스크 사용률 (루트 파티션)
# ────────────────────────────────────────────────────────────────
get_disk_usage() {
    # df -P /   : 루트 파티션의 사용량. -P(POSIX 형식)를 붙이는 이유는
    #             장치명이 길면 df 가 줄을 바꿔 출력해 칸 번호가 어긋나기 때문.
    # NR == 2   : 두 번째 줄(첫 줄은 제목이라 건너뜀)
    # $5        : 다섯 번째 칸 = 사용률. "23%" 처럼 % 가 붙어 있다.
    # gsub      : 그 % 기호를 지워 숫자만 남긴다.
    df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }'
}

# ────────────────────────────────────────────────────────────────
# 5. 방화벽 상태 (root 권한 없이 확인)
#    `ufw status` 는 root 가 필요하고, `systemctl is-active ufw` 는
#    믿을 수 없다 — ufw.service 는 부팅 시 한 번 실행되고 끝나는
#    oneshot 유닛이라, 런타임에 `ufw enable` 로 켜면 유닛 상태는
#    inactive(dead) 로 남으면서도 iptables 룰은 정상 적재되어 있다.
#    따라서 일반 계정도 읽을 수 있는 /etc/ufw/ufw.conf 의 ENABLED 를
#    1차 근거로 삼고, systemctl 은 보조 근거로만 쓴다.
# ────────────────────────────────────────────────────────────────
get_firewall_status() {
    if command -v ufw >/dev/null 2>&1; then
        if [ -r /etc/ufw/ufw.conf ] && grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf; then
            echo "ufw:active"
        elif systemctl is-active --quiet ufw 2>/dev/null; then
            echo "ufw:active"
        else
            echo "ufw:inactive"
        fi
    elif command -v firewall-cmd >/dev/null 2>&1; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            echo "firewalld:active"
        else
            echo "firewalld:inactive"
        fi
    else
        echo "none:notfound"
    fi
}

# ================================================================
#                           본  처  리
# ================================================================
echo "====== SYSTEM MONITOR RESULT ======"
echo

# ── [1] Health Check : 실패하면 즉시 종료 ────────────────────────
#
#   "서비스가 죽었다"는 즉시 대응해야 할 사고이므로 exit 1 로 끝낸다.
#   종료 코드는 0 = 성공, 0 이 아니면 실패라는 약속이며,
#   cron 이나 상위 감시 도구는 이 숫자를 보고 장애 여부를 판단한다.
#
echo "[HEALTH CHECK]"

# pgrep -x : 프로세스 "이름"이 정확히 일치하는 것만 찾는다.
#            -f 는 명령줄 전체를 매칭하므로, 이 스크립트 자신의 명령줄에
#            들어 있는 문자열까지 걸려 자기 자신을 잡는 사고가 난다.
# head -1  : 앱이 부모/자식 두 프로세스로 뜨므로 첫 번째(대표) PID 만 쓴다.
PID=$(pgrep -x "$PROC_NAME" 2>/dev/null | head -1)

# -z = zero length(빈 문자열). 즉 "PID 를 못 찾았다면".
if [ -z "$PID" ]; then
    echo "Checking process '$PROC_NAME'... [FAIL]"
    echo "[CRITICAL] Process '$PROC_NAME' is not running."
    exit 1
fi
echo "Checking process '$PROC_NAME'... [OK] (PID: $PID)"

# 프로세스가 살아 있어도 포트를 못 잡았으면 외부에서는 서비스 불가다.
# 그래서 둘을 따로 확인한다.
#
#   ss -ltn : -l 대기(LISTEN) 중인 것만, -t TCP 만, -n 이름변환 생략(빠름)
#             -p(프로세스명)는 root 권한이 필요해 일부러 뺐다.
#   $4      : 네 번째 칸 = "주소:포트"
#   :포트$  : 끝을 $ 로 고정하지 않으면 150340 같은 포트에도 걸린다.
#             IPv6 형태인 [::]:15034 도 이 패턴으로 함께 잡힌다.
if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${AGENT_PORT}$"; then
    echo "Checking port $AGENT_PORT... [FAIL]"
    echo "[CRITICAL] Port $AGENT_PORT is not in LISTEN state."
    exit 1
fi
echo "Checking port $AGENT_PORT... [OK]"
echo

# ── [2] 방화벽 : 경고만 하고 계속 진행 ───────────────────────────
#
#   방화벽이 꺼진 것은 보안 문제지만 서비스 자체는 동작한다.
#   모든 이상을 긴급으로 처리하면 알림이 과다해져 진짜 사고를 놓치므로,
#   "지금 서비스가 멈췄는가"를 기준으로 중단과 경고를 나눈다.
#
echo "[FIREWALL CHECK]"
FW=$(get_firewall_status)
FW_TOOL="${FW%%:*}"      # %%:*  = 첫 ':' 앞부분만  → ufw
FW_STATE="${FW##*:}"     # ##*:  = 마지막 ':' 뒷부분만 → active
case "$FW_STATE" in
    active)   echo "Checking firewall ($FW_TOOL)... [OK] (active)" ;;
    inactive) echo "Checking firewall ($FW_TOOL)... [WARNING]"
              echo "[WARNING] Firewall ($FW_TOOL) is INACTIVE." ;;
    *)        echo "Checking firewall... [WARNING]"
              echo "[WARNING] No firewall tool (ufw/firewalld) found." ;;
esac
echo

# ── [3] 자원 수집 ────────────────────────────────────────────────
#
#   헬스체크는 "죽었나 살았나"라는 이분법이라 이미 죽은 뒤에야 알려준다.
#   자원 수치는 "얼마나 위태로운가"를 알려주므로 죽기 전에 대응할 수 있다.
#
echo "[RESOURCE MONITORING]"
CPU=$(get_cpu_usage)
MEM=$(get_mem_usage)
DISK=$(get_disk_usage)

printf "CPU Usage  : %s%%\n" "$CPU"
printf "MEM Usage  : %s%%\n" "$MEM"
printf "DISK Used  : %s%%\n" "$DISK"
echo

# ── [4] 임계값 경고 : 경고만, 종료하지 않음 ─────────────────────
#
#   값이 소수(예: 9.2)라 bash 의 정수 비교로는 판단할 수 없다.
#   awk 의 BEGIN 블록에서 비교하고 그 결과를 종료 코드로 돌려받는다.
#     exit !(v > t)  →  초과면 exit 0(성공) → && 뒤가 실행되어 경고 출력
#                       아니면 exit 1        → && 뒤를 건너뜀
#
WARNED=0
awk -v v="$CPU" -v t="$CPU_THRESHOLD" 'BEGIN { exit !(v > t) }' \
    && { echo "[WARNING] CPU threshold exceeded (${CPU}% > ${CPU_THRESHOLD}%)"; WARNED=1; }
awk -v v="$MEM" -v t="$MEM_THRESHOLD" 'BEGIN { exit !(v > t) }' \
    && { echo "[WARNING] MEM threshold exceeded (${MEM}% > ${MEM_THRESHOLD}%)"; WARNED=1; }
awk -v v="$DISK" -v t="$DISK_THRESHOLD" 'BEGIN { exit !(v > t) }' \
    && { echo "[WARNING] DISK threshold exceeded (${DISK}% > ${DISK_THRESHOLD}%)"; WARNED=1; }
[ "$WARNED" -eq 0 ] && echo "[OK] All resource usage within thresholds."
echo

# ── [5] 로그 기록 ────────────────────────────────────────────────
if [ ! -d "$AGENT_LOG_DIR" ]; then            # -d = 디렉토리가 존재하는가
    echo "[ERROR] Log directory not found: $AGENT_LOG_DIR"
    exit 1
fi
if [ ! -w "$AGENT_LOG_DIR" ]; then            # -w = 쓸 수 있는가
    echo "[ERROR] Log directory not writable: $AGENT_LOG_DIR"
    exit 1
fi

rotate_log                                    # 쓰기 전에 용량부터 확인

TS=$(date '+%Y-%m-%d %H:%M:%S')

#   >>  는 파일 끝에 "이어쓰기".  >  를 쓰면 매 실행마다 파일을 비우고
#   새로 써서 이전 기록이 전부 사라진다. 로그의 가치는 시계열에 있으므로
#   누적이 필수다.
#   %%  는 printf 에서 % 기호 자체를 출력하기 위한 표기다.
printf '[%s] PID:%s CPU:%s%% MEM:%s%% DISK_USED:%s%%\n' \
    "$TS" "$PID" "$CPU" "$MEM" "$DISK" >> "$LOG_FILE"

echo "[INFO] Log appended: $LOG_FILE"
exit 0
