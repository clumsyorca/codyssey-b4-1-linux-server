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
    ├── logs/                    증거 로그 01~09
    └── screenshots/             증거 스크린샷
```

---

## 2. 필수 증거 자료 체크리스트

각 항목의 "수행 내역" 링크를 누르면 해당 작업을 설명한 절로 이동한다.

| # | 항목 | 수행 내역 | 로그 | 스크린샷 |
|---|---|---|---|---|
| ① | SSH 포트 변경(20022) 및 Root 원격 접속 차단 | [4.1.1](#ssh) | [01-ssh.log](docs/logs/01-ssh.log) | [ssh-login.png](docs/screenshots/ssh-login.png) |
| ② | 방화벽 활성화 및 20022/tcp, 15034/tcp만 허용 | [4.1.2](#firewall) | [02-firewall.log](docs/logs/02-firewall.log) | [ufw-status.png](docs/screenshots/ufw-status.png) |
| ③ | 계정/그룹 생성 확인 | [4.2.1](#users) | [03-users-groups.log](docs/logs/03-users-groups.log) | — |
| ④ | 디렉토리 구조 및 권한(ACL 포함) 확인 | [4.2.2](#dirs) · [4.2.3](#acl) | [04-directories-acl.log](docs/logs/04-directories-acl.log) | — |
| ⑤ | 앱 Boot Sequence 5단계 [OK] 및 "Agent READY" | [4.3](#app) | [05-app-boot.log](docs/logs/05-app-boot.log) | [app-ready.png](docs/screenshots/app-ready.png) |
| ⑥ | monitor.sh 실행 결과(프로세스/포트/리소스/경고) | [4.4](#monitor) | [06-monitor-run.log](docs/logs/06-monitor-run.log) | [monitor-run.png](docs/screenshots/monitor-run.png) |
| ⑦ | monitor.log 누적 기록 확인 | [4.4.4](#logging) | [07-monitor-cumulative.log](docs/logs/07-monitor-cumulative.log) | — |
| ⑧ | crontab 매분 실행 등록 및 자동 실행 확인 | [4.5](#cron) | [08-cron.log](docs/logs/08-cron.log) | — |

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

외부에서 서버로 들어오는 경로는 두 겹으로 통제했다. 바깥쪽은 **방화벽**이 어떤 포트로
들어올 수 있는지를 정하고, 안쪽은 **SSH**가 누가 로그인할 수 있는지를 정한다.

```
외부 접속  ──▶  ① 방화벽 : 20022 포트로 들어올 수 있는가?
                      ↓
                ② SSH    : 그 계정으로 로그인할 수 있는가?
```

<a id="ssh"></a>

#### 4.1.1 SSH 포트 변경(20022) 및 Root 원격 접속 차단

SSH는 원격에서 서버에 접속해 명령을 내리는 통로다. 기본 포트 22번과 기본 계정 `root`는
모든 리눅스에 공통으로 존재하기 때문에 자동화된 공격 도구가 가장 먼저 노리는 지점이다.

**① SSH 서버 설치 및 설정 파일 백업**

```bash
sudo apt install -y openssh-server
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
```

되돌릴 수단 없이 시스템 설정을 수정하면 문제 발생 시 복구할 방법이 없으므로 먼저 백업했다.

**② 포트와 root 로그인 설정 변경**

```bash
sudo sed -i 's/^#\?Port .*/Port 20022/'                   /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
```

기본 설정 파일에서 두 항목은 `#Port 22`처럼 주석 처리되어 있다. `#\?`는 `#`이 있든 없든
일치시키라는 뜻이며, 주석 상태와 설정 상태 모두를 한 번에 처리한다.

**③ 문법 검사 후 재시작**

```bash
sudo sshd -t
sudo systemctl restart ssh
```

`sshd -t`는 설정 파일의 문법만 검사한다. 오류가 있는 상태로 재시작하면 sshd가 기동에
실패하는데, 원격 서버였다면 그 순간 접속 경로 자체가 사라져 복구가 불가능해진다.
설정 파일을 수정해도 이미 실행 중인 프로세스는 변경을 알지 못하므로 재시작이 필요하다.

**확인**

```bash
sudo sshd -T | grep -iE '^(port|permitrootlogin)'
sudo ss -tulnp | grep sshd
ssh -p 20022 root@localhost
```

```
port 20022
permitrootlogin no

tcp LISTEN 0 128 0.0.0.0:20022 ... users:(("sshd",pid=3773,fd=3))

root@localhost: Permission denied (publickey,password).
```

`sshd -T`는 설정 파일의 내용이 아니라 **실제 적용된 최종 값**을 출력하므로 재시작 누락까지
걸러낸다. 접속 시험 결과는 다음과 같다.

| 시험 | 결과 | 의미 |
|---|---|---|
| `ssh -p 20022 agent-admin@localhost` | 접속 성공 | 신규 포트 정상 동작 |
| `ssh -p 20022 root@localhost` | `Permission denied` | root 원격 로그인 차단 |
| `ssh -p 22 agent-admin@localhost` | `Connection refused` | 구 포트 미개방 |

차단한 것은 root의 **원격 로그인**이며 계정 자체를 없앤 것이 아니다. 일반 계정으로 접속한 뒤
`sudo`를 쓰는 경로는 열려 있고, 이렇게 한 단계를 거치게 하면 누가 어떤 관리자 명령을
실행했는지가 `sudo` 로그에 남는다.

<a id="firewall"></a>

#### 4.1.2 방화벽(UFW) 활성화 및 20022/tcp, 15034/tcp만 허용

**왜 필요한가** — SSH 설정만으로는 충분하지 않다. 포트가 LISTEN 상태라는 것과 외부에서
그 포트에 도달할 수 있다는 것은 별개의 문제다. 서버에는 의도하지 않은 포트가 열려 있을 수
있고, 새 패키지를 설치하면 그 프로그램이 임의의 포트를 열기도 한다. 방화벽은 그 앞단에서
**어떤 포트로만 들어올 수 있는지**를 통제한다.

**UFW를 고른 이유** — 과제가 UFW와 firewalld 중 택일하도록 했다. 둘 다 리눅스 커널의
netfilter(iptables)를 조작하는 도구이며, UFW(Uncomplicated Firewall)는 Ubuntu의 기본
방화벽 관리 도구이고 규칙 문법이 단순하다. 본 실습 환경이 Ubuntu 22.04이므로 UFW를 선택했다.

**① 설치**

```bash
sudo apt install -y ufw
```

OrbStack의 Ubuntu 이미지에는 `ufw`와 `iptables`가 기본 설치되어 있지 않아 함께 설치된다.

**② 기본 정책 설정**

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

기본 정책은 **허용 목록에 없는 트래픽을 어떻게 처리할지**를 정한다.

| 방향 | 설정 | 이유 |
|---|---|---|
| `incoming` (외부 → 서버) | **deny** | 누가 접속할지 알 수 없으므로 전부 차단 |
| `outgoing` (서버 → 외부) | allow | 패키지 설치 등 서버가 먼저 요청하는 통신 |

"위험한 것을 막는" 블랙리스트 방식은 막아야 할 대상이 65535개 포트만큼 무한하지만,
"필요한 것만 여는" 화이트리스트 방식은 열어야 할 대상이 유한하다. 최소 권한 원칙을
네트워크에 적용한 것이며, 나중에 새 프로그램이 포트를 열어도 자동으로 차단된다.

**③ 필요한 포트만 허용**

```bash
sudo ufw allow 20022/tcp comment 'SSH'
sudo ufw allow 15034/tcp comment 'agent-app'
```

`comment`로 각 규칙의 용도를 기록했다. 운영 중 규칙이 늘어나면 어떤 포트가 왜 열려 있는지
알 수 없게 되고, 그러면 불필요해진 규칙을 정리하지 못한다.

**④ 활성화**

```bash
sudo ufw enable
```

> 포트를 먼저 허용하고 나서 방화벽을 켜는 **순서를 지켜야 한다.** 반대로 하면 활성화되는
> 순간 SSH 연결이 끊기고, 원격 서버라면 다시 들어갈 수 없다.

**확인**

```bash
sudo ufw status verbose
```

```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
New profiles: skip

To                         Action      From
20022/tcp                  ALLOW IN    Anywhere        # SSH
15034/tcp                  ALLOW IN    Anywhere        # agent-app
20022/tcp (v6)             ALLOW IN    Anywhere (v6)   # SSH
15034/tcp (v6)             ALLOW IN    Anywhere (v6)   # agent-app
```

규칙이 네 줄인 것은 UFW가 IPv4와 IPv6에 각각 규칙을 생성하기 때문이다. 포트는 두 개가 맞다.

실제로 어떤 규칙이 커널에 적재되었는지는 iptables로 확인할 수 있다.

```bash
sudo iptables -L INPUT -n | head -3
sudo iptables -L ufw-user-input -n
```

```
Chain INPUT (policy DROP)              ← 기본 정책이 DROP

Chain ufw-user-input (1 references)
ACCEPT  tcp  --  0.0.0.0/0  0.0.0.0/0  tcp dpt:20022
ACCEPT  tcp  --  0.0.0.0/0  0.0.0.0/0  tcp dpt:15034
```

**외부에서의 실제 검증** — 규칙 등록과 실제 차단은 별개이므로 호스트(macOS)에서 VM으로
직접 접속을 시도했다.

| 포트 | 결과 | 판정 |
|---|---|---|
| 20022 | `succeeded` | 허용 |
| 15034 | `succeeded` | 허용 |
| 22 | `Operation timed out` | 차단 |
| 8080 | `Operation timed out` | 차단 |

응답의 **종류**가 중요하다. 방화벽 없이 포트만 닫혀 있으면 커널이 즉시 RST 패킷을 보내
`Connection refused`가 반환된다. `timed out`은 방화벽이 패킷에 응답하지 않고 버리고
있다(DROP)는 뜻이며, 이 방식은 공격자에게 호스트나 포트의 존재 여부조차 알려주지 않는다.

문제가 생겼을 때는 `sudo ufw disable` 한 줄로 즉시 원상 복구된다.

---

### 4.2 계정 / 그룹 / 권한 체계

<a id="users"></a>

#### 4.2.1 계정과 그룹

여러 사람이 한 서버를 함께 쓰는 상황을 가정해 역할별로 계정을 나누고, 역할이 겹치는 범위를
그룹으로 묶었다.

```bash
sudo groupadd agent-common
sudo groupadd agent-core
sudo useradd -m -s /bin/bash -G agent-common,agent-core agent-admin
sudo useradd -m -s /bin/bash -G agent-common,agent-core agent-dev
sudo useradd -m -s /bin/bash -G agent-common            agent-test
```

`-m`은 홈 디렉토리를 만들고, `-s`는 로그인 셸을, `-G`는 소속 그룹을 지정한다.

| 계정 | uid | 소속 그룹 | 역할 |
|---|---|---|---|
| `agent-admin` | 1000 | agent-common, agent-core | 운영·관리, cron 실행자 |
| `agent-dev` | 1001 | agent-common, agent-core | 개발, monitor.sh 작성자 |
| `agent-test` | 1002 | agent-common | QA·테스트 |

`agent-test`만 `agent-core`에서 제외한 것이 이 구성의 핵심이다. QA 담당자가 API 키나
운영 로그에 접근할 업무상 이유가 없기 때문이며, 권한을 직무에 필요한 최소 범위로 제한하면
계정이 탈취되거나 실수가 발생해도 피해 범위가 그 역할 안으로 제한된다.

그룹이라는 중간 단계가 필요한 이유는, 권한을 "소유자 / 나머지 전부" 두 단계로만 나누면
일부에게만 열어주는 통제가 불가능하기 때문이다. `api_keys`를 `agent-dev`에게 열어주려면
"나머지 전부"에게 열어야 하고, 그러면 `agent-test`도 함께 보게 된다.

**확인**

```bash
getent group agent-common agent-core
id agent-admin ; id agent-dev ; id agent-test
```

```
agent-common:x:1000:agent-admin,agent-dev,agent-test
agent-core:x:1001:agent-admin,agent-dev
```

`getent group`은 그룹에 속한 사람을, `id`는 사람이 속한 그룹을 보여준다. 두 방향이
일치하는지 교차 확인했다. uid/gid 숫자는 생성 순서대로 붙는 일련번호일 뿐 의미가 없다.

<a id="dirs"></a>

#### 4.2.2 디렉토리 구조와 권한

공유해도 되는 디렉토리와 제한해야 할 디렉토리를 나누고 각각에 맞는 권한을 부여했다.

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
| `$AGENT_HOME/upload_files` | agent-admin | agent-common | `2770` | **공유** |
| `$AGENT_HOME/api_keys` | agent-admin | agent-core | `2770` | **보안** |
| `$AGENT_HOME/bin` | **agent-dev** | agent-core | `2750` | 스크립트 |
| `/var/log/agent-app` | agent-admin | agent-core | `2770` | **보안** |

`chown`은 누구의 것인지를, `chmod`는 그 사람이 무엇을 할 수 있는지를 정한다. 둘은 한 쌍이며
하나만으로는 의미가 없다. 권한 숫자는 읽기 4, 쓰기 2, 실행 1을 더해 만들고, 세 자리는 순서대로
소유자·그룹·나머지에 적용된다. 디렉토리에서 `x`는 실행이 아니라 **통과**를 뜻한다.

앞에 붙은 `2`는 **setgid**다. 이 디렉토리에 새로 생기는 파일이 생성자의 개인 그룹이 아니라
디렉토리의 그룹을 물려받게 한다. 없으면 `agent-dev`가 공유 폴더에 만든 파일의 그룹이
`agent-dev`가 되어 `agent-test`가 읽지 못한다.

`bin`만 `2750`으로 둔 것은 의도적이다. 소유자 `agent-dev`는 스크립트를 수정할 수 있지만
그룹에 속한 `agent-admin`은 `r-x`라 실행만 가능하다. cron 실행에는 `r-x`면 충분하고,
운영 중 스크립트가 변경되는 경로는 차단된다.

<a id="acl"></a>

#### 4.2.3 ACL

```bash
sudo setfacl -m  g:agent-common:r-x /home/agent-admin
sudo setfacl -m  g:agent-common:rwx $AGENT_HOME/upload_files
sudo setfacl -dm g:agent-common:rwx $AGENT_HOME/upload_files
sudo setfacl -m  g:agent-core:rwx   $AGENT_HOME/api_keys /var/log/agent-app
sudo setfacl -dm g:agent-core:rwx   $AGENT_HOME/api_keys /var/log/agent-app
```

ACL이 반드시 필요했던 지점은 상위 디렉토리다. `AGENT_HOME`의 상위인 `/home/agent-admin`은
`drwxr-x---  agent-admin:agent-admin`이라 `agent-dev`와 `agent-test`가 통과할 수 없었다.
디렉토리의 `x`가 없으면 하위 권한을 아무리 정확히 설정해도 진입 자체가 불가능하다.
그런데 일반 권한은 그룹을 하나만 지정할 수 있어 여기에 `agent-common`을 추가할 방법이 없다.
ACL은 "기존 권한은 그대로 두고 이 그룹에게만 규칙을 더한다"를 표현할 수 있어 이 한계를 보완한다.

`-d`(default) 옵션은 **권한 상속**을 담당한다. setgid가 그룹은 물려주지만 권한은 물려주지
않아, default ACL이 없으면 새 파일이 umask를 따라 `rw-r--r--`가 되어 그룹이 쓰기를 하지 못한다.
setgid와 default ACL이 함께 있어야 공유가 완성된다.

**확인**

```bash
sudo ls -l /home/agent-admin/agent-app
sudo ls -ld /var/log/agent-app
sudo -u agent-test ls /home/agent-admin/agent-app/api_keys
```

```
drwxrws---+ 1 agent-admin agent-core    api_keys
drwxr-s---  1 agent-dev   agent-core    bin
drwxrws---+ 1 agent-admin agent-common  upload_files
drwxrws---+ 1 agent-admin agent-core    /var/log/agent-app

ls: cannot open directory '.../api_keys': Permission denied
```

권한 표기 끝의 `+`는 ACL이 적용되었다는 표시이고, 그룹 자리의 `s`는 setgid가 켜져 있다는 표시다.
마지막 명령의 `Permission denied`가 보안 디렉토리 분리가 동작한다는 증거다.
보안 설정은 허용되는 접근보다 **차단되는 접근**을 증명하는 것이 중요하다.

| 시험 | 기대 | 결과 |
|---|---|---|
| `agent-dev` → `$AGENT_HOME` 진입 | 성공 | ✅ |
| `agent-test` → `upload_files` 쓰기 | 성공 | ✅ |
| `agent-test` → `api_keys` 접근 | **차단** | `Permission denied` |
| `agent-dev` → `api_keys` 접근 | 성공 | ✅ |
| 신규 파일 속성 | `agent-common` / `rw-rw----` | ✅ |

---

<a id="app"></a>

### 4.3 애플리케이션 실행 환경 구성

**① 바이너리 배치**

```bash
case "$(uname -m)" in
  x86_64)        APP=agent-app-linux-x86   ;;
  aarch64|arm64) APP=agent-app-linux-arm64 ;;
esac
sudo install -o agent-admin -g agent-core -m 750 "app/$APP" "$AGENT_HOME/agent_app"
```

제공 바이너리가 x86과 arm64로 나뉘어 있어 `uname -m`으로 아키텍처를 감지해 배치하되,
**파일명을 `agent_app`으로 통일**했다. 그렇게 하지 않으면 `monitor.sh`가 찾아야 할
프로세스명이 환경마다 달라진다.

**② 키 파일 생성**

```bash
echo 'agent_api_key_test' | sudo -u agent-admin tee $AGENT_HOME/api_keys/secret.key
sudo chmod 640 $AGENT_HOME/api_keys/secret.key
```

`sudo echo ... > 파일` 형태를 쓰지 않은 이유는 리다이렉션(`>`)이 `sudo`가 적용되기 전에
호출자의 권한으로 처리되기 때문이다. 파일을 직접 여는 `tee`를 사용해야 한다.

**③ 환경 변수**

```bash
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
export AGENT_KEY_PATH=$AGENT_HOME/api_keys
export AGENT_LOG_DIR=/var/log/agent-app
```

경로와 포트를 코드에 직접 넣으면 환경이 바뀔 때마다 코드를 고쳐야 하지만, 환경 변수로
분리하면 같은 바이너리가 환경만 바꿔 동작한다.

위 내용을 `$AGENT_HOME/agent.env` 파일 한 곳에 정의하고, 로그인 셸과 `monitor.sh`가 각각
이 파일을 읽어가도록 했다. 셸 프로필에만 두지 않은 이유는 cron 때문이다. cron은 로그인 셸이
아니어서 `~/.profile`을 읽지 않으므로, 프로필에만 정의하면 수동 실행은 성공하고 cron 실행만
실패하는 문제가 생긴다.

**④ 기동**

```bash
sudo -iu agent-admin bash -lc 'nohup "$AGENT_HOME/agent_app" >> "$AGENT_LOG_DIR/agent-app.out" 2>&1 &'
```

루트로 실행하지 않은 이유는 애플리케이션이 침해당하면 공격자가 그 프로세스의 권한을
그대로 획득하기 때문이다. root로 구동하면 앱 취약점 하나가 서버 전체 장악으로 이어진다.

`nohup ... &`로 백그라운드 실행한 것은 터미널 세션에 묶어두면 이후 작업 중 서비스가
유지되지 않기 때문이다.

**확인**

```bash
sudo head -20 /var/log/agent-app/agent-app.out
```

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

앱은 기동 시 다섯 가지를 검사한다. 루트가 아닌 서비스 계정으로 실행 중인지, 환경 변수가
올바른지, 키 파일이 존재하고 내용이 맞는지, 포트가 비어 있는지, 로그 디렉토리에 쓸 수 있는지다.
즉 이 앱은 앞선 모든 설정을 검사해 주는 역할도 한다.

---

<a id="monitor"></a>

### 4.4 시스템 관제 자동화 스크립트 — monitor.sh

소스: [`scripts/monitor.sh`](scripts/monitor.sh)

경로는 `$AGENT_HOME/bin/monitor.sh`, 소유자는 `agent-dev`, 그룹은 `agent-core`, 권한은 `750`이다.
`agent-admin`은 `agent-core` 소속이라 그룹 권한 `r-x`로 실행할 수 있고 수정은 불가능하다.

매 실행마다 다음 순서로 동작한다.

```
① Health Check   프로세스 · 포트        실패 시 exit 1
② 방화벽 점검     상태 확인만            비활성이면 경고만
③ 자원 수집       CPU · MEM · DISK
④ 임계값 경고     20% / 10% / 80%       초과해도 계속 진행
⑤ 로그 기록       monitor.log 에 1줄     10MB 초과 시 회전
```

#### 4.4.1 Health Check — 실패 등급 구분

이 스크립트의 핵심 설계는 **중단시킬 실패와 기록만 할 이상을 나눈 것**이다.

| 점검 | 이상 시 동작 | 근거 |
|---|---|---|
| 프로세스 부재 | `exit 1` | 서비스 중단 — 지금 사용자가 쓸 수 없다 |
| 포트 미개방 | `exit 1` | 프로세스가 살아도 서비스 불가 |
| 방화벽 비활성 | `[WARNING]` 후 계속 | 보안 이슈이나 서비스는 동작한다 |
| 임계값 초과 | `[WARNING]` 후 계속 | 추세 관찰 대상이다 |

판단 기준은 "지금 서비스가 멈췄는가"다. 모든 이상을 긴급으로 처리하면 알림이 과다해져
사람들이 알림을 무시하게 되고, 결국 실제 사고를 놓친다. cron이나 상위 감시 도구는 종료 코드로
성패를 판단하므로, 경고에도 `exit 1`을 내면 모든 경고가 장애로 인식된다.

프로세스와 포트를 모두 확인하는 이유는 프로세스가 살아 있어도 포트를 잡지 못하면
외부에서는 서비스 불가 상태이기 때문이다.

```bash
PID=$(pgrep -x "$PROC_NAME" | head -1)
ss -ltn | awk '{print $4}' | grep -q ":${AGENT_PORT}$"
```

`pgrep -x`는 프로세스 **이름**이 정확히 일치하는 것만 찾는다. `-f`는 명령줄 전체를 매칭하므로
스크립트 자신의 명령줄에 포함된 문자열까지 걸려 오탐이 발생한다.
`ss`는 `netstat`의 후속 표준이며, `-l`은 LISTEN만, `-t`는 TCP만, `-n`은 이름 변환을 생략한다.
`-p`(프로세스명)는 root 권한이 필요해 일부러 제외했다.

#### 4.4.2 방화벽 점검

```bash
grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf
```

`ufw status`는 root 권한이 필요하고 `monitor.sh`는 일반 계정으로 동작해야 하므로,
일반 계정도 읽을 수 있는 `/etc/ufw/ufw.conf`의 `ENABLED` 값을 판정 근거로 사용했다.
감시 도구가 설정을 바꾸지는 않는다. 운영자가 점검을 위해 잠시 꺼둔 것을 되살려버리면
그 자체가 사고가 되기 때문이며, 애초에 `agent-admin`에는 그럴 권한도 없다.

#### 4.4.3 자원 수집과 임계값

| 지표 | 방식 | 이유 |
|---|---|---|
| CPU | `/proc/stat`을 1초 간격 2회 읽어 차분 계산 | 값이 부팅 이후 누적이라 한 번만 읽으면 현재 부하가 아니라 평균이 나온다 |
| MEM | `/proc/meminfo`의 `MemAvailable` 기준 | `MemFree`는 디스크 캐시를 사용 중으로 세어 실제보다 크게 나온다 |
| DISK | `df -P /`의 Used % | 루트 파티션 기준 |

헬스체크가 "죽었는가"라는 이분법이라 이미 죽은 뒤에야 알려주는 반면, 자원 수치는
"얼마나 위태로운가"를 알려주므로 멈추기 전에 대응할 수 있다.

CPU 계산이 정확한지는 부하를 걸어 대조 검증했다.

| 부하 | 측정값 | 이론값 |
|---|---|---|
| 없음 | 0.3% | ~0% |
| 1코어 100% | 9.2% | 9.1% (11코어 중 1개) |
| 4코어 100% | 37.5% | 36.4% |

임계값 CPU 20%, MEM 10%는 제공 앱의 부하 패턴(메모리를 0에서 256MB까지 올렸다 내리는 순환)에서
경고가 실제로 발생하도록 설계된 값이다. MEM은 `10.2%`로 자연 발생했고, CPU는 본 환경이
11코어여서 앱이 1코어를 점유해도 전체로는 9%대에 그치므로 인위 부하로 로직을 검증했다.

<a id="logging"></a>

#### 4.4.4 로그 기록과 용량 관리

```
[2026-09-17 14:56:02] PID:5454 CPU:0.2% MEM:10.0% DISK_USED:1%
[2026-09-17 14:57:02] PID:5454 CPU:0.5% MEM:7.9%  DISK_USED:1%
```

사람이 읽으면서 기계도 파싱할 수 있도록 키와 순서를 고정했다. 시각을
`YYYY-MM-DD HH:MM:SS`로 둔 것은 문자열 정렬이 곧 시간 정렬이 되기 때문이다.

기록에는 `>>`를 썼다. `>`는 파일을 비우고 새로 쓰므로, 매분 실행되는 스크립트에서 `>`를 쓰면
항상 최근 한 줄만 남고 이전 기록이 사라진다. 로그의 가치는 시계열에 있어서, 한 시점의 값만으로는
원래 그런 것인지 지금 이상한 것인지 판단할 수 없다.

용량 관리는 `rotate_log()`가 담당한다. 10MB를 초과하면 아래처럼 회전시킨다.

```
monitor.log.9    → 삭제
monitor.log.8    → monitor.log.9
    ...
monitor.log.1    → monitor.log.2
monitor.log      → monitor.log.1
```

원본과 `.1`~`.9`로 최대 10개가 유지되어 로그 총량에 상한이 생긴다. 로그는 남기는 것과
지우는 것이 한 쌍이며, 방치하면 디스크가 가득 차 서버가 정지한다.

`logrotate`라는 전용 도구도 있으나 스크립트 내부에 구현했다. logrotate는 보통 하루 한 번
실행되어 급증 상황에 늦게 반응하고, 설정이 `/etc`에 있어 root 권한이 필요한데
`monitor.sh`는 일반 계정으로 동작해야 한다.

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

비정상 상태의 동작은 프로세스를 중단시켜 확인한다. 확인 후에는 애플리케이션을 다시 기동한다.

```bash
sudo pkill -x agent_app
sudo -u agent-admin /home/agent-admin/agent-app/bin/monitor.sh ; echo "exit=$?"
```

각 시나리오를 실제로 재현한 결과는 다음과 같다.

| 시나리오 | 출력 | exit |
|---|---|---|
| 정상 | 전 항목 `[OK]` | 0 |
| 앱 중단 | `[CRITICAL] Process 'agent_app' is not running.` | **1** |
| 방화벽 비활성 | `[WARNING] Firewall (ufw) is INACTIVE.` 후 로그 기록까지 완료 | 0 |
| CPU 초과 | `[WARNING] CPU threshold exceeded (36.6% > 20%)` | 0 |
| MEM 초과 | `[WARNING] MEM threshold exceeded (10.2% > 10%)` | 0 |

---

<a id="cron"></a>

### 4.5 자동 실행(cron) 설정

```bash
printf '* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/monitor-cron.out 2>&1\n' \
  | sudo crontab -u agent-admin -
```

앞의 별 다섯 개는 순서대로 분, 시, 일, 월, 요일이며 모두 `*`이면 조건 없이 매분 실행한다.

실행 계정은 `agent-admin`으로 지정했다. `agent-core` 소속이라 `agent-dev` 소유의
스크립트를 그룹 권한으로 실행할 수 있고 수정 권한은 없다.

출력을 파일로 보낸 것은 cron이 표준 출력을 메일로 보내려 하기 때문이며, `2>&1`로 에러까지
함께 기록해 문제 발생 시 원인을 확인할 수 있게 했다.

사람이 매분 서버 상태를 확인할 수는 없으므로 점검 자체를 자동화해야 하고, 자동화하면
사람이 보지 않는 시간대의 상태도 기록으로 남는다.

**확인**

```bash
sudo crontab -u agent-admin -l
sudo grep CRON /var/log/syslog | grep agent-admin | tail -3
sudo wc -l /var/log/agent-app/monitor.log
```

마지막 명령을 1분 간격으로 두 번 실행하면 라인 수가 증가한다. 실제로 사람의 개입 없이
75초를 방치했을 때 31줄에서 33줄로 늘었다.

```
Sep 17 14:51:01 agent CRON[6282]: (agent-admin) CMD (/home/agent-admin/agent-app/bin/monitor.sh >> ...)
Sep 17 14:52:01 agent CRON[6307]: (agent-admin) CMD (...)
Sep 17 14:53:01 agent CRON[6370]: (agent-admin) CMD (...)
```

`monitor.log`의 증가만으로는 수동 실행과 구분되지 않으므로, cron이 실제로 호출했음을
보여주는 syslog 기록을 함께 확인한다.

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
