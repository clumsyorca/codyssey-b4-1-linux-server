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
    [ -f "$LOG_FILE" ] || return 0

    local size
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null) || return 0
    [ "$size" -lt "$MAX_SIZE" ] && return 0

    local last=$((MAX_FILES - 1))
    rm -f "${LOG_FILE}.${last}"

    local i
    for (( i = last - 1; i >= 1; i-- )); do
        if [ -f "${LOG_FILE}.${i}" ]; then
            mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
        fi
    done

    mv "$LOG_FILE" "${LOG_FILE}.1"
    echo "[INFO] Log rotated (size ${size} bytes exceeded ${MAX_SIZE})"
}

# ────────────────────────────────────────────────────────────────
# 2. CPU 사용률
#    /proc/stat 을 1 초 간격으로 두 번 읽어 그 차이로 계산한다.
#    한 번만 읽으면 "부팅 이후 누적 평균"이 나와서 현재 부하를 알 수 없다.
# ────────────────────────────────────────────────────────────────
cpu_snapshot() {
    local cpu user nice sys idle iowait irq softirq steal rest
    read -r cpu user nice sys idle iowait irq softirq steal rest < /proc/stat
    echo "$((idle + iowait)) $((user + nice + sys + idle + iowait + irq + softirq + steal))"
}

get_cpu_usage() {
    local i1 t1 i2 t2
    read -r i1 t1 <<< "$(cpu_snapshot)"
    sleep 1
    read -r i2 t2 <<< "$(cpu_snapshot)"

    awk -v i1="$i1" -v t1="$t1" -v i2="$i2" -v t2="$t2" 'BEGIN {
        dt = t2 - t1; di = i2 - i1
        if (dt <= 0) { printf "0.0"; exit }
        printf "%.1f", (1 - di / dt) * 100
    }'
}

# ────────────────────────────────────────────────────────────────
# 3. 메모리 사용률
#    MemAvailable 기준. MemFree 를 쓰면 캐시를 "사용 중"으로 세어
#    실제보다 훨씬 높게 나온다.
# ────────────────────────────────────────────────────────────────
get_mem_usage() {
    awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2}
         END { if (t > 0) printf "%.1f", (t - a) / t * 100; else printf "0.0" }' /proc/meminfo
}

# ────────────────────────────────────────────────────────────────
# 4. 디스크 사용률 (루트 파티션)
# ────────────────────────────────────────────────────────────────
get_disk_usage() {
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
echo "[HEALTH CHECK]"

PID=$(pgrep -x "$PROC_NAME" 2>/dev/null | head -1)
if [ -z "$PID" ]; then
    echo "Checking process '$PROC_NAME'... [FAIL]"
    echo "[CRITICAL] Process '$PROC_NAME' is not running."
    exit 1
fi
echo "Checking process '$PROC_NAME'... [OK] (PID: $PID)"

if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${AGENT_PORT}$"; then
    echo "Checking port $AGENT_PORT... [FAIL]"
    echo "[CRITICAL] Port $AGENT_PORT is not in LISTEN state."
    exit 1
fi
echo "Checking port $AGENT_PORT... [OK]"
echo

# ── [2] 방화벽 : 경고만 하고 계속 진행 ───────────────────────────
echo "[FIREWALL CHECK]"
FW=$(get_firewall_status)
FW_TOOL="${FW%%:*}"
FW_STATE="${FW##*:}"
case "$FW_STATE" in
    active)   echo "Checking firewall ($FW_TOOL)... [OK] (active)" ;;
    inactive) echo "Checking firewall ($FW_TOOL)... [WARNING]"
              echo "[WARNING] Firewall ($FW_TOOL) is INACTIVE." ;;
    *)        echo "Checking firewall... [WARNING]"
              echo "[WARNING] No firewall tool (ufw/firewalld) found." ;;
esac
echo

# ── [3] 자원 수집 ────────────────────────────────────────────────
echo "[RESOURCE MONITORING]"
CPU=$(get_cpu_usage)
MEM=$(get_mem_usage)
DISK=$(get_disk_usage)

printf "CPU Usage  : %s%%\n" "$CPU"
printf "MEM Usage  : %s%%\n" "$MEM"
printf "DISK Used  : %s%%\n" "$DISK"
echo

# ── [4] 임계값 경고 : 경고만, 종료하지 않음 ─────────────────────
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
if [ ! -d "$AGENT_LOG_DIR" ]; then
    echo "[ERROR] Log directory not found: $AGENT_LOG_DIR"
    exit 1
fi
if [ ! -w "$AGENT_LOG_DIR" ]; then
    echo "[ERROR] Log directory not writable: $AGENT_LOG_DIR"
    exit 1
fi

rotate_log

TS=$(date '+%Y-%m-%d %H:%M:%S')
printf '[%s] PID:%s CPU:%s%% MEM:%s%% DISK_USED:%s%%\n' \
    "$TS" "$PID" "$CPU" "$MEM" "$DISK" >> "$LOG_FILE"

echo "[INFO] Log appended: $LOG_FILE"
exit 0
