# openstack-aws — OpenStack-Helm 컴퓨트 코어 실습용 단일 노드 랩

AWS EC2 한 대 위에 Kubernetes + OpenStack-Helm 2024.2.0 (Keystone / Glance / Nova / Neutron) 을 띄우고 CirrOS VM 부팅까지 검증하는 실습 환경.

## 무엇이 들어 있나

```
.
├── Makefile                # make up / down / osh-deploy / osh-vm 등 단축 명령
├── terraform/              # AWS 인프라
│   ├── providers.tf        #   AWS provider (Seoul 리전)
│   ├── vpc.tf              #   VPC + 퍼블릭 서브넷 + egress-only SG
│   ├── iam.tf              #   SSM Session Manager용 IAM 역할 (SSH 안 씀)
│   ├── ec2.tf              #   m5.4xlarge Ubuntu 22.04, 100GB gp3
│   ├── user_data.sh        #   부팅 시 K8s 1.29 + Calico 자동 설치
│   ├── outputs.tf          #   instance_id, region, ssm_command 출력
│   └── variables.tf
└── osh/                    # OpenStack-Helm 배포 (노드에서 실행)
    ├── deploy.sh           #   OSH 2024.2.0 컴퓨트 코어 풀스택 설치 (~30분)
    └── cirros-boot.sh      #   CirrOS VM 부팅으로 검증 (~3분)
```

## 처음 한 번만 — 로컬 환경 setup

### 1) 도구 설치 (macOS Apple Silicon 기준)

```bash
brew install awscli terraform jq make
```

`session-manager-plugin`은 macOS pkg installer라 sudo 비밀번호가 필요합니다:

```bash
# 옵션 A: brew cask (sudo 프롬프트 뜸)
brew install --cask session-manager-plugin

# 옵션 B: sudo 없이 zip bundle을 brew bin에 풀기
TMP=$(mktemp -d) && cd "$TMP"
curl -fsSL -o sm.zip https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/sessionmanager-bundle.zip
unzip -q sm.zip
cp sessionmanager-bundle/bin/session-manager-plugin /opt/homebrew/bin/
chmod +x /opt/homebrew/bin/session-manager-plugin
```

검증:
```bash
terraform version       # >= 1.5
aws --version           # v2.x
session-manager-plugin --version
```

### 2) AWS 자격증명

가장 빠른 길:
```bash
aws configure          # access key + secret + region(ap-northeast-2 권장)
aws sts get-caller-identity   # 누구로 인증됐는지 확인
```

> ⚠️ **AWS root 계정으로 일상 사용 비권장**. 처음 실습엔 root여도 작동은 하지만, IAM 사용자(또는 IAM Identity Center)를 만들어 `AdministratorAccess` 정책 (실습용 한정) + MFA 부여한 다음 그 자격증명을 쓰는 게 안전합니다.

### 3) 저장소 진입

이미 `/Users/eundms/openstack-aws`에 클론돼 있다고 가정. 다른 곳이면 그 경로로 `cd`.

```bash
cd /Users/eundms/openstack-aws
make help          # 사용 가능한 타겟 확인
```

---

## 매번 실행 사이클 (Cheatsheet)

| 단계 | 명령 | 소요 | 검증 포인트 |
|---|---|---|---|
| 0. terraform 초기화 | `make init` | 10초 | 처음 한 번 / 새 머신에서만. `.terraform/` 생성 |
| 1. EC2 + VPC 생성 | `make up` | ~2분 | `Apply complete! Resources: 10 added`, 그리고 `instance_id`, `public_ip` 출력 |
| 2. K8s 부트스트랩 대기 | `make ready` | ~1분 30초 | `K8S_READY` 출력될 때까지 다시 호출 |
| 3. K8s 상태 검증 | `make status` | 10초 | Node `Ready`, calico/coredns/kube-system 모든 파드 1/1 Running |
| 4. OSH 풀스택 배포 | `make osh-deploy` | **~30분** | 마지막에 `DONE_OSH_DEPLOY` |
| 5. CirrOS VM 부팅 검증 | `make osh-vm` | ~3분 | `test-vm`이 BUILD → ACTIVE |
| 6. 정리 | `make down` | ~3분 | `Destroy complete! Resources: 10 destroyed` |

### 각 단계에서 일어나는 일

**`make up`**: VPC/IGW/Subnet/SG/IAM 9개 + EC2 1개 = 10개 리소스 생성. EC2가 부팅되자마자 `user_data.sh`가 노드 안에서:
- containerd, kubeadm/kubelet/kubectl 1.29 설치
- kubeadm init
- Calico CNI apply (server-side, tigera-operator + custom-resources)
- control-plane taint 제거 (단일 노드라 워크로드 받게)
- 노드 Ready까지 대기 후 `/var/log/user-data-complete` 생성

**`make osh-deploy`**: 노드의 `/home/ubuntu/osh/deploy.sh`가 SSM으로 실행됨 (16 step). 진행 중 SSM 명령이 InProgress→Success로 가는 동안 30초마다 status 폴링. 마지막에 stdout tail이 화면에 나옵니다.

**`make osh-vm`**: 임시 `openstack-client` 파드를 openstack ns에 띄우고 CirrOS 이미지 업로드 → m1.tiny flavor → demo-net 네트워크 → `openstack server create`. ACTIVE 될 때까지 5초마다 폴링.

### 끝났을 때 무엇을 기대해야 하나

```bash
make osh-deploy 끝났을 때:
  kubectl -n openstack get pods --no-headers | wc -l    # ~60개
  helm -n openstack list                                # 9개 release (keystone/glance/...)

make osh-vm 끝났을 때:
  openstack server list                                 # test-vm ACTIVE
  openstack hypervisor list                             # ip-10-0-1-XX QEMU up
```

---

## 중간 점검 (노드 안에 들어가서 보고 싶을 때)

```bash
make ssm                  # SSM Session Manager로 노드 shell
# 노드 안에서:
sudo -i                                                   # root
export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl get nodes -o wide
kubectl -n openstack get pods --no-headers | wc -l        # 파드 카운트
kubectl -n openstack get pods --no-headers | awk '{print $3}' | sort | uniq -c   # 상태 분포
kubectl -n openstack get pods --field-selector=status.phase!=Running --no-headers
helm -n openstack list -a
sudo tail -f /var/log/user-data.log                       # 부트스트랩 로그
```

OpenStack CLI는 `osc` 파드로:
```bash
kubectl -n openstack exec osc -- openstack server list
kubectl -n openstack exec osc -- openstack image list
kubectl -n openstack exec osc -- openstack network list
kubectl -n openstack exec osc -- openstack hypervisor list
kubectl -n openstack exec osc -- openstack compute service list
kubectl -n openstack exec osc -- openstack network agent list
```

---

## 에러 대처 cheatsheet

| 증상 | 원인 / 대처 |
|---|---|
| `make up` 도중 `UnauthorizedOperation` | AWS 자격증명/권한 부족. `aws sts get-caller-identity` 확인, 권한 부여 |
| `make ssm` → `session-manager-plugin not found` | 위 setup 2번 항목 다시. PATH에 있는지 `which session-manager-plugin` |
| `make osh-deploy`가 중간에 Failed로 끝남 | `make ssm` 들어가서 `helm -n openstack list -a`로 어떤 release가 failed인지 보기. 보통 그 chart만 다시 helm install 시도하면 진행됨. `osh/deploy.sh`는 set -e + helm upgrade --install로 짜여 있어 다시 `make osh-deploy` 호출해도 idempotent |
| 어떤 pod이 영원히 `Init:0/N` 또는 `0/1 Running` | 본 README 하단 "디버깅 / 트러블슈팅 — 이번에 발견한 함정" 참조. 대부분 4가지 케이스 안에 들어감 |
| `openstack server create`가 ERROR | `kubectl -n openstack logs nova-compute-default-XXX --tail=50` 보고, 보통 libvirt/qemu 호스트 자원 부족 또는 neutron 포트 생성 실패. nova flavor RAM/disk 더 줄여보기 |
| 처음부터 다시 깨끗하게 시작하고 싶음 | `make down` → 잠시 후 `make up` (terraform state는 자동 동기화, 추가 작업 불요) |

### `make osh-deploy`가 중간에 실패했을 때 — 이어하기

`osh/deploy.sh`는 idempotent하게 짜여 있어요:
- `helm upgrade --install` 사용 — 이미 깔린 release는 그대로
- 노드 라벨, StorageClass, namespace 등 모두 "이미 있으면 skip"
- patch 명령들도 멱등

그래서 그냥 다시 `make osh-deploy`를 호출하면 됩니다. 단, **glance helm release가 `failed` 상태로 박힌 경우**가 가끔 있는데 (post-install hook이 시간 끌리면) 이건 cosmetic이라 무시해도 PVC, pods는 정상.

만약 진짜 깨졌다 싶으면:
```bash
make ssm   # 노드 들어가서
sudo -i
export KUBECONFIG=/etc/kubernetes/admin.conf
helm -n openstack uninstall <release-name>     # 막힌 chart만 제거
# 그리고 로컬로 나와서 다시
make osh-deploy
```

---

## 비용 안 잊는 팁

```bash
# AWS Console에서 Billing & Cost Management → Cost Anomaly Detection으로
# "OpenStack lab" 알람 설정 (5달러 초과 시 메일).
# 또는 가장 단순하게 — 매번 실습 끝나면 alias로:
alias osh-down='cd /Users/eundms/openstack-aws && make down'
```

`make down`은 멱등 — 노드가 이미 destroy 됐어도 안전하게 "0 destroyed"로 마무리. 의심나면 그냥 한 번 더 돌려도 OK.

## 디자인 결정 메모

- **SSH 막힘, SSM Session Manager만 사용** — 한국 ISP outbound 22 차단 이슈 회피. 모든 노드 명령은 `aws ssm send-command` 또는 `aws ssm start-session`을 통해.
- **`m5.4xlarge` (16 vCPU / 64GB)** — OSH 풀스택은 무겁고, nested KVM이 안 돼서 nova 안에서 `virt_type=qemu` 소프트웨어 에뮬레이션이라 컴퓨트도 CPU 많이 먹는다.
- **OSH는 release tag `2024.2.0`에 고정** — 옛 자료의 `stable/2024.1` 브랜치는 이미 사라졌고, OSH 2025.2 이상은 `ubuntu_noble`만 CI에서 테스트. Ubuntu 22.04 (Jammy) 노드 + K8s 1.29 조합에 맞는 가장 최근 안정 태그가 2024.2.0.
- **Ingress / MetalLB / Ceph 모두 생략** — 학습용 단일 노드라 외부 노출이 필요 없고, glance용 storage는 `local-path-provisioner`를 `general`이라는 이름으로 alias.
- **K8s API server / kubelet은 외부 노출 없음** — 모든 검증은 노드 안에서 `kubectl` 또는 임시 `openstack-client` 파드를 통해.

## 디버깅 / 트러블슈팅 — 이번에 발견한 함정

1. **`helm osh` 플러그인이 다음 SSM 호출에서 사라짐**
   원인: SSM run-command 셸이 `HOME=''`로 시작. helm은 `$HOME/.local/share/helm/plugins`를 보는데 비어있으면 cwd 기준으로 보게 됨 → 매번 다른 디렉토리.
   해결: 노드에서 도는 모든 스크립트가 첫줄에 `export HOME=/root`.

2. **OSH의 `glance-images` PVC가 영원히 Pending**
   원인: glance 차트의 `volume.class_name=general`인데 우리 클러스터 default StorageClass는 `local-path`.
   해결: `general`이라는 이름으로 같은 provisioner (rancher.io/local-path)를 가리키는 StorageClass 하나 더 만들기. → `osh/deploy.sh` Step 4.

3. **`neutron-metadata-agent`가 Init:0/2에서 영원히 멈춤**
   원인: 차트의 init dependency가 `Service metadata`를 기다리는데, 그 Service의 selector는 `{app: ingress-api}`이고 ports는 80/443. 우리 클러스터엔 ingress 컨트롤러가 없어 selector match 없음 → endpoints 비어있음.
   해결: Service `metadata`의 selector를 `nova-api-metadata` 파드에 매치하도록 patch + targetPort를 8775로. → `osh/deploy.sh` Step 14.

4. **`nova-compute` / `neutron-l3-agent` / `neutron-dhcp-agent` DaemonSet이 0/1 Running으로 영원히**
   원인: `health-probe.py`가 `oslo.messaging`으로 RabbitMQ 호스트네임을 resolve 시도하는데, pod DNS 환경에서 어떤 이유로 timeout (`Name or service not known`). **실제 프로세스는 정상** — placement에 hypervisor 등록, neutron 에이전트 등록 다 잘 동작.
   해결: 세 DaemonSet에서 `startupProbe`/`readinessProbe`/`livenessProbe`를 모두 제거하고 rollout restart. → `osh/deploy.sh` Step 15.

5. **OSH가 옛 user_data 주석의 stable 브랜치를 더 이상 안 함**
   원인: opendev.org/openstack/openstack-helm의 `stable/2024.1` 브랜치 자체가 삭제됨. master/edge 두 갈래 + release tag만 남음.
   해결: release tag (`2024.2.0`)로 clone. → `osh/deploy.sh` Step 1.

## OpenStack-Helm 공식 권장 사양

OSH README.rst의 공식 호환성 매트릭스 (2024.2 기준):

| OpenStack release | Host OS | Image OS | Kubernetes |
|---|---|---|---|
| 2023.2 (Bobcat) | Ubuntu Jammy | Ubuntu Jammy | >=1.29, <=1.31 |
| 2024.1 (Caracal) | Ubuntu Jammy | Ubuntu Jammy | >=1.29, <=1.31 |
| **2024.2 (Dalmatian)** ← 이 랩 | **Ubuntu Jammy** | **Ubuntu Jammy** | **>=1.29, <=1.31** |

K8s 1.32 이상은 공식 지원 범위 밖. 더 최신 K8s를 쓰려면 OSH도 release tag 2025.x / 2026.1로 같이 올려야 하지만, 그 매트릭스는 OSH README에서 업데이트되지 않았고 CI는 `ubuntu_noble` (24.04) 기반으로 이전됐어요. 우리 랩은 README 권장 정중앙에 있습니다.

OSH CI의 `zuul.d/nodesets.yaml`에서 추정한 hardware 베이스라인:

| CI nodeset | 노드 수 | 노드 사양 (추정) | 용도 |
|---|---|---|---|
| `openstack-helm-1node-ubuntu_jammy` | 1 | 8 vCPU / 16GB | 가벼운 단일 차트 테스트 |
| **`openstack-helm-1node-32GB-ubuntu_jammy`** | **1** | **8 vCPU / 32GB** | 풀스택 단일 노드 ("extremely limited" 별도 flavor) |
| `openstack-helm-3nodes-ubuntu_jammy` | 3 | 각 8 vCPU / 16GB | 분산 |
| `openstack-helm-5nodes-ubuntu_jammy` | 5 | 각 8 vCPU / 16GB | Ceph 포함 풀스택 |

즉 **단일 노드에 컴퓨트 코어 풀스택을 띄울 거면 8 vCPU / 32GB가 OSH 측 권장 최소선**. nested KVM이 안 되는 클라우드 VM에서는 QEMU 소프트웨어 에뮬레이션이라 CPU 여유가 더 필요해요.

## AWS 인스턴스 선택지 + 비용

ap-northeast-2 (Seoul) 기준, 시간당 가격 (on-demand). EBS 100GB gp3는 모두 동일하게 **시간당 ≈$0.014** (월 ~$10) 추가됩니다.

| 인스턴스 | vCPU / RAM | $/hr | 한 시간 풀스택 비용 (EBS 포함) | 비고 |
|---|---|---|---|---|
| `t3.xlarge` | 4 / 16 GB | ~$0.21 | ~$0.22 | RAM 부족. mariadb + rabbit + nova/neutron까지만 빠듯 |
| `m5.xlarge` | 4 / 16 GB | ~$0.24 | ~$0.25 | OSH CI 1node와 동일. 풀스택은 OOM 위험 |
| **`m5.2xlarge`** ← 권장 가성비 | **8 / 32 GB** | **~$0.48** | **~$0.49** | **OSH의 1node-32GB nodeset과 정확히 매칭** |
| `t3.2xlarge` | 8 / 32 GB | ~$0.33 | ~$0.34 | burst CPU 제약. 컴포넌트 install 시 CPU credit 소진 가능 |
| **`m5.4xlarge`** ← 이 랩 현재 | **16 / 64 GB** | **~$0.96** | **~$0.97** | 여유 있음. 풀스택 + 여러 VM 부팅 + 약간의 옵션 컴포넌트도 |
| `c5.4xlarge` | 16 / 32 GB | ~$0.85 | ~$0.86 | CPU 강함, RAM은 m5.2xlarge와 같음 |

추가 비용:
- **VPC / IGW**: 무료 (NAT Gateway 만들지 않음. 우리 구조는 IGW만)
- **Egress 대역폭**: 1 GB/월 무료 후 ~$0.126/GB. 한 번 풀스택 띄우는 데 컨테이너 이미지 다운로드 ~2-3 GB → **~$0.3-0.4**
- **SSM Session Manager**: 무료 (CloudWatch Logs 안 켜는 한)
- **Public IP**: 시간당 ~$0.005 (2024년 이후 모든 IPv4 public IP에 부과)

### 시나리오별 한 사이클 (up → osh-deploy → osh-vm → down) 예상 총 비용

| 인스턴스 | 시간 | EC2 | EBS | Egress | 합계 |
|---|---|---|---|---|---|
| m5.2xlarge | 1 hr | $0.48 | $0.014 | ~$0.3 | **~$0.8** |
| **m5.4xlarge** (현재) | 1 hr | $0.96 | $0.014 | ~$0.3 | **~$1.3** |
| m5.2xlarge | 24 hr (잊고 안 내림) | $11.5 | $0.34 | ~$0.3 | **~$12** |
| m5.4xlarge | 24 hr | $23 | $0.34 | ~$0.3 | **~$24** |

> ⚠️ **인스턴스 안 내린 채로 잊으면 하루 $20-$25씩 누적**. `make down`이 인생을 구합니다.

### 인스턴스 사이즈 바꾸려면

`terraform/variables.tf:9`의 `instance_type` 기본값을 수정하거나 apply 시점에 인자로:
```bash
terraform -chdir=terraform apply -auto-approve -var="instance_type=m5.2xlarge"
```
`terraform plan` 시 EC2가 replace (재생성). 기존 K8s 클러스터 사라지고 새로 부트스트랩됩니다.
