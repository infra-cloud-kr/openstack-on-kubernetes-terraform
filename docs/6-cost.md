# 6. 운영 — 비용과 사이즈

## 6.1 비용 안 잊는 팁

```bash
# AWS Console에서 Billing & Cost Management → Cost Anomaly Detection으로
# "OpenStack lab" 알람 설정 (5달러 초과 시 메일).
# 또는 가장 단순하게 — 매번 실습 끝나면 alias로:
alias osh-down='cd /Users/eundms/openstack-aws && make down'
```

`make down`은 멱등 — 노드가 이미 destroy 됐어도 안전하게 "0 destroyed"로 마무리. 의심나면 그냥 한 번 더 돌려도 OK.

## 6.2 AWS 인스턴스 선택지

ap-northeast-2 (Seoul) 기준, 시간당 가격 (on-demand). EBS 100GB gp3는 모두 동일하게 **시간당 ≈$0.014** (월 ~$10) 추가됩니다.

| 인스턴스 | vCPU / RAM | $/hr | 1시간 풀스택 비용 (EBS 포함) | 비고 |
|---|---|---|---|---|
| `t3.xlarge` | 4 / 16 GB | ~$0.21 | ~$0.22 | RAM 부족. mariadb + rabbit + nova/neutron까지만 빠듯 |
| `m5.xlarge` | 4 / 16 GB | ~$0.24 | ~$0.25 | OSH CI 1node와 동일. 풀스택은 OOM 위험 |
| **`m5.2xlarge`** ← 권장 가성비 | **8 / 32 GB** | **~$0.48** | **~$0.49** | **OSH의 1node-32GB nodeset과 정확히 매칭** |
| `t3.2xlarge` | 8 / 32 GB | ~$0.33 | ~$0.34 | burst CPU 제약. 컴포넌트 install 시 CPU credit 소진 가능 |
| **`m5.4xlarge`** ← 이 랩 현재 | **16 / 64 GB** | **~$0.96** | **~$0.97** | 여유 있음. 풀스택 + 여러 VM + 옵션 컴포넌트도 |
| `c5.4xlarge` | 16 / 32 GB | ~$0.85 | ~$0.86 | CPU 강함, RAM은 m5.2xlarge와 같음 |

추가 비용:
- **VPC / IGW**: 무료 (NAT Gateway 만들지 않음, IGW만)
- **Egress 대역폭**: 1 GB/월 무료 후 ~$0.126/GB. 한 번 풀스택 띄우면 컨테이너 이미지 다운로드 ~2-3 GB → **~$0.3-0.4**
- **SSM Session Manager**: 무료 (CloudWatch Logs 안 켜는 한)
- **Public IP**: 시간당 ~$0.005 (2024년 이후 모든 IPv4 public IP에 부과)

## 6.3 시나리오별 한 사이클 비용

| 인스턴스 | 시간 | EC2 | EBS | Egress | 합계 |
|---|---|---|---|---|---|
| m5.2xlarge | 1 hr | $0.48 | $0.014 | ~$0.3 | **~$0.8** |
| **m5.4xlarge** (현재) | 1 hr | $0.96 | $0.014 | ~$0.3 | **~$1.3** |
| m5.2xlarge | 24 hr (잊고 안 내림) | $11.5 | $0.34 | ~$0.3 | **~$12** |
| m5.4xlarge | 24 hr | $23 | $0.34 | ~$0.3 | **~$24** |

> ⚠️ **인스턴스 안 내린 채로 잊으면 하루 $20-$25씩 누적**. `make down`이 인생을 구합니다.

## 6.4 인스턴스 사이즈 바꾸려면

`terraform/variables.tf:9`의 `instance_type` 기본값을 수정하거나 apply 시점에 인자로:
```bash
terraform -chdir=terraform apply -auto-approve -var="instance_type=m5.2xlarge"
```
`terraform plan` 시 EC2가 replace (재생성). 기존 K8s 클러스터 사라지고 새로 부트스트랩됩니다.

## 6.5 OpenStack-Helm 공식 권장 사양

OSH README.rst의 호환성 매트릭스 (2026.1 기준):

| OpenStack release | Host OS | Image OS | Kubernetes |
|---|---|---|---|
| 2024.2 (Dalmatian) | Ubuntu Jammy | Ubuntu Jammy | >=1.29, <=1.31 |
| 2025.1 (Epoxy) | Ubuntu Noble | Ubuntu Noble | >=1.30, <=1.32 |
| **2026.1** ← 이 랩 | **Ubuntu Noble** | **Ubuntu Noble** | **1.34** (이 랩 실측) |

이 랩은 Noble(24.04) AMI + K8s 1.34 + OSH `2026.1.0` 조합입니다. 2025.2부터 CI가 `ubuntu_noble` (24.04) 기반으로 이전됐고, 노드 OS·OSH tag·K8s 버전을 모두 그에 맞췄어요 (`osh/deploy.sh`의 `FEATURES="2026.1 ubuntu_noble"`, `terraform/ec2.tf`의 `ubuntu-noble-24.04` AMI). 위 매트릭스의 2025.1 행 등 정확한 K8s 범위는 OSH README.rst를 직접 확인하세요.

OSH CI의 `zuul.d/nodesets.yaml`에서 추정한 hardware 베이스라인:

| CI nodeset | 노드 수 | 노드 사양 (추정) | 용도 |
|---|---|---|---|
| `openstack-helm-1node-ubuntu_jammy` | 1 | 8 vCPU / 16GB | 가벼운 단일 차트 테스트 |
| **`openstack-helm-1node-32GB-ubuntu_jammy`** | **1** | **8 vCPU / 32GB** | 풀스택 단일 노드 |
| `openstack-helm-3nodes-ubuntu_jammy` | 3 | 각 8 vCPU / 16GB | 분산 |
| `openstack-helm-5nodes-ubuntu_jammy` | 5 | 각 8 vCPU / 16GB | Ceph 포함 풀스택 |

즉 **단일 노드에 컴퓨트 코어 풀스택을 띄울 거면 8 vCPU / 32GB가 OSH 측 권장 최소선**. nested KVM이 안 되는 클라우드 VM에서는 QEMU 소프트웨어 에뮬레이션이라 CPU 여유가 더 필요해요.

---

다음 → [7. 디자인 결정 메모](7-design-decisions.md)
