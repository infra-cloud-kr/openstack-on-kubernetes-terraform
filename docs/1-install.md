# 1. 설치

AWS EC2 한 대를 띄우고 그 위에 K8s 1.34 + OpenStack-Helm 2026.1.0을 깔아 CirrOS VM 부팅까지 가는 전체 사이클. (Rook-Ceph 단일 노드 클러스터 + Cinder LVM 백엔드 포함)

## 1.1 로컬 도구 (macOS Apple Silicon 기준)

```bash
brew install awscli terraform jq make
```

`session-manager-plugin`은 별도 — macOS pkg installer라 sudo 비밀번호가 필요합니다:

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

## 1.2 AWS 자격증명

가장 빠른 길:
```bash
aws configure          # access key + secret + region (ap-northeast-2 권장)
aws sts get-caller-identity   # 누구로 인증됐는지 확인
```

> ⚠️ **AWS root 계정 일상 사용 비권장**. 처음 실습엔 root여도 작동은 하지만, IAM 사용자(또는 IAM Identity Center)를 만들어 `AdministratorAccess` (실습용 한정) + MFA 부여한 자격증명을 쓰는 게 안전합니다.

## 1.3 한 줄 사이클

| 단계 | 명령 | 소요 | 검증 포인트 |
|---|---|---|---|
| 0. terraform 초기화 | `make init` | 10초 | 처음 한 번 / 새 머신에서만. `.terraform/` 생성 |
| 1. EC2 + VPC 생성 | `make up` | ~2분 | `Apply complete! Resources: 10 added`, `instance_id`, `public_ip` 출력 |
| 2. K8s 부트스트랩 대기 | `make ready` | ~3분 | `K8S_READY` 출력될 때까지 다시 호출 |
| 3. K8s 상태 검증 | `make status` | 10초 | Node `Ready`, calico/coredns/kube-system 파드 1/1 Running |
| 4. OSH 풀스택 배포 | `make osh-deploy` | **~30분** | 마지막에 `DONE_OSH_DEPLOY` |
| 5. CirrOS VM 부팅 검증 | `make osh-vm` | ~3분 | `test-vm`이 BUILD → ACTIVE |
| 6. 정리 | `make down` | ~3분 | `Destroy complete! Resources: 10 destroyed` |

## 1.4 각 단계에서 일어나는 일

**`make up`**: VPC/IGW/Subnet/SG/IAM 9개 + EC2 1개 = 10개 리소스 생성. EC2가 부팅되자마자 `user_data.sh`가 노드 안에서:
- containerd, kubeadm/kubelet/kubectl 1.34 설치
- kubeadm init
- Calico CNI apply (server-side, tigera-operator + custom-resources)
- control-plane taint 제거 (단일 노드라 워크로드 받게)
- helm v3 설치 (공식 `get-helm-3` 스크립트)
- 노드 Ready까지 대기 후 `/var/log/user-data-complete` 생성

**`make osh-deploy`**: 로컬 `osh/deploy.sh`가 base64로 인코딩돼 SSM `RunShellScript`로 노드에서 실행됨 (18 step). 진행 중 SSM 명령이 InProgress → Success로 가는 동안 30초마다 status 폴링. Step 1~15가 OSH 코어 스택(keystone~neutron + 단일노드 패치), Step 16이 Rook-Ceph(mon/osd/replication=1, 80G raw EBS), Step 17이 Cinder LVM 백엔드, Step 18이 최종 파드 대기.

**`make osh-vm`**: 임시 `openstack-client` 파드를 openstack ns에 띄우고 CirrOS 이미지 업로드 → m1.tiny flavor → demo-net 네트워크 → `openstack server create`. ACTIVE 될 때까지 5초마다 폴링.

## 1.5 끝났을 때 무엇을 기대해야 하나

```bash
# make osh-deploy 끝났을 때:
kubectl -n openstack get pods --no-headers | wc -l    # ~60개
helm -n openstack list                                # 10개 release (keystone/glance/...)
kubectl -n rook-ceph get pods                         # operator/mon-a/mgr-a/osd-0 Running
kubectl get sc                                        # rook-ceph-block (rbd) + local-path(default)/general

# make osh-vm 끝났을 때:
openstack server list                                 # test-vm ACTIVE
openstack hypervisor list                             # ip-10-0-1-XX QEMU up
```

> ⚠️ **반드시 끝나면 `make down`**. m5.4xlarge는 시간당 ≈$0.97 (EBS 포함). 잊고 24시간 두면 ~$24. 비용 표는 [6장](6-cost.md) 참조.

---

다음 → [2. 설치 확인](2-verify.md)
