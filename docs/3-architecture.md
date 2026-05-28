# 3. K8s와 OpenStack은 어떻게 연계돼 있나

OpenStack-Helm의 한 줄 요약: **"모든 OpenStack 컴포넌트를 K8s 리소스 — Deployment / DaemonSet / StatefulSet / Job — 로 띄운다."** 이 장은 실제로 떠 있는 것들을 분류해서 큰 그림을 그립니다 (모두 `openstack` 네임스페이스).

## 3.1 큰 그림

| K8s 리소스 종류 | 무엇을 띄우나 | 개수 (이 랩) |
|---|---|---|
| **Deployment** | 상태 없는 컨트롤 플레인 API/스케줄러/컨덕터 | 11 |
| **DaemonSet** | 컴퓨트 노드에 1:1로 박혀야 하는 데이터 플레인 (hypervisor agent, network agent, OVS) | 8 |
| **StatefulSet** | 영구 상태가 있는 인프라 (DB, MQ, 캐시) | 3 |
| **Job** | 일회성 부트스트랩 (DB 스키마, keystone에 user/endpoint 등록) | ~38 |

(`kubectl -n openstack get {deploy,ds,sts,jobs}` 로 자기 클러스터 숫자 확인)

## 3.2 컨트롤 플레인 — Deployment

상태 없음, 어느 노드에 떠도 됨, 보통 1 replica (HA 구성 시 늘림). `openstack-control-plane=enabled` 라벨이 붙은 노드에 떠요.

| 서비스 | Deployment | 역할 |
|---|---|---|
| **Keystone** | `keystone-api` | identity / 토큰 발급. 모든 다른 서비스의 인증 기반 |
| **Glance** | `glance-api` | 이미지 저장/조회 (PVC `glance-images`에 qcow2 보관) |
| **Nova** | `nova-api-osapi` | 사용자가 치는 `openstack server ...` 받음 |
|  | `nova-api-metadata` | VM 안에서 169.254.169.254로 호출하는 메타데이터 서버 |
|  | `nova-conductor` | DB 접근 중개 (compute → DB 직접 X) |
|  | `nova-scheduler` | 어느 하이퍼바이저에 VM을 배치할지 결정 |
|  | `nova-novncproxy` | 브라우저에서 VM 콘솔 접속 |
| **Neutron** | `neutron-server` | network/subnet/port API |
|  | `neutron-rpc-server` | 에이전트들과의 RPC 분리 (성능용) |
| **Placement** | `placement-api` | 리소스 인벤토리/할당 (Nova가 빈 자리를 placement에 묻고 답을 받음) |
| (MariaDB) | `mariadb-controller` | MariaDB Galera 상태 머신 컨트롤러 |

## 3.3 데이터 플레인 — DaemonSet

노드에 1:1로 박혀야 하는 것 (가상화 호스트, OVS 브리지, 네트워크 에이전트). 라벨 셀렉터로 어느 노드에 띄울지 결정 — 우리 랩은 단일 노드라 모두 같은 노드에 1개씩.

| DaemonSet | 라벨 셀렉터 | 역할 |
|---|---|---|
| `libvirt-libvirt-default` | `openstack-compute-node=enabled` | QEMU/KVM hypervisor 데몬. host `/var/lib/libvirt` 마운트 |
| `nova-compute-default` | `openstack-compute-node=enabled` | nova-compute (libvirt와 대화해 실제 VM 띄움) |
| `openvswitch` | `openvswitch=enabled` | OVS vswitchd + ovsdb-server. br-int / br-ex 생성 |
| `neutron-ovs-agent-default` | `openvswitch=enabled` | VM port가 만들어지면 OVS에 attach |
| `neutron-l3-agent-default` | `l3-agent=enabled` | 가상 라우터 (네트워크 간 라우팅) |
| `neutron-dhcp-agent-default` | `dhcp-agent=enabled` | VM에 IP 할당 (dnsmasq) |
| `neutron-metadata-agent-default` | `metadata-agent=enabled` | VM의 169.254.169.254 요청을 nova-api-metadata로 프록시 |
| `neutron-netns-cleanup-cron-default` | (compute) | 좀비 netns 정리 cron |

`osh/deploy.sh` Step 5에서 노드에 다음 라벨을 모두 박아 단일 노드가 컨트롤+데이터 플레인 역할을 동시에 합니다:

```
openstack-control-plane, openstack-compute-node,
openvswitch, linuxbridge, ovs-host,
l3-agent, dhcp-agent, metadata-agent
```

## 3.4 인프라 의존성 — StatefulSet

영구 상태가 있고 ordering이 중요한 인프라.

| StatefulSet | 역할 | 누가 의존하나 |
|---|---|---|
| `mariadb-server` | OpenStack의 모든 메타데이터 DB | 거의 모든 서비스 |
| `rabbitmq-rabbitmq` | RPC 메시지 큐 (oslo.messaging) | nova / neutron / placement / glance 에이전트들 |
| `memcached-memcached` | keystone 토큰 캐시 | keystone (성능) |

## 3.5 Jobs — 일회성 부트스트랩

OpenStack은 "DB가 비어있으면 스키마부터 만들어야" 하고 "keystone에 자기 자신을 등록"해야 돌아갑니다. OSH는 이걸 모두 K8s Job으로 만들어요:

| Job 이름 패턴 | 무엇을 |
|---|---|
| `*-db-init`, `*-db-sync` | DB 사용자 생성, 스키마 마이그레이션 |
| `*-rabbit-init` | RabbitMQ 사용자/vhost 생성 |
| `*-ks-user`, `*-ks-service`, `*-ks-endpoint` | keystone에 user / service / endpoint 등록 |
| `keystone-fernet-setup`, `keystone-credential-setup` | 토큰 서명 키 만들기 |
| `nova-bootstrap`, `nova-cell-setup` | placement에 hypervisor 등록 대기 + nova cell 초기화 |
| `glance-metadefs-load` | glance metadata definitions |

`kubectl -n openstack get jobs` 했을 때 `Completions 1/1`이면 성공 → 두 번 다시 안 돕니다.

## 3.6 자격증명 흐름

각 서비스가 keystone에 admin으로 호출할 때 쓸 자격증명을 Secret으로 보관합니다.

```
secret/keystone-keystone-admin   ← 진짜 cloud admin
secret/glance-keystone-admin
secret/neutron-keystone-admin
secret/nova-keystone-admin
secret/placement-keystone-admin
```

`keystone-keystone-admin` Secret이 들고 있는 키 (그대로 OpenStack CLI 환경변수):
```
OS_AUTH_URL  OS_USERNAME  OS_PASSWORD  OS_PROJECT_NAME
OS_PROJECT_DOMAIN_NAME  OS_USER_DOMAIN_NAME  OS_DEFAULT_DOMAIN
OS_REGION_NAME  OS_INTERFACE
```

`osc` 파드의 Pod spec에 다음이 있어서 `openstack` CLI를 별다른 source 없이 바로 쓸 수 있는 거예요:
```yaml
envFrom:
- secretRef:
    name: keystone-keystone-admin
```

(`osh/cirros-boot.sh` 12-27행 참조)

## 3.7 서비스 디스커버리 — K8s Service + cluster.local

`openstack endpoint list`에 나오는 URL은 전부 K8s Service FQDN입니다:

```
keystone     public    http://keystone.openstack.svc.cluster.local
keystone     internal  http://keystone-api.openstack.svc.cluster.local:5000/v3
nova         public    http://nova.openstack.svc.cluster.local/v2.1/%(tenant_id)s
neutron      public    http://neutron.openstack.svc.cluster.local
glance       public    http://glance.openstack.svc.cluster.local
placement    public    http://placement-api.openstack.svc.cluster.local:8778/
```

즉 **서비스 간 통신은 모두 K8s in-cluster DNS**. 클러스터 밖에서 부르려면 ingress / NodePort 필요한데 이 랩은 학습용이라 안 깔았어요 (자세한 건 [7장](7-design-decisions.md) 참조).

## 3.8 스토리지

| 컴포넌트 | StorageClass | 크기 | 용도 |
|---|---|---|---|
| `glance-images` PVC | `general` | 2Gi | 업로드된 OS 이미지 (qcow2) |
| MariaDB PV | `local-path` | (chart 기본) | DB 데이터 |
| RabbitMQ PV | `local-path` | (chart 기본) | MQ 상태 |

둘 다 실제 provisioner는 같은 `rancher.io/local-path`. 차트가 `class_name: general`이라고 하드코딩해놓은 게 있어서 같은 provisioner를 가리키는 alias `general`을 추가로 만들어 둔 거예요 ([5.5 함정](5-troubleshooting.md#54-함정-5가지-원인과-해결) #2).

## 3.9 가상화 / 네트워크 흐름

VM이 부팅될 때 일어나는 일:

```
사용자 → openstack server create
  └→ nova-api → nova-conductor → nova-scheduler (어느 hypervisor?)
                                      ↓ (placement에 질의)
                                  placement-api
                                      ↓ (정답)
                            nova-compute (선택된 노드의 DaemonSet)
                                      ↓ (libvirtd에 명령)
                              libvirt DaemonSet
                                      ↓
                                QEMU 프로세스 (= VM)
                                      ↓ (네트워크 port 필요)
                              neutron-server (Deployment, API)
                                      ↓ (port 만들고 IP 할당)
                          neutron-dhcp-agent / ovs-agent (DaemonSet)
                                      ↓ (OVS에 attach)
                                  br-int (OVS)
                                      ↓ (외부 통신은)
                                  br-ex → provider1 (dummy)
```

- **br-int** = integration bridge. 모든 VM port가 여기 묶임
- **br-ex** = external bridge. tenant network → 외부로 나가는 출구
- **provider1** = host NIC라야 정상이지만, 단일 노드 랩이라 `ip link add provider1 type dummy`로 가짜 인터페이스. neutron `auto_bridge_add: br-ex: provider1` 만족시키는 용도
- **QEMU 모드 (nested KVM 아님)** — m5 인스턴스는 nested KVM 불가라 `virt_type=qemu` 소프트웨어 에뮬레이션. 컴퓨트가 CPU 많이 먹는 이유

---

다음 → [4. OpenStack 이용 (놀이터)](4-using-openstack.md)
