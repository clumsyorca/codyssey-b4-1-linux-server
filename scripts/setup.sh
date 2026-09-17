#!/usr/bin/env bash
#
# B4-1 서버 부트스트랩 — STEP 1~8 전 과정을 한 번에 복원한다.
#
#   사용법 : sudo ./scripts/setup.sh
#   전제   : Ubuntu 22.04 LTS (또는 동등 환경), 인터넷 연결
#   특징   : 멱등(idempotent) — 여러 번 실행해도 안전
#
#   아키텍처(x86_64 / aarch64)는 자동 감지한다. 교육장 인텔 맥과
#   개인 Apple Silicon 맥을 오가도 같은 스크립트가 동작한다.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
APP_SRC_DIR="$REPO_DIR/app"

AGENT_HOME=/home/agent-admin/agent-app
LOG_DIR=/var/log/agent-app
SSH_PORT=20022
APP_PORT=15034

[ "$(id -u)" -eq 0 ] || { echo "ERROR: sudo 로 실행하세요"; exit 1; }

say() { printf '\n== %s ==\n' "$*"; }

# ─────────────────────────────────────────────────────────────
say "[1/9] 패키지 설치 (acl / openssh-server / ufw)"
NEED=()
command -v setfacl  >/dev/null || NEED+=(acl)
command -v sshd     >/dev/null || NEED+=(openssh-server)
command -v ufw      >/dev/null || NEED+=(ufw)
command -v crontab  >/dev/null || NEED+=(cron)
if [ ${#NEED[@]} -gt 0 ]; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${NEED[@]}"
    echo "   설치: ${NEED[*]}"
else
    echo "   전부 설치됨, 건너뜀"
fi

# ─────────────────────────────────────────────────────────────
say "[2/9] 그룹"
for g in agent-common agent-core; do
    if getent group "$g" >/dev/null; then echo "   $g 존재"; else groupadd "$g"; echo "   $g 생성"; fi
done

# ─────────────────────────────────────────────────────────────
say "[3/9] 계정"
add_user() {   # $1=계정  $2=그룹목록
    if id "$1" >/dev/null 2>&1; then echo "   $1 존재"; else useradd -m -s /bin/bash "$1"; echo "   $1 생성"; fi
    usermod -aG "$2" "$1"
}
add_user agent-admin agent-common,agent-core
add_user agent-dev   agent-common,agent-core
add_user agent-test  agent-common

# ─────────────────────────────────────────────────────────────
say "[4/9] 디렉토리 / 소유권 / 권한"
mkdir -p "$AGENT_HOME"/upload_files "$AGENT_HOME"/api_keys "$AGENT_HOME"/bin "$LOG_DIR"

chown agent-admin:agent-common "$AGENT_HOME" "$AGENT_HOME/upload_files"
chown agent-admin:agent-core   "$AGENT_HOME/api_keys" "$LOG_DIR"
chown agent-dev:agent-core     "$AGENT_HOME/bin"

chmod 750  "$AGENT_HOME"                       # 그룹은 통과+목록만
chmod 2770 "$AGENT_HOME/upload_files" "$AGENT_HOME/api_keys" "$LOG_DIR"
chmod 2750 "$AGENT_HOME/bin"                   # dev 작성 / admin 실행

# ─────────────────────────────────────────────────────────────
say "[5/9] ACL"
# 홈 디렉토리는 소유자 개인 그룹(agent-admin)이라 일반 권한으로는
# dev/test 에게 통행권(x)을 줄 방법이 없다. ACL 로 별도 부여한다.
setfacl -m  g:agent-common:r-x /home/agent-admin
setfacl -m  g:agent-common:rwx "$AGENT_HOME/upload_files"
setfacl -dm g:agent-common:rwx "$AGENT_HOME/upload_files"
setfacl -m  g:agent-core:rwx   "$AGENT_HOME/api_keys" "$LOG_DIR"
setfacl -dm g:agent-core:rwx   "$AGENT_HOME/api_keys" "$LOG_DIR"

# ─────────────────────────────────────────────────────────────
say "[6/9] 애플리케이션 배치 + 실행 환경"
case "$(uname -m)" in
    x86_64)        APP_BIN=agent-app-linux-x86   ;;
    aarch64|arm64) APP_BIN=agent-app-linux-arm64 ;;
    *) echo "ERROR: 지원하지 않는 아키텍처 $(uname -m)"; exit 1 ;;
esac
echo "   아키텍처 $(uname -m) → $APP_BIN"

if [ -f "$APP_SRC_DIR/$APP_BIN" ]; then
    install -o agent-admin -g agent-core -m 750 "$APP_SRC_DIR/$APP_BIN" "$AGENT_HOME/agent_app"
    echo "   agent_app 배치 완료"
else
    echo "   WARNING: $APP_SRC_DIR/$APP_BIN 없음 — 앱 배치 건너뜀"
fi

# 키 파일
#   과제 문서는 t_secret.key 를 명시하나 실제 바이너리는 secret.key 를 찾는다.
#   양쪽을 모두 만족시키기 위해 두 파일을 함께 생성한다.
for k in secret.key t_secret.key; do
    printf 'agent_api_key_test\n' > "$AGENT_HOME/api_keys/$k"
    chown agent-admin:agent-core "$AGENT_HOME/api_keys/$k"
    chmod 640 "$AGENT_HOME/api_keys/$k"
done

# 환경 변수
#   cron 은 로그인 셸이 아니라 ~/.profile 을 읽지 않는다.
#   진실의 원천을 agent.env 한 곳에 두고 셸과 monitor.sh 가 각각 읽어간다.
#   AGENT_KEY_PATH 는 파일이 아니라 디렉토리다(앱 요구사항).
cat > "$AGENT_HOME/agent.env" <<ENV
export AGENT_HOME=$AGENT_HOME
export AGENT_PORT=$APP_PORT
export AGENT_UPLOAD_DIR=\$AGENT_HOME/upload_files
export AGENT_KEY_PATH=\$AGENT_HOME/api_keys
export AGENT_LOG_DIR=$LOG_DIR
ENV
chown agent-admin:agent-core "$AGENT_HOME/agent.env"
chmod 640 "$AGENT_HOME/agent.env"

PROFILE=/home/agent-admin/.profile
LINE='[ -f "$HOME/agent-app/agent.env" ] && . "$HOME/agent-app/agent.env"'
grep -qxF "$LINE" "$PROFILE" 2>/dev/null || echo "$LINE" >> "$PROFILE"

# ─────────────────────────────────────────────────────────────
say "[7/9] monitor.sh 배치"
if [ -f "$SCRIPT_DIR/monitor.sh" ]; then
    install -o agent-dev -g agent-core -m 750 "$SCRIPT_DIR/monitor.sh" "$AGENT_HOME/bin/monitor.sh"
    echo "   $AGENT_HOME/bin/monitor.sh (agent-dev:agent-core 750)"
else
    echo "   WARNING: $SCRIPT_DIR/monitor.sh 없음"
fi

# ─────────────────────────────────────────────────────────────
say "[8/9] SSH (포트 $SSH_PORT / root 원격 로그인 차단)"
[ -f /etc/ssh/sshd_config.bak ] || cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i "s/^#\?Port .*/Port $SSH_PORT/"            /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
# 문법 검사를 통과했을 때만 재시작한다. 원격 서버에서 이 순서를 어기면
# sshd 가 죽은 채로 영구히 접속 불가가 된다.
sshd -t
systemctl restart ssh
echo "   $(sshd -T | grep -iE '^(port|permitrootlogin)' | tr '\n' ' ')"

# ─────────────────────────────────────────────────────────────
say "[9/9] 방화벽 (UFW) + cron"
# 순서 주의: 포트를 먼저 허용하고 나서 방화벽을 켠다.
ufw --force reset >/dev/null
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "$SSH_PORT"/tcp comment 'SSH' >/dev/null
ufw allow "$APP_PORT"/tcp comment 'agent-app' >/dev/null
ufw --force enable >/dev/null
echo "   $(ufw status | head -1) / 허용: $SSH_PORT,$APP_PORT tcp"

CRON_LINE="* * * * * $AGENT_HOME/bin/monitor.sh >> $LOG_DIR/monitor-cron.out 2>&1"
printf '# B4-1 시스템 관제 — monitor.sh 매분 실행 (실행 계정: agent-admin)\n%s\n' "$CRON_LINE" | crontab -u agent-admin -
echo "   crontab(agent-admin) 등록 완료"

# ─────────────────────────────────────────────────────────────
cat <<'DONE'

────────────────────────────────────────────────────────────
 setup 완료.

 앱 기동 :
   sudo -iu agent-admin bash -lc 'nohup "$AGENT_HOME/agent_app" \
        >> "$AGENT_LOG_DIR/agent-app.out" 2>&1 &'

 확인 :
   pgrep -x agent_app
   sudo ss -tulnp | grep -E '20022|15034'
   sudo -u agent-admin /home/agent-admin/agent-app/bin/monitor.sh
────────────────────────────────────────────────────────────
DONE
