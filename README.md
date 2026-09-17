# B4-1 — 컴퓨터가 알아서 자기 상태를 점검하게 만들기

리눅스 서버의 기본 보안(SSH·방화벽), 역할 기반 계정/권한 체계, 애플리케이션 실행 환경을
구성하고 시스템 상태를 주기적으로 수집·기록하는 관제 자동화를 구현했다.

**제출물**
- 요구사항 수행 내역서 — 본 문서
- 자동화 스크립트 — [`scripts/monitor.sh`](scripts/monitor.sh)

---

## 1. 실습 환경

| 항목 | 값 |
|---|---|
| 호스트 | macOS (Apple Silicon) |
| 가상화 | OrbStack Linux Machine (`agent`) |
| OS | Ubuntu 22.04.5 LTS / aarch64 |
| 자원 | 11 vCPU / 8,999 MB RAM |
| VM IP | 192.168.139.141 |

---

## 2. 최종 구성

```
                      호스트 (macOS)
                            │
                  20022 ────┼──── 15034          ← 이 두 포트만 통과
                            │
        ┌───────────────────▼───────────────────┐
        │  UFW  default deny incoming            │
        ├────────────────────────────────────────┤
        │  sshd :20022 (root 로그인 차단)         │
        │  agent_app :15034                      │
        │       ▲                                │
        │       │ 감시                            │
        │  monitor.sh ──▶ /var/log/agent-app/monitor.log
        │       ▲                                │
        │       │ 매분 호출                       │
        │  crontab (agent-admin)                 │
        └────────────────────────────────────────┘
```

| 계정 | uid | 소속 그룹 | 역할 |
|---|---|---|---|
| `agent-admin` | 1000 | agent-common, agent-core | 운영·관리, cron 실행자 |
| `agent-dev` | 1001 | agent-common, agent-core | 개발, monitor.sh 작성자 |
| `agent-test` | 1002 | agent-common | QA·테스트 |

| 경로 | 소유자 | 그룹 | 권한 | 성격 |
|---|---|---|---|---|
| `$AGENT_HOME` | agent-admin | agent-common | `750` | 진입점 |
| `$AGENT_HOME/upload_files` | agent-admin | agent-common | `2770` | 공유 |
| `$AGENT_HOME/api_keys` | agent-admin | agent-core | `2770` | 보안 |
| `$AGENT_HOME/bin` | agent-dev | agent-core | `2750` | 스크립트 |
| `/var/log/agent-app` | agent-admin | agent-core | `2770` | 보안 |

---

## 3. 수행 내역

### ① SSH 포트 변경(20022) 및 Root 원격 접속 차단

**설정**

```bash
sudo apt install -y openssh-server
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sudo sed -i 's/^#\?Port .*/Port 20022/'                   /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sshd -t                    # 문법 검사
sudo systemctl restart ssh
```

**확인**

```
$ sudo sshd -T | grep -iE '^(port|permitrootlogin)'
port 20022
permitrootlogin no
```

| 접속 시험 | 결과 |
|---|---|
| `ssh -p 20022 agent-admin@localhost` | 성공 |
| `ssh -p 20022 root@localhost` | `Permission denied` |
| `ssh -p 22 agent-admin@localhost` | `Connection refused` |

**설명 포인트**
- 포트 22와 계정명 root는 모든 리눅스에 공통이라 자동화된 공격의 기본 표적이다. 포트를 옮기면 무차별 스캔 대부분이 비껴가고, root를 막으면 공격자가 계정명부터 알아내야 한다.
- 근본 방어는 아니지만 공격 표면과 로그 소음을 줄여 실제 위협을 식별하기 쉽게 만든다.
- 재시작 전 `sshd -t`를 반드시 수행한다. 설정 오류 상태로 재시작하면 sshd가 기동에 실패하고, 원격 서버라면 그 순간 접속 경로가 사라진다.

**증거** — [`docs/logs/01-ssh.log`](docs/logs/01-ssh.log) · [ssh-login.png](docs/screenshots/ssh-login.png)

---

### ② 방화벽(UFW) 활성화 및 20022/tcp, 15034/tcp만 허용

**설정**

```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 20022/tcp comment 'SSH'
sudo ufw allow 15034/tcp comment 'agent-app'
sudo ufw enable                 # 포트 허용 후에 활성화
```

**확인**

```
$ sudo ufw status verbose
Status: active
Default: deny (incoming), allow (outgoing), deny (routed)

To                  Action      From
20022/tcp           ALLOW IN    Anywhere        # SSH
15034/tcp           ALLOW IN    Anywhere        # agent-app
```

호스트(macOS) → VM 외부 접속 시험

| 포트 | 결과 | 판정 |
|---|---|---|
| 20022 | `succeeded` | 허용 |
| 15034 | `succeeded` | 허용 |
| 22 | `Operation timed out` | 차단 |
| 8080 | `Operation timed out` | 차단 |

**설명 포인트**
- 기본 정책을 `deny incoming`으로 두고 필요한 포트만 여는 화이트리스트 방식이다. 차단할 대상은 무한하지만 열어야 할 대상은 유한하다.
- 검증은 `ufw status`만으로 부족하고 외부에서 실제 접속을 시도해야 한다. 방화벽 없이 포트만 닫혀 있으면 `Connection refused`가 즉시 반환된다. `timed out`은 UFW가 패킷에 응답하지 않고 DROP한다는 뜻이며, 공격자에게 호스트·포트의 존재조차 노출하지 않는다.
- 포트를 먼저 허용하고 방화벽을 켜는 순서를 지켜야 한다. 반대로 하면 SSH 연결이 끊긴다.

**증거** — [`docs/logs/02-firewall.log`](docs/logs/02-firewall.log) · [ufw-status.png](docs/screenshots/ufw-status.png)

---

### ③ 계정/그룹 생성

**설정**

```bash
sudo groupadd agent-common
sudo groupadd agent-core
sudo useradd -m -s /bin/bash -G agent-common,agent-core agent-admin
sudo useradd -m -s /bin/bash -G agent-common,agent-core agent-dev
sudo useradd -m -s /bin/bash -G agent-common            agent-test
```

**확인**

```
$ getent group agent-common agent-core
agent-common:x:1000:agent-admin,agent-dev,agent-test
agent-core:x:1001:agent-admin,agent-dev
```

**설명 포인트**
- `agent-test`만 `agent-core`에서 제외된다. QA 담당자가 API 키와 운영 로그에 접근할 이유가 없다.
- 권한을 직무에 필요한 최소 범위로 부여하면 사고가 나도 피해 범위가 그 역할 안으로 제한된다.
- 그룹이 존재하는 이유는 "나 / 나머지 전부" 두 단계만으로는 일부에게만 열어주는 통제가 불가능하기 때문이다.

**증거** — [`docs/logs/03-users-groups.log`](docs/logs/03-users-groups.log)

---

### ④ 디렉토리 구조 및 권한(ACL 포함)

**설정**

```bash
sudo mkdir -p /home/agent-admin/agent-app/{upload_files,api_keys,bin} /var/log/agent-app

sudo chown agent-admin:agent-common $AGENT_HOME $AGENT_HOME/upload_files
sudo chown agent-admin:agent-core   $AGENT_HOME/api_keys /var/log/agent-app
sudo chown agent-dev:agent-core     $AGENT_HOME/bin

sudo chmod 750  $AGENT_HOME
sudo chmod 2770 $AGENT_HOME/upload_files $AGENT_HOME/api_keys /var/log/agent-app
sudo chmod 2750 $AGENT_HOME/bin

sudo setfacl -m  g:agent-common:r-x /home/agent-admin          # 상위 통행권
sudo setfacl -m  g:agent-common:rwx $AGENT_HOME/upload_files
sudo setfacl -dm g:agent-common:rwx $AGENT_HOME/upload_files
sudo setfacl -m  g:agent-core:rwx   $AGENT_HOME/api_keys /var/log/agent-app
sudo setfacl -dm g:agent-core:rwx   $AGENT_HOME/api_keys /var/log/agent-app
```

**확인**

| 시험 | 기대 | 결과 |
|---|---|---|
| `agent-dev` → `$AGENT_HOME` 진입 | 성공 | ✅ |
| `agent-test` → `upload_files` 쓰기 | 성공 | ✅ |
| `agent-test` → `api_keys` 접근 | **차단** | `Permission denied` |
| `agent-dev` → `api_keys` 접근 | 성공 | ✅ |
| 신규 파일 속성 | `agent-common` / `rw-rw----` | ✅ |

**설명 포인트**
- 소유권(`chown`)은 "누구인지"를, 권한(`chmod`)은 "그 누구가 무엇을 할 수 있는지"를 정한다. 둘은 세트로 써야 의미가 생긴다.
- 선행 비트 `2`는 **setgid**다. 이 디렉토리에 새로 생기는 파일이 생성자의 개인 그룹이 아니라 디렉토리의 그룹을 상속한다. 없으면 `agent-dev`가 공유 폴더에 만든 파일을 `agent-test`가 읽지 못한다.
- `bin`을 `2750`으로 둔 것은 `agent-dev`(소유자)만 스크립트를 수정하고 `agent-admin`(그룹)은 읽기·실행만 하게 하기 위해서다. cron 실행에는 `r-x`면 충분하다.
- **ACL이 반드시 필요했던 지점**: `AGENT_HOME`의 상위인 `/home/agent-admin`은 `drwxr-x--- agent-admin:agent-admin`이다. 디렉토리에서 `x`는 "통과"를 뜻하므로 `agent-dev`/`agent-test`는 하위 권한과 무관하게 진입 자체가 불가능했다. 일반 권한은 그룹을 하나만 지정할 수 있어 여기에 `agent-common`을 추가할 방법이 없고, ACL로만 해결된다.
- `-d`(default) 옵션은 **권한 상속**을 담당한다. setgid가 그룹을 상속시키더라도 권한은 umask(022)를 따라 `rw-r--r--`가 되어 그룹이 쓰기를 못 한다. setgid + default ACL이 함께 있어야 공유가 완성된다.

**증거** — [`docs/logs/04-directories-acl.log`](docs/logs/04-directories-acl.log)

---

### ⑤ 앱 Boot Sequence 5단계 [OK] 및 "Agent READY"

**설정**

```bash
# 아키텍처 자동 감지 후 배치. 파일명은 agent_app 으로 통일한다.
case "$(uname -m)" in
  x86_64)        APP=agent-app-linux-x86   ;;
  aarch64|arm64) APP=agent-app-linux-arm64 ;;
esac
sudo install -o agent-admin -g agent-core -m 750 "app/$APP" "$AGENT_HOME/agent_app"

# 키 파일
echo 'agent_api_key_test' | sudo -u agent-admin tee $AGENT_HOME/api_keys/secret.key
sudo chmod 640 $AGENT_HOME/api_keys/secret.key
```

환경 변수는 `$AGENT_HOME/agent.env` 한 곳에 정의한다.

```bash
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
export AGENT_KEY_PATH=$AGENT_HOME/api_keys
export AGENT_LOG_DIR=/var/log/agent-app
```

**확인**

```
[1/5] Checking User Account               [OK]   ... Running as service user 'agent-admin' (uid=1000)
[2/5] Verifying Environment Variables     [OK]   ... All required Envs correct
[3/5] Checking Required Files             [OK]   ... Verified 'secret.key' with correct key string.
[4/5] Checking Port Availability          [OK]   ... Port 15034 is available.
[5/5] Verifying Log Permission            [OK]   ... Log directory is writable: /var/log/agent-app
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
```

상시 구동은 백그라운드로 실행한다.

```bash
sudo -iu agent-admin bash -lc 'nohup "$AGENT_HOME/agent_app" >> "$AGENT_LOG_DIR/agent-app.out" 2>&1 &'
```

**설명 포인트**
- 경로·포트를 코드에 박아넣으면 환경마다 코드를 고쳐야 한다. 환경 변수로 빼면 같은 바이너리가 환경만 바꿔 동작한다.
- 환경 변수를 셸 프로필이 아니라 **파일 하나**로 분리한 이유는 cron 때문이다. cron은 로그인 셸이 아니어서 `~/.profile`을 읽지 않는다. 셸 프로필에만 두면 수동 실행은 성공하고 cron 실행만 실패한다. `agent.env`를 진실의 원천으로 두고 셸과 `monitor.sh`가 각각 읽어간다.
- 루트로 실행하지 않는 이유는, 앱이 침해당하면 공격자가 그 프로세스의 권한을 그대로 얻기 때문이다. root로 구동하면 앱 취약점 하나가 서버 전체 장악으로 이어진다.
- `nohup ... &`로 띄우는 이유는 터미널 세션에 묶어두면 방화벽 설정·monitor.sh 검증 구간 동안 서비스가 유지되지 않기 때문이다.

**증거** — [`docs/logs/05-app-boot.log`](docs/logs/05-app-boot.log) · [app-ready.png](docs/screenshots/app-ready.png)

---

### ⑥ monitor.sh 실행 결과

소스: [`scripts/monitor.sh`](scripts/monitor.sh)

**배치 정책**

```
경로   $AGENT_HOME/bin/monitor.sh
소유자 agent-dev      그룹 agent-core      권한 750
```

**실행 결과**

```
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent_app'... [OK] (PID: 5454)
Checking port 15034... [OK]

[FIREWALL CHECK]
Checking firewall (ufw)... [OK] (active)

[RESOURCE MONITORING]
CPU Usage  : 0.5%
MEM Usage  : 8.8%
DISK Used  : 1%

[OK] All resource usage within thresholds.

[INFO] Log appended: /var/log/agent-app/monitor.log
```

**실패 등급 구분** — 이 스크립트의 핵심 설계

| 점검 | 이상 시 동작 | 근거 |
|---|---|---|
| 프로세스 부재 | `exit 1` | 서비스 중단 = 즉시 대응할 사고 |
| 포트 미개방 | `exit 1` | 프로세스가 살아도 서비스 불가 |
| 방화벽 비활성 | `[WARNING]` 후 계속 | 보안 이슈이나 서비스는 정상 |
| 임계값 초과 | `[WARNING]` 후 계속 | 추세 관찰 대상 |

실제 재현 결과

| 시나리오 | 출력 | exit |
|---|---|---|
| 정상 | 전 항목 `[OK]` | 0 |
| 앱 중단 | `[CRITICAL] Process 'agent_app' is not running.` | **1** |
| 방화벽 비활성 | `[WARNING] Firewall (ufw) is INACTIVE.` 후 로그 기록까지 완료 | 0 |
| CPU 초과 | `[WARNING] CPU threshold exceeded (36.6% > 20%)` | 0 |
| MEM 초과 | `[WARNING] MEM threshold exceeded (10.2% > 10%)` | 0 |

**자원 수집 방식**

| 지표 | 방식 | 이유 |
|---|---|---|
| CPU | `/proc/stat`을 1초 간격 2회 읽어 차분 계산 | 1회만 읽으면 부팅 이후 누적 평균이 나와 현재 부하를 알 수 없다 |
| MEM | `/proc/meminfo`의 `MemAvailable` 기준 | `MemFree`를 쓰면 캐시를 사용 중으로 세어 실제보다 크게 나온다 |
| DISK | `df -P /`의 Used % | 루트 파티션 기준 |

CPU 계산 검증 (11코어)

| 부하 | 측정값 | 이론값 |
|---|---|---|
| 없음 | 0.3% | ~0% |
| 1코어 100% | 9.2% | 9.1% |
| 4코어 100% | 37.5% | 36.4% |

**설명 포인트**
- 모든 이상을 긴급으로 처리하면 알림이 과다해져 실제 사고를 놓친다. 그래서 "중단시킬 실패"와 "기록만 할 이상"을 구분했다.
- 프로세스와 포트를 모두 확인하는 이유는, 프로세스가 살아 있어도 포트를 잡지 못하면 서비스는 불가능하기 때문이다.
- 임계값 CPU 20% / MEM 10%는 제공 앱의 부하 패턴(메모리 0 → 256MB → 0 순환)에서 경고가 실제로 발생하도록 설계된 값이다. MEM은 `10.2%`로 자연 발생했고, CPU는 본 VM이 11코어여서 앱이 1코어를 점유해도 전체로는 9%대라 임계값에 닿지 않으므로 4코어 인위 부하로 로직을 검증했다.

**증거** — [`docs/logs/06-monitor-run.log`](docs/logs/06-monitor-run.log) · [monitor-run.png](docs/screenshots/monitor-run.png)

---

### ⑦ monitor.log 누적 기록 및 용량 관리

**로그 포맷**

```
[2026-09-17 14:55:02] PID:5454 CPU:0.1% MEM:7.1% DISK_USED:1%
[2026-09-17 14:56:02] PID:5454 CPU:0.2% MEM:10.0% DISK_USED:1%
[2026-09-17 14:57:02] PID:5454 CPU:0.5% MEM:7.9% DISK_USED:1%
```

**용량 관리** — `monitor.sh`의 `rotate_log()`

```
monitor.log 가 10MB 초과 시

  monitor.log.9   삭제
  monitor.log.8 → .9 ,  ... ,  monitor.log.1 → .2
  monitor.log   → monitor.log.1
```

원본 + `.1`~`.9`로 최대 10개를 유지한다.

**설명 포인트**
- 로그는 남기는 것과 지우는 것이 한 쌍이다. 매분 쌓이는 로그를 방치하면 디스크가 가득 차 서버가 정지하며, 이는 현업에서 흔한 장애 원인이다.
- 장애 발생 시 로그의 시계열을 거슬러 올라가면 "언제부터 이상해졌는가"를 특정할 수 있다. 로그가 없으면 원인 분석이 추측에 의존하고 같은 장애가 반복된다.

**증거** — [`docs/logs/07-monitor-cumulative.log`](docs/logs/07-monitor-cumulative.log)

---

### ⑧ crontab 매분 실행 등록 및 자동 실행

**설정**

```bash
printf '* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/monitor-cron.out 2>&1\n' \
  | sudo crontab -u agent-admin -
```

**확인** — 75초간 사람의 개입 없이 방치

```
2026-09-17 14:52:01   31 /var/log/agent-app/monitor.log
      ↓ 75초 경과
2026-09-17 14:53:16   33 /var/log/agent-app/monitor.log
```

```
$ sudo grep CRON /var/log/syslog | grep agent-admin | tail -3
Sep 17 14:51:01 agent CRON[6282]: (agent-admin) CMD (/home/agent-admin/agent-app/bin/monitor.sh >> ...)
Sep 17 14:52:01 agent CRON[6307]: (agent-admin) CMD (...)
Sep 17 14:53:01 agent CRON[6370]: (agent-admin) CMD (...)
```

**설명 포인트**
- 실행 계정은 `agent-admin`이다. `agent-core` 소속이므로 `agent-dev` 소유의 `monitor.sh`(`750`)를 그룹 권한 `r-x`로 실행할 수 있다. 수정 권한은 없다.
- 사람이 매분 서버를 들여다볼 수 없으므로 점검 자체를 자동화해야 한다.

**증거** — [`docs/logs/08-cron.log`](docs/logs/08-cron.log)

---

## 4. 필수 증거 자료 체크리스트

| # | 항목 | 로그 | 스크린샷 |
|---|---|---|---|
| ① | SSH 포트 변경(20022) 및 Root 원격 접속 차단 | [01-ssh.log](docs/logs/01-ssh.log) | [ssh-login.png](docs/screenshots/ssh-login.png) |
| ② | 방화벽 활성화 및 20022/tcp, 15034/tcp만 허용 | [02-firewall.log](docs/logs/02-firewall.log) | [ufw-status.png](docs/screenshots/ufw-status.png) |
| ③ | 계정/그룹 생성 | [03-users-groups.log](docs/logs/03-users-groups.log) | — |
| ④ | 디렉토리 구조 및 권한(ACL 포함) | [04-directories-acl.log](docs/logs/04-directories-acl.log) | — |
| ⑤ | Boot Sequence 5단계 [OK] 및 Agent READY | [05-app-boot.log](docs/logs/05-app-boot.log) | [app-ready.png](docs/screenshots/app-ready.png) |
| ⑥ | monitor.sh 실행 결과 | [06-monitor-run.log](docs/logs/06-monitor-run.log) | [monitor-run.png](docs/screenshots/monitor-run.png) |
| ⑦ | monitor.log 누적 기록 | [07-monitor-cumulative.log](docs/logs/07-monitor-cumulative.log) | — |
| ⑧ | crontab 매분 실행 및 자동 실행 | [08-cron.log](docs/logs/08-cron.log) | — |

보너스 과제(`report.sh`, 시간 기반 압축/아카이브)는 수행하지 않았다.
필수 항목인 로그 용량 관리(10MB / 10개)는 `monitor.sh`에 구현되어 있다.

---

## 5. 저장소 구조

```
B4-1/
├── README.md
├── app/
│   ├── agent-app-linux-arm64
│   └── agent-app-linux-x86
├── scripts/
│   ├── monitor.sh      # 관제 자동화 스크립트 (제출물)
│   ├── setup.sh        # 환경 전체 복원 (STEP 1~8)
│   └── evidence.sh     # 증거 로그 생성 헬퍼
└── docs/
    ├── logs/           # 01~09, 체크리스트 번호와 1:1
    └── screenshots/
```

---

## 6. 환경 재현

[`scripts/setup.sh`](scripts/setup.sh) 하나로 계정 생성부터 SSH·방화벽·cron까지 복원된다.
멱등하게 작성되어 여러 번 실행해도 안전하고, `uname -m`으로 아키텍처를 감지하므로
x86 환경에서도 동일하게 동작한다.

```bash
orb create ubuntu:22.04 agent
orb -m agent
sudo ./scripts/setup.sh
sudo -iu agent-admin bash -lc 'nohup "$AGENT_HOME/agent_app" >> "$AGENT_LOG_DIR/agent-app.out" 2>&1 &'
sudo -u agent-admin /home/agent-admin/agent-app/bin/monitor.sh
```

서버를 수작업이 아니라 코드로 구성해 두면 다른 장비에서도 동일 환경을 수 분 안에
재현할 수 있고, 무엇을 설정했는지가 실행 가능한 형태로 남는다.

---

## 7. 과제 목표 점검

과제가 제시한 "이 과제를 마친 후 스스로 설명할 수 있어야 하는 것" 6가지에 대한 정리.

### 7-1. SSH 포트 변경과 Root 원격 접속 차단이 왜 기본 보안인가

포트 22와 계정명 `root`는 모든 리눅스에 공통으로 존재한다. 그래서 자동화된 공격 도구는
아무 서버나 22번 포트로 접속을 시도하고 `root` 계정의 비밀번호만 반복해서 대입한다.

포트를 20022로 옮기면 이 무차별 스캔 대부분이 대상을 찾지 못한다. Root 로그인을 막으면
공격자는 비밀번호 이전에 **유효한 계정명부터 알아내야** 하므로 공격 난이도가 한 단계 올라간다.

둘 다 근본적인 방어 수단은 아니다. 포트 스캔으로 20022를 찾아낼 수 있고 계정명도 유출될 수
있다. 그러나 무의미한 공격 시도와 로그 소음을 줄여 **실제 위협을 식별하기 쉽게** 만든다는
점에서 기본 보안에 해당한다.

### 7-2. "필요 포트만 허용"하는 방화벽 정책을 구성하고 검증하는 법

**구성** — 기본 정책을 `deny incoming`으로 두고 필요한 포트만 명시적으로 여는
화이트리스트 방식이다. 차단해야 할 대상은 무한하지만 열어야 할 대상은 유한하므로,
"위험한 것을 막는" 블랙리스트보다 안전하다. 최소 권한 원칙의 네트워크 적용이다.

```bash
sudo ufw default deny incoming     # 기본은 전부 차단
sudo ufw allow 20022/tcp           # 필요한 것만 연다
sudo ufw allow 15034/tcp
sudo ufw enable                    # 포트 허용 후에 활성화
```

**검증** — `ufw status`로 규칙을 확인하는 것만으로는 부족하다. 규칙이 등록돼 있어도 실제로
동작하지 않을 수 있으므로 **외부 호스트에서 접속을 시도**해야 한다.

| 응답 | 의미 |
|---|---|
| `Connection refused` | 방화벽이 없고 포트만 닫혀 있음 (커널이 RST 반환) |
| `Operation timed out` | 방화벽이 패킷을 응답 없이 DROP 중 |

`timed out`이어야 방화벽이 동작하는 것이며, 이 방식은 공격자에게 호스트·포트의 존재
여부조차 알려주지 않는다.

### 7-3. 역할 기반 계정/그룹과 ACL로 공유/보안 디렉토리를 분리하는 이유

**역할 기반으로 나누는 이유** — 권한은 직무 수행에 필요한 최소 범위로만 부여해야 한다.
QA 담당자가 API 키나 운영 로그를 볼 이유가 없다. 이렇게 나눠두면 계정 하나가 탈취되거나
실수가 발생해도 **피해 범위가 그 역할의 권한 안으로 제한**된다.

**그룹이 필요한 이유** — 권한을 "소유자 / 나머지 전부" 두 단계로만 나누면, 일부에게만
열어주는 통제가 불가능하다. `api_keys`를 `agent-dev`에게 열어주려면 "나머지 전부"에게
열어야 하고, 그러면 `agent-test`도 보게 된다. 중간 단계인 그룹이 있어야 이 구분이 가능하다.

**ACL이 추가로 필요한 이유** — 일반 권한은 그룹을 **하나만** 지정할 수 있다. 본 과제에서
`AGENT_HOME`의 상위인 `/home/agent-admin`은 그룹이 `agent-admin`(개인 그룹)이라
`agent-dev`/`agent-test`에게 통행권(`x`)을 줄 자리가 없었다. 디렉토리의 `x`는 "통과"를
뜻하므로, 이것이 없으면 하위 디렉토리 권한을 아무리 잘 설정해도 진입 자체가 불가능하다.
ACL은 "기존 권한은 두고 이 그룹에게만 추가 규칙을 건다"는 표현을 가능하게 해 이 한계를 보완한다.

```bash
sudo setfacl -m g:agent-common:r-x /home/agent-admin
```

### 7-4. 환경 변수로 실행 환경을 고정하는 이유와 검증 방법

**이유** — 경로와 포트를 코드에 직접 박아넣으면 개발 서버와 운영 서버에서 코드가 달라진다.
환경 변수로 빼면 **같은 바이너리가 환경만 바꿔 동작**한다. 설정이 코드 밖으로 나오므로
무엇이 환경에 의존하는지도 명시적으로 드러난다.

**검증 방법** — 값 자체를 확인하는 것으로는 부족하고, **실행 주체와 실행 경로를 바꿔가며**
확인해야 한다.

```bash
sudo -iu agent-admin env | grep AGENT     # 로그인 셸에서
```

로그인 셸에서는 보이지만 cron에서는 보이지 않는 경우가 실제로 발생한다. cron은 로그인 셸이
아니어서 `~/.profile`·`~/.bashrc`를 읽지 않기 때문이다. 이 때문에 환경 변수를 셸 프로필이
아닌 `agent.env` 파일 한 곳에 정의하고, 로그인 셸과 `monitor.sh`가 각각 그 파일을 읽도록
구성했다.

### 7-5. 쉘 스크립트로 상태를 수집하고 로그로 남겨 문제를 추적하는 흐름

```
① 살아 있는가   프로세스 존재 → 포트 LISTEN      실패 시 exit 1
② 여유가 있는가  CPU / MEM / DISK 수집            임계값 초과 시 WARNING
③ 기록한다      타임스탬프와 함께 로그에 append
④ 반복한다      cron 이 매분 호출
```

**살아 있는가를 먼저 판정하는 이유** — 자원 수치는 서비스가 동작할 때만 의미가 있다.
프로세스가 죽었는데 CPU 사용률을 재는 것은 의미가 없으므로, Health Check가 실패하면
그 자리에서 `exit 1`로 끝낸다.

**프로세스와 포트를 모두 보는 이유** — 프로세스가 살아 있어도 포트를 잡지 못하면
외부에서는 서비스 불가 상태다. 둘 중 하나만으로는 "서비스가 정상인가"에 답할 수 없다.

**실패 등급을 나누는 이유** — 프로세스 중단은 즉시 대응할 사고지만 방화벽 비활성은
서비스가 동작하는 상태의 보안 이슈다. 모든 이상을 긴급으로 처리하면 알림이 과다해져
정작 실제 사고를 놓치게 되므로, 중단시킬 실패와 기록만 할 이상을 구분했다.

**로그가 추적에 쓰이는 방식** — 장애가 발생하면 로그의 시계열을 거슬러 올라가
"언제부터 수치가 이상해졌는가"를 특정할 수 있다. 로그가 없으면 원인 분석이 추측에
의존하게 되고, 원인을 모르므로 같은 장애가 반복된다.

### 7-6. crontab 주기 실행과 로그 보존 정책이 필요한 이유

**주기 실행이 필요한 이유** — 사람이 매분 서버 상태를 확인할 수는 없다. 점검 자체를
자동화해야 하며, 자동화하면 사람이 보지 않는 새벽 시간의 상태도 기록으로 남는다.

```
* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> ... 2>&1
│ │ │ │ │
│ │ │ │ └ 요일    ┐
│ │ │ └── 월      │ 모두 * = 매분 실행
│ │ └──── 일      │
│ └────── 시      │
└──────── 분      ┘
```

**로그 보존 정책이 필요한 이유** — 매분 한 줄씩 쌓이는 로그를 방치하면 시간이 지나
디스크가 가득 차고, 그 순간 서버 전체가 정지한다. 로그를 남기려고 넣은 장치가 오히려
장애 원인이 되는 것이다. 현업에서 흔한 장애 유형이다.

따라서 **로그는 남기는 것과 지우는 것이 한 쌍**이다. 본 과제에서는 `monitor.sh`의
`rotate_log()`가 매 실행마다 크기를 확인해 10MB를 넘으면 회전시키고, 원본 + `.1`~`.9`로
최대 10개만 유지한다. 오래된 것부터 자동으로 삭제되므로 로그 총량에 상한이 생긴다.
