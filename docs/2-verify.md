# 2. 설치 확인

K8s + OpenStack 컨트롤 플레인 + end-to-end VM 부팅까지 3계층으로 점검합니다.

## 2.1 노드 진입

로컬에서:
```bash
make ssm
```

내부적으로 `aws ssm start-session --target <instance_id> --region ap-northeast-2`. 처음 한 번은 `Starting session with SessionId: ...` 메시지 뜨고 프롬프트가 `sh-5.1$`로 바뀝니다. 이 프롬프트는 EC2 노드 **안**의 shell, default user는 `ssm-user` (sudoer).

세션 끊기: `exit` 또는 Ctrl-D.

연결이 안 될 때:
- `terraform output instance_id`가 비어 있으면 → `make up` 미완료. `make ready` 대기
- `TargetNotConnected` → 노드가 아직 SSM agent를 띄우는 중 (부팅 후 30초쯤). 다시 시도
- `session-manager-plugin not found` → 로컬에 플러그인 미설치, [1.1](1-install.md#11-로컬-도구-macos-apple-silicon-기준) 참조

### `KUBECONFIG` 환경변수가 왜 필요한가

`kubectl`은 클러스터 주소·인증서·토큰을 다음 우선순위로 찾아요:
1. `--kubeconfig` 플래그
2. **`$KUBECONFIG` 환경변수** ← 우리가 셋팅하는 것
3. `~/.kube/config`

`kubeadm init`이 만든 admin 자격증명은 `/etc/kubernetes/admin.conf`에 있는데 모드 0600·owner root라 일반 유저는 못 읽음. SSM 세션은 `ssm-user`로 떨어지고 root로 승격해도 root의 `~/.kube/config`는 비어 있을 수 있어서 명시적으로 `export KUBECONFIG=...` 해주는 거예요.

대안 두 가지:
```bash
# 옵션 A: root + export (이 문서 기본 방식)
sudo -i
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl ...

# 옵션 B: ubuntu 유저 (user_data가 ~ubuntu/.kube/config 깔아둠, export 불필요)
sudo -u ubuntu -i
kubectl ...
```

`make status` 타겟은 옵션 B 방식(`sudo -u ubuntu kubectl ...`)을 씁니다.

## 2.2 osc 파드로 OpenStack CLI 호출

OpenStack 명령어는 클러스터 안에 떠 있는 `osc` 파드(admin 크레덴셜이 envFrom으로 자동 주입)에서 실행합니다. 한 번씩 호출:

```bash
kubectl -n openstack exec osc -- openstack server list
kubectl -n openstack exec osc -- openstack image list
kubectl -n openstack exec osc -- openstack network list
kubectl -n openstack exec osc -- openstack hypervisor list
kubectl -n openstack exec osc -- openstack compute service list
kubectl -n openstack exec osc -- openstack network agent list
```

여러 명령 연속으로 칠 거면 셸로 진입:
```bash
kubectl -n openstack exec -it osc -- bash
# 안에서 openstack ... 자유롭게
```

`osc` 파드가 어떻게 admin 자격증명을 자동으로 받는지는 [3.6 자격증명 흐름](3-architecture.md#36-자격증명-흐름)에서 설명.

## 2.3 3계층 점검

위에서 아래로 내려가면서 끊기는 데가 없으면 OK.

### (a) K8s + Helm 레벨 — 인프라가 살았나

```bash
kubectl get nodes                                # Ready
helm -n openstack list                           # 10개 release 모두 deployed
kubectl -n openstack get pods --no-headers \
  | awk '{print $3}' | sort | uniq -c            # Running/Completed만 있어야 (보통 22 Running / 36 Completed)
```

### (b) OpenStack 컨트롤 플레인 — 각 서비스가 자기 등록 됐나

```bash
# nova-api / conductor / scheduler / compute 모두 State=up
kubectl -n openstack exec osc -- openstack compute service list

# 하이퍼바이저(=compute 노드)가 placement에 등록됐나 — ip-10-0-1-XX QEMU 1줄 보여야
kubectl -n openstack exec osc -- openstack hypervisor list

# neutron 에이전트들(L3 / DHCP / metadata / OVS) Alive=:-) State=UP
kubectl -n openstack exec osc -- openstack network agent list

# keystone endpoint catalog — public/internal/admin URL이 깔끔하게 나열됨
kubectl -n openstack exec osc -- openstack endpoint list
```

### (c) End-to-end — 실제 VM이 부팅되나 (가장 확실한 증거)

```bash
kubectl -n openstack exec osc -- openstack server list
# test-vm  ACTIVE  demo-net=10.10.10.XXX  cirros  m1.tiny

# 게스트 OS까지 부팅 끝났는지 — 마지막에 cirros 로그인 프롬프트(`login:`)
kubectl -n openstack exec osc -- openstack console log show test-vm | tail -20
```

`make osh-vm`이 이미 (c)를 자동으로 해줍니다. 따로 한 대 더 띄워서 확인하고 싶거나 ERROR 나는 경우는 [4장](4-using-openstack.md) / [5장](5-troubleshooting.md) 참조.

---

다음 → [3. K8s와 OpenStack은 어떻게 연계돼 있나](3-architecture.md)
