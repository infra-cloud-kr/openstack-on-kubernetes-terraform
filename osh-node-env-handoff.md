# OSH 단일 노드 환경 — 관측 실험(qemu-exporter) 인수인계

> **이 문서를 읽는 대상**: `infra-cloud-kr/openstack-on-kubernetes-terraform`로 AWS 단일 노드에
> OpenStack-Helm를 배포·운영하는 에이전트.
> **목적**: 그 위에서 돌아가는 별도 프로젝트 `qemu-exporter`(관측 수집기, 학부 논문 프로토타입)가
> 환경에 대해 무엇을 **전제**하고, 실험을 위해 무엇을 **요청**하는지 한 장에 정리한다.
> qemu-exporter 코드/배포는 별도 레포(`~/Desktop/openstack_helm_observility`, GitHub `LyleKim/qemu-exporter`)에 있고
> 이 문서는 그 레포에서 작성됨.

---

## 1. 배경 (짧게)

OpenStack-Helm에서 libvirtd가 만든 QEMU 프로세스는 `kubepods.slice`가 아니라 `machine`(cgroupfs 드라이버)
cgroup에 놓여 kubelet/cAdvisor 자원 회계에서 누락된다. `qemu-exporter`는 호스트 cgroupfs/procfs를 읽고
libvirt RO 소켓으로 Nova 메타데이터를 붙여 Prometheus 형식으로 노출하는 **읽기 전용** DaemonSet이다.
논문 주장 1개: *"QEMU가 K8s 자원 회계 밖 → 경합이 은폐됨 → 무변경 수집기로 드러낼 수 있다."*

**핵심**: 이 수집기는 설계상 OSH/libvirt/Nova 설정을 **하나도 바꾸지 않는다.** 환경 쪽에서 이 수집기를 위해
특별 설정을 추가할 필요도 없다. 아래 "전제"는 전부 현재 배포에서 이미 충족되어 있고(2026-09-07 실측),
환경을 재구축해도 그대로 유지되기만 하면 된다.

---

## 2. 환경 전제 (이미 충족됨 — 재구축 시 유지 확인용)

| 전제 | 확인 명령 | 현재 값 (2026-09-07) |
|---|---|---|
| 커널 PSI 지원 | `ls /proc/pressure/` | `cpu io memory` 존재 (kernel `7.0.0-1012-aws`) |
| cgroup v2 unified | `stat -fc %T /sys/fs/cgroup` | `cgroup2fs` |
| schedstat 켜짐 | `sysctl kernel.sched_schedstats` | `1` (기본값, 별도 설정 안 함) |
| libvirt RO 소켓이 **호스트**에 노출 | `sudo ls -l /var/run/libvirt/libvirt-sock-ro` | `srwxrwxrwx` 존재 (`/run/libvirt/`도 동일) |
| QEMU pidfile 호스트 경로 | `sudo ls /var/run/libvirt/qemu/` | `<domain>.pid` 존재, 디렉터리 world-readable |
| libvirt cgroup 드라이버 | `cat /proc/<qemu-pid>/cgroup` | `0::/machine/qemu-N-<name>.libvirt-qemu/emulator` = **cgroupfs 드라이버** (systemd-machined 미설치) |
| Nova 도메인 XML 메타데이터 | `virsh dumpxml <dom>` (libvirt 파드 안) | `<nova:instance>`에 flavor/project uuid 있음 |
| containerd | `kubectl get node -o wide` | `containerd://2.2.1`, K8s `v1.34.11` |

이 중 **하나라도 바뀌면** exporter가 깨지거나 지표 일부가 빈다. 특히:
- systemd-machined를 설치하면 libvirt가 systemd 드라이버로 전환 → cgroup 경로가 `machine.slice/...scope`로 바뀜
  (코드는 양쪽 다 대응하지만, 검증은 cgroupfs 기준으로만 됨)
- `/run/libvirt`를 libvirt 파드 내부 전용(emptyDir 등)으로 돌리면 호스트에서 소켓·pidfile이 안 보임 → exporter 전면 실패

---

## 3. 환경이 실험을 위해 제공해야 하는 것 (TDL)

### 3-1. 실험용 VM
- [ ] **Ubuntu 이미지 + 4 GiB 이상 flavor**로 인스턴스 1대 기동
  (현재 테스트 VM은 `m1.tiny` 512 MB — Fig.1의 메모리 회계 대비가 눈에 안 띔. Ubuntu여야 guest 안에 `mpstat`/`stress-ng` 사용 가능)
- [ ] 인스턴스 부팅 완료 확인 (`openstack server list` → ACTIVE)

### 3-2. guest 내부 접속 경로
- [ ] `virsh console <domain>` 로그인 가능하게 하거나(콘솔 크리덴셜), floating IP + 보안그룹 + SSH 키 중 하나 확보
  → 실험 중 VM **내부**에서 `/proc/stat`·`mpstat`를 2초 간격으로 샘플링해야 함 (Fig.3의 "게스트 관점" 시계열)

### 3-3. 경합 유발 파드 스케줄 여유
- [ ] `default` 네임스페이스에 `busybox` Deployment(replicas 4~8, `while :; do :; done`)를 띄울 수 있어야 함
  → ResourceQuota / LimitRange / 노드 taint 로 막혀 있지 않게
- [ ] 이 파드들이 **컴퓨트 노드(= 유일 노드)** 에 스케줄되는지 확인 (단일 노드라 자동이지만 taint 있으면 toleration 필요)

### 3-4. 실험 중 노드 안정성 (Fig.3는 의도적으로 CPU를 부족하게 만듦)
- [ ] Fig.3 시나리오: `t=60s`에 CPU-hog 파드 투입 → 노드 8 vCPU 오버커밋 → `t=180s`에 제거. 4분 사이클, 여러 번 반복될 수 있음
- [ ] 이 구간에 OSH 파드가 잠깐 느려지거나 `Ready` 깜빡이는 건 **정상** — 자동으로 개입해 되돌리지 말 것
- [ ] 단, OSH 핵심 파드(keystone/nova/neutron/rabbitmq/mariadb)가 **Evict/CrashLoop**로 넘어가면 실험자에게 알림.
  실험자가 hog replicas를 4로 낮춰 재시도함. hog는 `kubectl delete deploy cpu-hog`로 즉시 회수 가능
- [ ] `kubectl get pod -A | grep -vE 'Running|Completed'` 를 실험 중 모니터링 대상으로

### 3-5. 데이터 추출 전 환경 파기 금지
- [ ] `paper_data/` (실험 CSV·로그) 가 노드 밖으로 복사되기 전까지 **`make down` 금지**
  → 재구축 시 Fig.1/Fig.3 실험을 처음부터 다시 (비용 ~$0.8/h, 반나절 분량)
- [ ] 실험자가 "데이터 확보 완료" 신호를 준 뒤에 teardown

### 3-6. 환경 재구축 시 (필요할 때만)
- [ ] 재구축 후 §2 표의 8개 전제 재확인
- [ ] qemu-exporter DaemonSet 재적용 (§4)
- [ ] libvirt 파드명이 바뀌므로(`libvirt-libvirt-default-<hash>`) 실험 스크립트의 파드명 갱신 필요 — 실험자에게 새 파드명 전달

---

## 4. qemu-exporter 배포 방법 (환경 재구축 후 재적용용)

이미지는 실험자가 Mac에서 빌드·push함:
```
# ~/Desktop/openstack_helm_observility 에서
docker buildx build --no-cache --pull --platform linux/amd64 \
  -f deploy/Dockerfile -t lylekim/qemu-exporter:dev --push .
```
- 이미지: `docker.io/lylekim/qemu-exporter:dev` (Docker Hub public), `imagePullPolicy: Always`
- 매니페스트: `deploy/daemonset.yaml` (qemu-exporter 레포)
  - `namespace: openstack`, `hostPID: true`, `privileged: false`
  - RO hostPath 마운트 3개: `/proc`→`/host/proc`, `/sys/fs/cgroup`→`/host/sys/fs/cgroup`, `/var/run/libvirt`→`/var/run/libvirt`
  - env: `HOST_PROC`, `HOST_SYS_FS_CGROUP`, `LIBVIRT_SOCK=/var/run/libvirt/libvirt-sock-ro`, `NODE_NAME`(downward API)

```
kubectl -n openstack apply -f deploy/daemonset.yaml
kubectl -n openstack rollout status ds/qemu-exporter --timeout=90s

POD_IP=$(kubectl -n openstack get pod -l app=qemu-exporter -o jsonpath='{.items[0].status.podIP}')
curl -s http://$POD_IP:9179/metrics | grep -E '^(openstack_vm|qemu_exporter)'
```
정상 판정: `qemu_exporter_vms_discovered` ≥ 1, `qemu_exporter_scrape_errors_total` 0, `openstack_vm_*` 4종에 값+라벨.
- 이미지가 `FROM scratch`라 셸 없음 → `kubectl exec` 불가. `/metrics`는 podIP로 curl, 파일 확인은 호스트 `/proc/<pid>/root/...`.

---

## 5. 이 환경의 특성 메모 (참고 — 실험 결과 해석·재구축 시 유용)

- **단일 노드에 컨트롤+데이터 플레인 공존**. Fig.3 경합은 이 노드에서 일어나고 OSH도 같은 노드 → 강도 단계적.
- **KVM 없음, `-accel tcg`** (소프트웨어 에뮬레이션). 관측 지표는 실행 방식과 무관하나, TCG는 paravirt steal 회계가
  없어 "guest가 자기 굶는 걸 모른다"가 더 뚜렷 → 논문엔 유리, 단 §5 한계에 명시됨.
- **중첩 가상화**: EC2 인스턴스 자체가 VM. 확인 결과 파드 관점 == 호스트 관점 cgroup 경로 동일, cgroup 네임스페이스
  번역도 문제 없음 (exporter가 처리).
- **libvirt cgroupfs 드라이버** → 도메인 cgroup(`/machine/qemu-N-<name>.libvirt-qemu`) 밑에 threaded 하위 cgroup
  (`emulator/`, `vcpu0/`, `iothread1/`) 생성. exporter는 `cgroup.type`을 읽어 도메인 cgroup까지 올라가 계측함.
- **exporter 파드는 자체 cgroup 네임스페이스** → `/host/proc/<qemu>/cgroup`가 `/../` 프리픽스로 나옴.
  exporter가 `filepath.Clean`으로 정규화함 (배포 중 발견·수정한 이슈).
- QEMU pidfile: `/var/run/libvirt/qemu/<domain-name>.pid` (예: `instance-00000001.pid`), 내용은 QEMU 메인 PID.

---

## 6. 절대 하지 말 것

- qemu-exporter를 위해 **OSH 차트 / libvirt 설정 / Nova 설정 변경 금지**. 이 수집기의 논지 자체가 "무변경".
  뭔가 chart 수정이 필요해 보이면 그건 exporter 쪽에서 해결할 신호이므로 실험자에게 **알리기만** 할 것.
- systemd-machined 설치 금지 (libvirt cgroup 드라이버가 바뀜).
- `/run/libvirt`를 호스트와 분리(파드 내부 전용)하는 방향의 변경 금지.
- 데이터 추출 완료 신호 전 `make down` 금지.

---

## 7. 현재 상태 / 다음

- **완료**: OSH 2026.1.0 단일 노드 배포, qemu-exporter DaemonSet 배포·검증(G2 통과 — 6지표 정상, 값이
  `virsh domstats`와 0.3% 이내 일치).
- **다음 (실험자 주도, 환경은 §3 지원만)**:
  1. Fig.1 — 메모리 회계 왜곡 스냅샷
  2. Fig.3 — CPU 경합 은폐 시계열 (핵심, §3-4 협조 필요)
  3. Table 1 / 정확도 / 오버헤드
  4. 데이터 노드 밖 복사 → `make down`
- 세부 실행 절차는 qemu-exporter 레포의 `paper_data_tdl.md`, 환경 검증 이력은 `aws_verification_tdl.md`.
