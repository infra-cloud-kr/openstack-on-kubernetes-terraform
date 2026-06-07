# 5. 트러블슈팅

## 5.1 make 단계별 에러 cheatsheet

| 증상 | 원인 / 대처 |
|---|---|
| `make up` 도중 `UnauthorizedOperation` | AWS 자격증명/권한 부족. `aws sts get-caller-identity` 확인, 권한 부여 |
| `make ssm` → `session-manager-plugin not found` | 로컬에 플러그인 미설치. [1.1](1-install.md#11-로컬-도구-macos-apple-silicon-기준) 다시 |
| `make ssm` → `TargetNotConnected` | 노드가 아직 SSM agent를 띄우는 중 (부팅 후 30초쯤). 다시 시도 |
| `make osh-deploy`가 중간에 Failed | [5.3](#53-osh-deploy-중간-실패-시-이어하기) 이어하기 참조 |
| 어떤 pod이 영원히 `Init:0/N` 또는 `0/1 Running` | [5.4](#54-함정-5가지-원인과-해결) 5가지 함정 참조 |
| `openstack server create`가 ERROR | `kubectl -n openstack logs -l application=nova,component=compute --tail=50` 보고, 보통 libvirt/qemu 자원 부족 또는 neutron 포트 생성 실패 |
| 처음부터 깨끗하게 시작 | `make down` → 잠시 후 `make up`. terraform state는 자동 동기화 |

## 5.2 osh-deploy 진행도 확인 (20-30분 동안 어디까지 왔나)

`make osh-deploy`는 SSM run-command로 노드에서 `osh/deploy.sh`를 돌리는데, 로컬 터미널엔 30초마다 status 폴링만 보입니다. 실제 진행 단계는 세 갈래로.

### (1) SSM run-command의 실시간 stdout (set -x trace)

`deploy.sh`는 `set -x`로 켜져 있어서 지금 어느 `helm install`/`kubectl apply` 단계인지 줄 단위로 찍힙니다. `make osh-deploy` 화면의 command-id를 잡아서:

```bash
aws ssm get-command-invocation \
    --command-id <command-id> \
    --instance-id <i-xxxx> \
    --region ap-northeast-2 \
    --query 'StandardOutputContent' --output text | tail -50
```

마지막 줄이 어떤 chart를 깔고 있는지 / 어떤 job을 기다리는지 알려줍니다.

### (2) 노드 안에서 클러스터 상태 (가장 신뢰할 수 있음)

```bash
make ssm
sudo -i
export KUBECONFIG=/etc/kubernetes/admin.conf

helm -n openstack list          # 지금까지 성공한 release
kubectl -n openstack get pods   # 떠 있는 파드
kubectl -n openstack get jobs   # bootstrap job 진행 (Completions 1/1 = 끝)
```

helm list 줄 수가 늘어나는 속도 = 진행 속도. 보통 순서: rabbitmq → mariadb → memcached → keystone → glance → openvswitch → libvirt → placement → nova → neutron. 10개 채워지면 거의 끝.

### (3) 가장 오래 걸리는 단계 — `nova-bootstrap`의 `wait_for_computes`

nova chart의 bootstrap job이 hypervisor(=nova-compute가 placement에 등록되는 것)가 잡힐 때까지 폴링. 여기서 5-10분 잡힙니다. 답답하면:

```bash
kubectl -n openstack get jobs | grep bootstrap
kubectl -n openstack logs job/nova-bootstrap -f --tail=30
# 또는
kubectl -n openstack logs job/keystone-bootstrap --tail=30
```

`nova-compute` 파드가 placement에 등록되면 (`openstack hypervisor list`에 나타나면) bootstrap job이 Succeeded로 빠지고 다음 helm install로 진행.

## 5.3 osh-deploy 중간 실패 시 이어하기

`osh/deploy.sh`는 idempotent하게 짜여 있어요:
- `helm upgrade --install` 사용 — 이미 깔린 release는 그대로
- 노드 라벨, StorageClass, namespace 등 모두 "이미 있으면 skip"
- patch 명령들도 멱등

그래서 그냥 다시 `make osh-deploy`를 호출하면 됩니다. 단, **glance helm release가 `failed` 상태로 박힌 경우**가 가끔 있는데 (post-install hook이 시간 끌리면) 이건 cosmetic이라 무시해도 PVC, pods는 정상.

진짜 깨졌다 싶으면:
```bash
make ssm
sudo -i
export KUBECONFIG=/etc/kubernetes/admin.conf
helm -n openstack uninstall <release-name>     # 막힌 chart만 제거
exit   # 로컬로 나와서
make osh-deploy
```

## 5.4 함정 5가지 (원인과 해결)

이 랩을 만들면서 실제로 부딪힌 것들. 모두 `osh/deploy.sh`와 `terraform/user_data.sh`에 영구 해결 코드가 들어있어요.

### #1 `helm osh` 플러그인이 다음 SSM 호출에서 사라짐
**원인**: SSM run-command 셸이 `HOME=''`로 시작. helm은 `$HOME/.local/share/helm/plugins`를 보는데 비어있으면 cwd 기준으로 보게 됨 → 매번 다른 디렉토리.
**해결**: 노드에서 도는 모든 스크립트가 첫줄에 `export HOME=/root`. → `osh/deploy.sh:9`.

### #2 OSH의 `glance-images` PVC가 영원히 Pending
**원인**: glance 차트의 `volume.class_name=general`인데 클러스터 default StorageClass는 `local-path`.
**해결**: `general`이라는 이름으로 같은 provisioner(rancher.io/local-path)를 가리키는 StorageClass 추가. → `osh/deploy.sh` Step 4.

### #3 `neutron-metadata-agent`가 Init:0/2에서 영원히 멈춤
**원인**: 차트의 init dependency가 Service `metadata`를 기다리는데, 그 Service의 selector는 `{app: ingress-api}`이고 ports는 80/443. 우리 클러스터엔 ingress 컨트롤러가 없어 selector match 없음 → endpoints 비어 있음.
**해결**: Service `metadata`의 selector를 `nova-api-metadata` 파드에 매치하도록 patch + targetPort를 8775로. → `osh/deploy.sh` Step 14.

### #4 `nova-compute` / `neutron-l3-agent` / `neutron-dhcp-agent` DaemonSet이 0/1 Running으로 영원히
**원인**: `health-probe.py`가 `oslo.messaging`으로 RabbitMQ 호스트네임을 resolve 시도하는데 pod DNS 환경에서 timeout (`Name or service not known`). **실제 프로세스는 정상** — placement에 hypervisor 등록, neutron 에이전트 등록 다 잘 동작.
**해결**: 세 DaemonSet에서 `startupProbe`/`readinessProbe`/`livenessProbe` 모두 제거하고 rollout restart. → `osh/deploy.sh` Step 15.

### #5 옛 user_data 주석의 stable 브랜치를 더 이상 안 함
**원인**: opendev.org/openstack/openstack-helm의 `stable/2024.1` 브랜치 자체가 삭제됨. master/edge 두 갈래 + release tag만 남음.
**해결**: release tag (`2026.1.0`)로 clone. → `osh/deploy.sh` Step 1.

### #6 (보너스) baltocdn helm apt 저장소의 키 응답이 비어 옴
**원인**: 옛 `helm` 설치 가이드들은 `https://baltocdn.com/helm/signing.asc`를 apt-key로 받는데, 이 엔드포인트가 빈 응답을 줘서 `gpg --dearmor`가 "no valid OpenPGP data" 실패.
**해결**: 공식 `https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3` 스크립트로 설치. → `terraform/user_data.sh` 6b 단계.

---

다음 → [6. 운영 — 비용과 사이즈](6-cost.md)
