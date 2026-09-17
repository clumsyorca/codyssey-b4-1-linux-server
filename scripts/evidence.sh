#!/usr/bin/env bash
#
# 증거 로그 헬퍼 — 과제 "필수 증거 자료 체크리스트" 형식에 맞춘 로그를 남긴다.
#
#   [사용법]  VM 안에서 한 번만:
#     source /Users/tokomon/Documents/codyssey/B4-1/scripts/evidence.sh
#
#   [그 다음]
#     ev_start "③ 계정/그룹 생성 확인" 03-users-groups.log
#     ev_run   "id agent-admin"
#     ev_note  "agent-test 는 agent-core 에 미포함(의도된 설계)"
#     ev_end
#
#   ev_start 는 파일을 새로 씁니다(덮어쓰기). 같은 단계를 다시 실행해도
#   내용이 중복되지 않고 항상 최신 1벌만 남습니다.
#

ev_start() {
  if [ -z "${LOG:-}" ]; then
    echo "ERROR: \$LOG 환경변수가 없습니다. 'source ~/.bashrc' 후 다시 시도하세요." >&2
    return 1
  fi
  EV_FILE="$LOG/$2"
  {
    echo "=================================================================="
    echo " 증거자료 : $1"
    echo " 일시     : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo " 호스트   : $(hostname)"
    echo " OS       : $( . /etc/os-release && echo "$PRETTY_NAME" ) / $(uname -m)"
    echo " 실행계정 : $(whoami)"
    echo "=================================================================="
  } | tee "$EV_FILE"
}

ev_run() {
  {
    echo
    echo "\$ $*"
    echo "------------------------------------------------------------------"
    eval "$@" 2>&1 | sed 's/^/   /'
    echo "   [exit=${PIPESTATUS[0]}]"
  } | tee -a "$EV_FILE"
}

ev_note() {
  { echo; echo "※ $*"; } | tee -a "$EV_FILE"
}

ev_end() {
  {
    echo
    echo "=========================== 기록 끝 ==============================="
  } | tee -a "$EV_FILE"
  echo
  echo ">> 저장 완료: $EV_FILE"
}
