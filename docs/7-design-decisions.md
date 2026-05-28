# 7. 디자인 결정 메모

이 랩이 왜 지금 모양인지 — 4가지 선택 이유.

## 7.1 SSH 막힘, SSM Session Manager만 사용

**왜**: 한국 ISP의 outbound 22 차단 이슈 회피. 그리고 SSH 키 관리·rotation을 안 해도 됨.
**어떻게**: EC2에 SSM 호환 IAM 역할 부여(`AmazonSSMManagedInstanceCore`), 노드에 amazon-ssm-agent 사전 설치(Ubuntu AMI에 기본 포함). 모든 노드 명령은 `aws ssm send-command` 또는 `aws ssm start-session`을 통해.
**결과**: 보안그룹 ingress가 완전 비어 있음 (egress만 열림). VPC에 NAT Gateway도 없음.

## 7.2 `m5.4xlarge` (16 vCPU / 64 GB) 사용

**왜**: OSH 풀스택은 무겁고, m5는 nested KVM이 안 되니 nova 안에서 `virt_type=qemu` 소프트웨어 에뮬레이션이라 컴퓨트도 CPU를 많이 먹어요. OSH가 공식 권장하는 1node-32GB nodeset과 동등한 `m5.2xlarge`로도 동작은 하지만, 여러 VM을 동시에 띄우거나 옵션 차트(heat/cinder/horizon)를 얹으려면 부족.
**결과**: 약 시간당 $0.97 (EBS 포함). 비용 자세히는 [6장](6-cost.md).
**바꾸려면**: `terraform/variables.tf:9` 또는 `-var="instance_type=..."`.

## 7.3 OSH는 release tag `2024.2.0`에 고정

**왜**:
- 옛 자료의 `stable/2024.1` 브랜치는 이미 삭제됨. 현재는 master/edge 두 갈래 + release tag만 남음
- OSH 2025.2 이상은 `ubuntu_noble` (24.04)만 CI에서 테스트. Ubuntu 22.04 (Jammy) 노드와 호환 안 됨
- Ubuntu 22.04 (Jammy) + K8s 1.29 조합에 맞는 가장 최근 안정 태그가 2024.2.0

**바꾸려면**: `osh/deploy.sh:13` `OSH_REF`, 그리고 노드 OS도 함께 Noble로.

## 7.4 Ingress / MetalLB / Ceph 모두 생략

**왜**: 학습용 단일 노드라 외부 노출이 필요 없고, 클러스터 안에서 `osc` 파드로 모든 검증이 됨.
- **Ingress 안 깔음**: OSH가 만드는 public Service들(keystone, nova, neutron 등)은 ClusterIP라 클러스터 밖에서 직접 못 부름. 안에서 `kubectl exec osc -- openstack ...`로 호출.
- **MetalLB 안 깔음**: LoadBalancer 타입 Service를 EXTERNAL-IP에 묶을 일이 없음.
- **Ceph 안 깔음**: glance 이미지 저장소는 PVC + `local-path-provisioner`로 충분. cinder/manila처럼 분산 스토리지가 필요한 컴포넌트는 안 깔았어요.
**부작용**: 함정 #2(StorageClass alias)와 #3(metadata Service patch)이 생김 — [5.4](5-troubleshooting.md#54-함정-5가지-원인과-해결) 참조.

## 7.5 K8s API server / kubelet 외부 노출 없음

**왜**: SSH도 안 열어둔 마당에 K8s API를 열 이유가 없음. kubeconfig 유출 위험만 늘림.
**결과**: 모든 검증은 노드 안에서 `kubectl` 또는 임시 `osc` 파드를 통해. 로컬에서 직접 `kubectl`로 클러스터를 못 부름.
**그래도 로컬에서 kubectl 쓰고 싶으면**: SSM port-forward로 6443 터널링하거나, kubeconfig를 SSM으로 받아 server 주소를 `https://localhost:6443`으로 바꾸고 위와 같이 터널.

---

← [README](../README.md)
