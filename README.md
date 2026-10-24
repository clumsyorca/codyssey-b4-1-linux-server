# B4-1 — 컴퓨터가 알아서 자기 상태를 점검하게 만들기

리눅스 서버의 기본 보안(SSH·방화벽), 역할 기반 계정/권한 체계, 애플리케이션 실행 환경을
구성하고, 시스템 상태를 주기적으로 수집·기록하는 관제 자동화를 구현했다.

---

## 1. 최종 산출물

| 산출물 | 파일 |
|---|---|
| 요구사항 수행 내역서 | 본 문서 — [4. 수행 내역](#work)으로 이동 |
| 자동화 스크립트 | [`scripts/monitor.sh`](scripts/monitor.sh) |

```
B4-1/
├── README.md                    수행 내역서
├── app/
│   ├── agent-app-linux-arm64    제공 애플리케이션 (Apple Silicon)
│   └── agent-app-linux-x86      제공 애플리케이션 (Intel)
├── scripts/
│   ├── monitor.sh               ★ 관제 자동화 스크립트
│   ├── setup.sh                 환경 전체 복원 스크립트
│   └── evidence.sh              증거 로그 생성 헬퍼
└── docs/
    ├── logs/                    증거 로그 01~08 (체크리스트 번호와 일치)
    └── screenshots/             증거 스크린샷 (확인 지점에 주석 표시)
```

---

## 2. 필수 증거 자료 체크리스트

각 항목의 "수행 내역" 링크를 누르면 해당 작업을 설명한 절로 이동한다.

| # | 항목 | 수행 내역 | 로그 | 스크린샷 |
|---|---|---|---|---|
| ① | SSH 포트 변경(20022) 및 Root 원격 접속 차단 | [4.1.1](#ssh) | [01-ssh.log](docs/logs/01-ssh.log) | [01](docs/screenshots/01-ssh-root-block.png) · [02](docs/screenshots/02-ssh-login.png) |
| ② | 방화벽 활성화 및 20022/tcp, 15034/tcp만 허용 | [4.1.2](#firewall) | [02-firewall.log](docs/logs/02-firewall.log) | [03](docs/screenshots/03-ufw-status.png) |
| ③ | 계정/그룹 생성 확인 | [4.2.1](#users) | [03-users-groups.log](docs/logs/03-users-groups.log) | [04](docs/screenshots/04-users-groups.png) |
| ④ | 디렉토리 구조 및 권한(ACL 포함) 확인 | [4.2.2](#dirs) · [4.2.3](#acl) | [04-directories-acl.log](docs/logs/04-directories-acl.log) | [05](docs/screenshots/05-dirs-acl.png) |
| ⑤ | 앱 Boot Sequence 5단계 [OK] 및 "Agent READY" | [4.3](#app) | [05-app-boot.log](docs/logs/05-app-boot.log) | [06](docs/screenshots/06-app-ready.png) |
| ⑥ | monitor.sh 실행 결과(프로세스/포트/리소스/경고) | [4.4](#monitor) | [06-monitor-run.log](docs/logs/06-monitor-run.log) | [07](docs/screenshots/07-monitor-ok.png) · [08](docs/screenshots/08-monitor-exit1.png) |
| ⑦ | monitor.log 누적 기록 확인 | [4.4.4](#logging) | [07-monitor-cumulative.log](docs/logs/07-monitor-cumulative.log) | [10](docs/screenshots/10-log-rotate.png) |
| ⑧ | crontab 매분 실행 등록 및 자동 실행 확인 | [4.5](#cron) | [08-cron.log](docs/logs/08-cron.log) | [09](docs/screenshots/09-cron.png) |

---

## 3. 실습 환경

| 항목 | 값 |
|---|---|
| OS | Ubuntu 22.04.5 LTS |
| 아키텍처 | aarch64 (arm64) |
| 자원 | 11 vCPU / 8,999 MB RAM |
| 가상화 | OrbStack Linux Machine (`agent`) |
| VM IP | 192.168.139.141 |

최종 구성은 다음과 같다.

```
                      외부 (호스트 macOS)
                            │
                  20022 ────┼──── 15034        ← 이 두 포트만 통과
                            │
        ┌───────────────────▼────────────────────┐
        │  UFW   기본 정책: 들어오는 접속 전부 차단  │
        ├────────────────────────────────────────┤
        │  sshd      :20022   (root 로그인 차단)   │
        │  agent_app :15034                      │
        │       ▲                                │
        │       │ 감시                            │
        │  monitor.sh ──▶ /var/log/agent-app/monitor.log
        │       ▲                                │
        │       │ 매분 호출                       │
        │  crontab (agent-admin)                 │
        └────────────────────────────────────────┘
```

확인 명령은 모두 VM 안에서 실행하며, 애플리케이션이 구동 중인 상태를 전제로 한다.

```bash
pgrep -x agent_app
```

PID 두 개(부모·자식)가 출력되면 구동 중이다. 없다면 아래로 기동한다.

```bash
sudo -iu agent-admin bash -lc 'nohup "$AGENT_HOME/agent_app" >> "$AGENT_LOG_DIR/agent-app.out" 2>&1 &'
```

---

<a id="work"></a>

## 4. 수행 내역

과제의 기능 요구사항 순서대로 정리했다.

```
4.1  기본 보안 및 네트워크 설정      SSH · 방화벽
4.2  계정 / 그룹 / 권한 체계         계정 · 디렉토리 · ACL
4.3  애플리케이션 실행 환경 구성      환경 변수 · 키 파일 · 기동
4.4  시스템 관제 자동화 스크립트      monitor.sh
4.5  자동 실행 설정                  crontab
```

---

### 4.1 기본 보안 및 네트워크 설정

외부에서 서버로 들어오는 길을 두 겹으로 막았다.

```
외부 접속 ──▶ ① 방화벽 : 이 포트로 들어올 수 있나?
                   ↓
             ② SSH    : 이 계정으로 로그인할 수 있나?
```

<a id="ssh"></a>

#### 4.1.1 SSH 포트 변경(20022) 및 Root 원격 접속 차단

포트 22번과 계정 `root`는 모든 리눅스에 똑같이 있다. 그래서 공격 도구가 아무 서버나
22번으로 접속해 `root` 비밀번호만 반복해서 찍어본다. 둘 다 바꿨다.

**설정**

```bash
sudo apt install -y openssh-server
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

sudo sed -i 's/^#\?Port .*/Port 20022/'                   /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config

sudo sshd -t                 # 문법 검사
sudo systemctl restart ssh   # 설정 반영
```

`sshd -t`를 먼저 돌린 이유는, 설정이 틀린 채로 재시작하면 sshd가 아예 안 켜지기 때문이다.
원격 서버였다면 그 순간 들어갈 길이 사라진다.

**확인**

```bash
sudo sshd -T | grep -iE '^(port|permitrootlogin)'
sudo ss -tulnp | grep sshd
ssh -p 20022 root@localhost
```

```
port 20022
permitrootlogin no
tcp LISTEN 0.0.0.0:20022 ... sshd
root@localhost: Permission denied (publickey,password).
```

`sshd -T`는 파일 내용이 아니라 **지금 실제로 적용된 값**을 보여준다.

| 시험 | 결과 |
|---|---|
| `agent-admin` 으로 20022 접속 | 성공 |
| `root` 로 20022 접속 | `Permission denied` |
| 구 포트 22 접속 | `Connection refused` |

막은 것은 root의 **원격 로그인**이지 계정 자체가 아니다. 일반 계정으로 들어와서 `sudo`를
쓰는 길은 열려 있고, 이렇게 한 단계를 거치면 누가 무슨 관리자 명령을 썼는지 기록에 남는다.

<a id="firewall"></a>

#### 4.1.2 방화벽(UFW) 활성화 및 20022/tcp, 15034/tcp만 허용

포트가 열려 있다는 것과 외부에서 거기 닿을 수 있다는 것은 다른 문제다. 방화벽은 그 앞에서
**어떤 포트로만 들어올 수 있는지**를 정한다. 과제가 UFW와 firewalld 중 택일하라 했고,
Ubuntu 기본 도구인 UFW를 골랐다.

**설정**

```bash
sudo apt install -y ufw

sudo ufw default deny incoming     # 들어오는 건 전부 차단
sudo ufw default allow outgoing    # 나가는 건 허용

sudo ufw allow 20022/tcp comment 'SSH'
sudo ufw allow 15034/tcp comment 'agent-app'

sudo ufw enable
```

막을 포트는 65535개라 끝이 없지만 열 포트는 두 개뿐이다. 그래서 **전부 막고 필요한 것만
여는** 방식을 썼다. 나중에 다른 프로그램이 포트를 열어도 자동으로 막힌다.

> 포트를 먼저 열고 방화벽을 켜는 **순서가 중요하다.** 반대로 하면 켜는 순간 SSH가 끊긴다.

**확인**

```bash
sudo ufw status verbose
```

```
Status: active
Default: deny (incoming), allow (outgoing)

To                 Action      From
20022/tcp          ALLOW IN    Anywhere        # SSH
15034/tcp          ALLOW IN    Anywhere        # agent-app
20022/tcp (v6)     ALLOW IN    Anywhere (v6)   # SSH
15034/tcp (v6)     ALLOW IN    Anywhere (v6)   # agent-app
```

네 줄인 것은 IPv4와 IPv6에 규칙이 각각 생기기 때문이고, 포트는 두 개가 맞다.

규칙이 등록됐다고 실제로 막히는 건 아니므로, 호스트(macOS)에서 직접 접속해 봤다.

| 포트 | 결과 | 판정 |
|---|---|---|
| 20022 | `succeeded` | 허용 |
| 15034 | `succeeded` | 허용 |
| 22 | `Operation timed out` | 차단 |
| 8080 | `Operation timed out` | 차단 |

응답 종류가 다르다는 점이 핵심이다. 방화벽 없이 포트만 닫혀 있으면 즉시
`Connection refused`가 온다. `timed out`은 방화벽이 **대꾸 없이 패킷을 버리고 있다**는 뜻이라,
공격자는 서버가 있는지조차 알 수 없다.

---

### 4.2 계정 / 그룹 / 권한 체계

<a id="users"></a>

#### 4.2.1 계정과 그룹

역할별로 계정을 나누고, 역할이 겹치는 범위를 그룹으로 묶었다.

```bash
sudo groupadd agent-common
sudo groupadd agent-core

sudo useradd -m -s /bin/bash -G agent-common,agent-core agent-admin
sudo useradd -m -s /bin/bash -G agent-common,agent-core agent-dev
sudo useradd -m -s /bin/bash -G agent-common            agent-test
```

| 계정 | 소속 그룹 | 역할 |
|---|---|---|
| `agent-admin` | agent-common, agent-core | 운영·관리, cron 실행 |
| `agent-dev` | agent-common, agent-core | 개발, monitor.sh 작성 |
| `agent-test` | agent-common | QA·테스트 |

`agent-test`만 `agent-core`에서 뺐다. QA가 API 키를 볼 일이 없기 때문이다.
권한을 필요한 만큼만 주면 계정이 털려도 피해가 그 역할 안에서 멈춘다.

그룹이 있어야 하는 이유는, 권한을 "주인 / 나머지 전부"로만 나누면 **일부에게만 열어주는 것이
불가능**하기 때문이다. `agent-dev`에게 열어주려면 "나머지 전부"를 열어야 하고, 그러면
`agent-test`도 따라 들어온다.

**확인**

```bash
getent group agent-common agent-core
id agent-admin ; id agent-dev ; id agent-test
```

```
agent-common:x:1000:agent-admin,agent-dev,agent-test
agent-core:x:1001:agent-admin,agent-dev
```

`getent group`은 "그룹 → 사람", `id`는 "사람 → 그룹"이다. 두 방향을 맞춰봤다.

<a id="dirs"></a>

#### 4.2.2 디렉토리 구조와 권한

```bash
sudo mkdir -p /home/agent-admin/agent-app/{upload_files,api_keys,bin} /var/log/agent-app

sudo chown agent-admin:agent-common $AGENT_HOME $AGENT_HOME/upload_files
sudo chown agent-admin:agent-core   $AGENT_HOME/api_keys /var/log/agent-app
sudo chown agent-dev:agent-core     $AGENT_HOME/bin

sudo chmod 750  $AGENT_HOME
sudo chmod 2770 $AGENT_HOME/upload_files $AGENT_HOME/api_keys /var/log/agent-app
sudo chmod 2750 $AGENT_HOME/bin
```

| 경로 | 소유자 | 그룹 | 권한 | 성격 |
|---|---|---|---|---|
| `$AGENT_HOME` | agent-admin | agent-common | `750` | 진입점 |
| `upload_files` | agent-admin | agent-common | `2770` | **공유** |
| `api_keys` | agent-admin | agent-core | `2770` | **보안** |
| `bin` | **agent-dev** | agent-core | `2750` | 스크립트 |
| `/var/log/agent-app` | agent-admin | agent-core | `2770` | **보안** |

`chown`은 "누구 것인지", `chmod`는 "그 사람이 뭘 할 수 있는지"를 정한다. 둘은 한 쌍이다.
숫자는 읽기 4 + 쓰기 2 + 실행 1을 더한 값이고, 세 자리는 순서대로 소유자·그룹·나머지다.
디렉토리에서 `x`는 실행이 아니라 **통과**를 뜻한다.

앞에 붙은 `2`는 **setgid**다. 이 폴더에 새로 생기는 파일이 만든 사람의 개인 그룹이 아니라
**폴더의 그룹을 물려받게** 한다. 없으면 `agent-dev`가 공유 폴더에 만든 파일을
`agent-test`가 못 읽는다.

`bin`만 `2750`인 것은 일부러다. `agent-dev`는 고칠 수 있지만 `agent-admin`은 `r-x`라
**실행만** 된다. cron이 돌리는 데는 그걸로 충분하고, 운영 중에 스크립트가 바뀌는 길은 막힌다.

<a id="acl"></a>

#### 4.2.3 ACL

```bash
sudo setfacl -m  g:agent-common:r-x /home/agent-admin
sudo setfacl -m  g:agent-common:rwx $AGENT_HOME/upload_files
sudo setfacl -dm g:agent-common:rwx $AGENT_HOME/upload_files
sudo setfacl -m  g:agent-core:rwx   $AGENT_HOME/api_keys /var/log/agent-app
sudo setfacl -dm g:agent-core:rwx   $AGENT_HOME/api_keys /var/log/agent-app
```

ACL이 꼭 필요했던 곳은 **상위 폴더**다. `/home/agent-admin`은 그룹이 개인 그룹
`agent-admin`이라 `agent-dev`와 `agent-test`가 지나갈 수 없었다. 디렉토리에서 `x`가 없으면
안쪽 권한을 아무리 잘 줘도 **들어가지를 못한다.** 그런데 일반 권한은 그룹을 하나만 지정할 수
있어서 여기에 `agent-common`을 끼워넣을 자리가 없다. ACL은 "원래 권한은 두고 이 그룹에게만
규칙을 더한다"가 되어 이 한계를 메운다.

`-d`(default)는 **권한 상속**이다. setgid가 그룹은 물려주지만 권한은 안 물려줘서,
이게 없으면 새 파일이 `rw-r--r--`가 되어 그룹이 쓰지를 못한다. 둘 다 있어야 공유가 완성된다.

**확인**

```bash
sudo ls -l /home/agent-admin/agent-app
sudo ls -ld /var/log/agent-app
sudo -u agent-test ls /home/agent-admin/agent-app/api_keys
```

```
drwxrws---+ agent-admin agent-core    api_keys
drwxr-s---  agent-dev   agent-core    bin
drwxrws---+ agent-admin agent-common  upload_files
drwxrws---+ agent-admin agent-core    /var/log/agent-app

ls: cannot open directory '.../api_keys': Permission denied
```

끝의 `+`는 ACL이 걸렸다는 표시, 그룹 자리의 `s`는 setgid가 켜졌다는 표시다.
마지막 줄의 `Permission denied`가 **차단이 실제로 동작한다는 증거**다. 보안 설정은
되는 것보다 **안 되는 것**을 보여줘야 한다.

---

<a id="app"></a>

### 4.3 애플리케이션 실행 환경 구성

**설정**

```bash
# 아키텍처 자동 감지 후 배치 (파일명은 agent_app 으로 통일)
case "$(uname -m)" in
  x86_64)        APP=agent-app-linux-x86   ;;
  aarch64|arm64) APP=agent-app-linux-arm64 ;;
esac
sudo install -o agent-admin -g agent-core -m 750 "app/$APP" "$AGENT_HOME/agent_app"

# 키 파일
echo 'agent_api_key_test' | sudo -u agent-admin tee $AGENT_HOME/api_keys/secret.key
sudo chmod 640 $AGENT_HOME/api_keys/secret.key
```

제공 바이너리가 x86/arm64로 나뉘어 있어 자동 감지하되 **파일명을 통일**했다. 안 그러면
`monitor.sh`가 찾을 프로세스 이름이 환경마다 달라진다.

환경 변수는 `$AGENT_HOME/agent.env` 파일 하나에 모았다.

```bash
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
export AGENT_KEY_PATH=$AGENT_HOME/api_keys
export AGENT_LOG_DIR=/var/log/agent-app
```

경로를 코드에 박아넣으면 환경이 바뀔 때마다 코드를 고쳐야 한다. 변수로 빼면 **같은 파일이
환경만 바꿔 돈다.** 셸 설정이 아니라 별도 파일로 둔 것은 cron 때문이다. cron은 로그인 셸이
아니라서 `~/.profile`을 안 읽어, 셸에만 넣으면 **손으로는 되고 cron만 실패**한다.

```bash
sudo -iu agent-admin bash -lc 'nohup "$AGENT_HOME/agent_app" >> "$AGENT_LOG_DIR/agent-app.out" 2>&1 &'
```

루트로 돌리지 않은 이유는, 앱이 뚫리면 공격자가 그 앱의 권한을 그대로 갖기 때문이다.
`nohup ... &`는 터미널을 닫아도 계속 돌게 한다.

**확인**

```bash
sudo head -20 /var/log/agent-app/agent-app.out
```

```
[1/5] Checking User Account               [OK]
[2/5] Verifying Environment Variables     [OK]
[3/5] Checking Required Files             [OK]
[4/5] Checking Port Availability          [OK]
[5/5] Verifying Log Permission            [OK]
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
```

앱이 기동하면서 계정·환경변수·키파일·포트·로그권한 다섯 가지를 스스로 검사한다.
즉 **앞 단계 설정이 다 맞았는지 이 앱이 대신 확인해 준다.**

---

<a id="monitor"></a>

### 4.4 시스템 관제 자동화 스크립트 — monitor.sh

소스: [`scripts/monitor.sh`](scripts/monitor.sh)

경로 `$AGENT_HOME/bin/monitor.sh`, 소유자 `agent-dev`, 그룹 `agent-core`, 권한 `750`.
`agent-admin`은 `agent-core` 소속이라 **실행만** 되고 수정은 안 된다.

```
① 살아 있나?   프로세스 · 포트          아니면 exit 1
② 방화벽은?    켜져 있는지 확인만        꺼져 있으면 경고만
③ 얼마나 쓰나?  CPU · MEM · DISK
④ 너무 높나?   20% / 10% / 80%         넘어도 계속 진행
⑤ 기록         monitor.log 에 한 줄      10MB 넘으면 회전
```

#### 4.4.1 실패 등급을 나눈 것이 핵심

| 점검 | 이상일 때 | 왜 |
|---|---|---|
| 프로세스 없음 | **exit 1** | 서비스 중단 — 지금 사용자가 못 쓴다 |
| 포트 안 열림 | **exit 1** | 떠 있어도 서비스는 불가 |
| 방화벽 꺼짐 | 경고만 | 문제지만 서비스는 돈다 |
| 임계값 초과 | 경고만 | 지켜볼 대상이지 사고는 아니다 |

기준은 **"지금 서비스가 멈췄는가"** 다. 전부 긴급으로 처리하면 알림이 넘쳐서 사람들이
알림을 무시하게 되고, 결국 진짜 사고를 놓친다. cron 같은 도구는 종료 코드로 성패를
판단하므로 경고에까지 `exit 1`을 내면 전부 장애로 잡힌다.

프로세스와 포트를 **둘 다** 보는 이유는, 프로세스가 살아 있어도 포트를 못 잡으면
밖에서는 서비스가 안 되기 때문이다.

```bash
PID=$(pgrep -x "$PROC_NAME" | head -1)
ss -ltn | awk '{print $4}' | grep -q ":${AGENT_PORT}$"
```

`pgrep -x`는 프로세스 **이름이 정확히 같은 것만** 찾는다. `-f`는 명령줄 전체를 보기 때문에
스크립트 자신까지 걸려든다. `ss`는 `netstat`의 후속 표준이고, `-l` 대기중만 `-t` TCP만
`-n` 이름변환 생략이다. `-p`는 root가 필요해서 뺐다.

#### 4.4.2 방화벽 점검

```bash
grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf
```

`ufw status`는 root가 필요한데 `monitor.sh`는 일반 계정으로 돌아야 해서, 일반 계정도
읽을 수 있는 설정 파일을 봤다. 감시 도구가 방화벽을 켜지는 않는다. 운영자가 점검하려고
잠깐 꺼둔 걸 멋대로 되살리면 그게 사고다.

#### 4.4.3 자원 수집과 임계값

| 지표 | 방식 | 왜 |
|---|---|---|
| CPU | `/proc/stat`을 1초 간격 두 번 읽어 차이 계산 | 이 값은 부팅 이후 누적이라, 한 번만 읽으면 **지금 부하가 아니라 평균**이 나온다 |
| MEM | `/proc/meminfo`의 `MemAvailable` | `MemFree`는 캐시를 쓰는 중으로 세서 실제보다 높게 나온다 |
| DISK | `df -P /`의 Used % | 루트 파티션 기준 |

헬스체크는 "죽었나 살았나"라 이미 죽은 뒤에 알려주지만, 자원 수치는 "얼마나 위험한가"라
**멈추기 전에** 알려준다.

CPU 계산이 맞는지는 부하를 걸어 대조했다. 11코어 환경에서 1코어를 100% 점유했을 때
9.2%(이론값 9.1%), 4코어일 때 37.5%(이론값 36.4%)가 나왔다.

임계값이 낮은 이유는 제공 앱이 메모리를 0 → 256MB → 0으로 반복하며 일부러 부하를
만들기 때문이다. MEM은 `10.2%`로 자연히 경고가 떴고, CPU는 코어가 11개라 앱이 1코어를
다 써도 전체로는 9%대여서 인위 부하로 로직을 확인했다.

<a id="logging"></a>

#### 4.4.4 로그 기록과 용량 관리

```
[2026-09-17 14:56:02] PID:5454 CPU:0.2% MEM:10.0% DISK_USED:1%
[2026-09-17 14:57:02] PID:5454 CPU:0.5% MEM:7.9%  DISK_USED:1%
```

사람이 읽으면서 프로그램도 뽑아 쓸 수 있게 순서를 고정했다. 시각을 `YYYY-MM-DD HH:MM:SS`로
둔 건 **글자 순서 = 시간 순서**가 되기 때문이다.

기록은 `>>`로 한다. `>`를 쓰면 **매번 파일을 비우고 새로 써서** 한 줄만 남는다.
로그의 가치는 시계열에 있고, 한 시점 값만으로는 원래 그런 건지 지금 이상한 건지 알 수 없다.

10MB를 넘으면 `rotate_log()`가 이렇게 돌린다.

```
monitor.log.9  → 삭제
monitor.log.8  → .9      ...      monitor.log.1 → .2
monitor.log    → .1
```

원본 + `.1`~`.9`로 **최대 10개**만 남아 총량에 상한이 생긴다. 로그는 남기는 것과 지우는 것이
한 쌍이다. 놔두면 디스크가 꽉 차서 서버가 멈춘다.

`logrotate`라는 도구도 있지만 보통 하루 한 번 돌아 급증에 늦고, 설정이 `/etc`에 있어
root가 필요하다. `monitor.sh`는 일반 계정으로 돌아야 해서 스크립트 안에 직접 넣었다.

#### 4.4.5 실행 확인

```bash
sudo ls -l /home/agent-admin/agent-app/bin/monitor.sh
sudo -u agent-admin /home/agent-admin/agent-app/bin/monitor.sh ; echo "exit=$?"
```

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

비정상일 때는 앱을 멈춰서 확인한다. 확인 후에는 다시 기동한다.

```bash
sudo pkill -x agent_app
sudo -u agent-admin /home/agent-admin/agent-app/bin/monitor.sh ; echo "exit=$?"
```

| 상황 | 출력 | exit |
|---|---|---|
| 정상 | 전 항목 `[OK]` | 0 |
| 앱 중단 | `[CRITICAL] Process 'agent_app' is not running.` | **1** |
| 방화벽 꺼짐 | `[WARNING] Firewall (ufw) is INACTIVE.` 후 로그까지 기록 | 0 |
| CPU 초과 | `[WARNING] CPU threshold exceeded (36.6% > 20%)` | 0 |
| MEM 초과 | `[WARNING] MEM threshold exceeded (10.2% > 10%)` | 0 |

---

<a id="cron"></a>

### 4.5 자동 실행(cron) 설정

```bash
printf '* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/monitor-cron.out 2>&1\n' \
  | sudo crontab -u agent-admin -
```

별 다섯 개는 순서대로 **분·시·일·월·요일**이고, 전부 `*`이면 조건 없이 매분 실행이다.
실행 계정을 `agent-admin`으로 둔 것은 `agent-core` 소속이라 `agent-dev` 소유의 스크립트를
실행할 수 있고 고치지는 못하기 때문이다.

출력을 파일로 보낸 것은 cron이 결과를 메일로 보내려 하기 때문이고, `2>&1`로 에러까지 같이
남겨야 문제가 생겼을 때 원인을 본다.

사람이 매분 서버를 들여다볼 수는 없다. 점검 자체를 자동으로 돌려야 하고, 그래야 아무도
안 보는 새벽 상태도 기록에 남는다.

**확인**

```bash
sudo crontab -u agent-admin -l
sudo grep CRON /var/log/syslog | grep agent-admin | tail -3
sudo wc -l /var/log/agent-app/monitor.log
```

```
Sep 17 14:51:01 agent CRON[6282]: (agent-admin) CMD (.../monitor.sh >> ...)
Sep 17 14:52:01 agent CRON[6307]: (agent-admin) CMD (...)
Sep 17 14:53:01 agent CRON[6370]: (agent-admin) CMD (...)
```

마지막 명령을 1분 간격으로 두 번 치면 줄 수가 늘어난다. 실제로 손대지 않고 75초를 두었더니
31줄에서 33줄이 됐다.

`monitor.log`만 보면 손으로 돌린 것과 구분이 안 되므로, **cron이 불렀다는 증거**인
syslog 기록을 같이 본다.

---

## 5. 환경 재현

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

## 6. 과제 목표 점검

### 6-1. SSH 포트 변경과 Root 원격 접속 차단이 왜 기본 보안인가

포트 22와 계정명 `root`는 모든 리눅스에 공통으로 존재한다. 그래서 자동화된 공격 도구는
아무 서버나 22번 포트로 접속을 시도하고 `root` 계정의 비밀번호만 반복해서 대입한다.

포트를 20022로 옮기면 이 무차별 스캔 대부분이 대상을 찾지 못한다. Root 로그인을 막으면
공격자는 비밀번호 이전에 **유효한 계정명부터 알아내야** 하므로 공격 난이도가 한 단계 올라간다.

둘 다 근본적인 방어 수단은 아니다. 포트 스캔으로 20022를 찾아낼 수 있고 계정명도 유출될 수
있다. 그러나 무의미한 공격 시도와 로그 소음을 줄여 **실제 위협을 식별하기 쉽게** 만든다는
점에서 기본 보안에 해당한다.

### 6-2. "필요 포트만 허용"하는 방화벽 정책을 구성하고 검증하는 법

기본 정책을 `deny incoming`으로 두고 필요한 포트만 명시적으로 여는 화이트리스트 방식이다.
차단해야 할 대상은 무한하지만 열어야 할 대상은 유한하므로, "위험한 것을 막는" 블랙리스트보다
안전하다. 포트를 먼저 허용하고 방화벽을 켜는 순서를 지켜야 접속이 끊기지 않는다.

검증은 `ufw status`로 규칙을 확인하는 것만으로는 부족하다. 규칙이 등록돼 있어도 실제로
동작하지 않을 수 있으므로 **외부 호스트에서 접속을 시도**해야 한다.
`Connection refused`는 방화벽 없이 포트만 닫혀 있는 상태이고, `Operation timed out`은
방화벽이 패킷을 응답 없이 버리는 상태다. 후자여야 방화벽이 동작하는 것이며,
이 방식은 공격자에게 포트나 호스트의 존재조차 알려주지 않는다.

### 6-3. 역할 기반 계정/그룹과 ACL로 공유/보안 디렉토리를 분리하는 이유

권한은 직무 수행에 필요한 최소 범위로만 부여해야 사고의 피해 범위가 제한된다. QA 담당자가
API 키를 볼 이유가 없다. 다만 권한을 "소유자 / 나머지 전부"로만 나누면 일부에게만 열어주는
통제가 불가능하므로 그룹이라는 중간 단계가 필요하다.

일반 권한은 그룹을 **하나만** 지정할 수 있다는 한계가 있다. 본 과제에서 `/home/agent-admin`은
그룹이 개인 그룹 `agent-admin`이라 다른 계정에게 통행권(`x`)을 줄 자리가 없었고, ACL로만
해결할 수 있었다. 디렉토리의 `x`는 "통과"를 뜻하므로, 이것이 없으면 하위 디렉토리 권한을
아무리 잘 설정해도 진입 자체가 불가능하다.

### 6-4. 환경 변수로 실행 환경을 고정하는 이유와 검증 방법

경로와 포트를 코드에 직접 박아넣으면 개발 서버와 운영 서버에서 코드가 달라진다.
환경 변수로 빼면 **같은 바이너리가 환경만 바꿔 동작**한다.

검증은 값 자체를 확인하는 것으로 부족하고, **실행 주체와 실행 경로를 바꿔가며** 확인해야 한다.
로그인 셸에서는 보이지만 cron에서는 보이지 않는 경우가 실제로 발생한다. cron은 로그인 셸이
아니어서 `~/.profile`을 읽지 않기 때문이다. 이 때문에 환경 변수를 셸 프로필이 아닌
`agent.env` 파일 한 곳에 정의하고, 로그인 셸과 `monitor.sh`가 각각 그 파일을 읽도록 했다.

### 6-5. 쉘 스크립트로 상태를 수집하고 로그로 남겨 문제를 추적하는 흐름

```
① 살아 있는가   프로세스 존재 → 포트 LISTEN      실패 시 exit 1
② 여유가 있는가  CPU / MEM / DISK 수집            임계값 초과 시 WARNING
③ 기록한다      타임스탬프와 함께 로그에 append
④ 반복한다      cron 이 매분 호출
```

자원 수치는 서비스가 동작할 때만 의미가 있으므로 "살아 있는가"를 먼저 판정하고, 실패하면
그 자리에서 종료한다. 프로세스가 살아 있어도 포트를 잡지 못하면 외부에서는 서비스 불가이므로
둘을 모두 확인한다.

프로세스 중단은 즉시 대응할 사고지만 방화벽 비활성은 서비스가 동작하는 상태의 보안 이슈다.
모든 이상을 긴급으로 처리하면 알림이 과다해져 정작 실제 사고를 놓치게 되므로 등급을 나눴다.

장애가 발생하면 로그의 시계열을 거슬러 올라가 "언제부터 수치가 이상해졌는가"를 특정할 수 있다.
로그가 없으면 원인 분석이 추측에 의존하게 되고, 원인을 모르므로 같은 장애가 반복된다.

### 6-6. crontab 주기 실행과 로그 보존 정책이 필요한 이유

사람이 매분 서버 상태를 확인할 수는 없다. 점검 자체를 자동화해야 하며, 자동화하면 사람이
보지 않는 새벽 시간의 상태도 기록으로 남는다.

동시에, 매분 한 줄씩 쌓이는 로그를 방치하면 시간이 지나 디스크가 가득 차고 그 순간 서버
전체가 정지한다. 로그를 남기려고 넣은 장치가 오히려 장애 원인이 되는 것이다.

따라서 **로그는 남기는 것과 지우는 것이 한 쌍**이다. 본 과제에서는 `rotate_log()`가 매 실행마다
크기를 확인해 10MB를 넘으면 회전시키고 최대 10개만 유지한다. 오래된 것부터 자동으로
삭제되므로 로그 총량에 상한이 생긴다.
