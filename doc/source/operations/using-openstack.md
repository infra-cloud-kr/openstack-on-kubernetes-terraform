# OpenStack 이용

설치와 검증이 끝났으면 직접 명령을 실행하면서 익숙해진다.

## 진입

```bash
make ssm                                            # 노드 셸
sudo -i
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl -n openstack exec -it osc -- bash           # osc 파드 셸로 진입
# 이 안에서 openstack ... 자유롭게
```

`osc` 파드가 admin 자격증명을 어떻게 받는지는 [자격증명 흐름](../architecture/overview.md) 참조.

나가기: `exit` 3번 (osc → 노드 root → SSM 세션).

## ① 둘러보기 (read-only)

```bash
openstack catalog list                           # 사용 가능한 모든 서비스 + 엔드포인트
openstack server show test-vm                    # 기존 VM 상세
openstack console log show test-vm | tail -30    # cirros 부팅 로그 — "login:" 보이면 게스트 OS 부팅 성공
openstack flavor list                            # 5가지 사이즈 (m1.tiny ~ m1.xlarge)
openstack image show cirros                      # 이미지 메타데이터
openstack project list                           # admin, service
openstack user list
```

## ② 두 번째 VM 띄우기

```bash
NET_ID=$(openstack network show demo-net -f value -c id)
openstack server create --flavor m1.tiny --image cirros --nic net-id=$NET_ID vm2
watch -n 2 openstack server list                 # BUILD → ACTIVE 로 전환되는 것을 확인 (Ctrl-C로 종료)
```

## ③ 파워 상태 조작

```bash
openstack server stop  vm2
openstack server list                            # SHUTOFF
openstack server start vm2
openstack server list                            # ACTIVE
openstack server reboot vm2 --hard
```

## ④ 사용자 정의 네트워크 만들기

```bash
openstack network create my-net
openstack subnet  create --network my-net --subnet-range 10.20.20.0/24 my-subnet
openstack network list
openstack subnet  list
```

## ⑤ 정리

```bash
openstack server  delete vm2
openstack subnet  delete my-subnet
openstack network delete my-net
```

## ⑥ 도움말

```bash
openstack --help | less                          # 전체 명령 카테고리
openstack server --help                          # server 서브명령
openstack server create --help                   # 옵션
```

## ERROR가 나면

VM이 ACTIVE 안 되고 ERROR로 끝나면:
```bash
openstack server show vm2 -f value -c fault
# 노드 root 셸에서
kubectl -n openstack logs -l application=nova,component=compute --tail=50
```

흔한 원인:
- 하이퍼바이저 자원 부족 → flavor RAM/disk 더 작게
- neutron 포트 생성 실패 → `openstack network agent list` 에서 Alive 가 아닌 에이전트가 있는지 확인

더 자세한 트러블슈팅은 [트러블슈팅](troubleshooting.md) 참조.
