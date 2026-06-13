# 비용

## 비용은 얼마나 나오나

이 랩(m5.2xlarge, ap-northeast-2 기준)을 한 번 띄웠다 내리는 한 사이클(~1시간) 비용이다.

| 항목 | 비용 |
|---|---|
| EC2 (m5.2xlarge) | 시간당 ~$0.48 |
| EBS (100GB gp3) | 시간당 ~$0.014 (월 ~$10) |
| Egress (이미지 다운로드 ~2-3 GB) | 한 사이클 ~$0.3 |
| **한 사이클(~1시간) 합계** | **~$0.8** |

VPC / IGW 와 SSM Session Manager 는 무료다(NAT Gateway 를 만들지 않고 IGW 만 쓰며, CloudWatch Logs 를 켜지 않는 한). Public IP 만 시간당 ~$0.005 추가된다.

```{warning}
인스턴스를 안 내린 채로 잊으면 하루 ~$12씩 누적된다. 끝나면 반드시 `make down`.
```

## 비용 안 잊는 법

`make down` 은 멱등이라 노드가 이미 destroy 됐어도 안전하게 "0 destroyed" 로 마무리한다. 의심나면 한 번 더 실행해도 된다.

```bash
# 매번 실습 끝나면 alias 로 한 번에:
alias osh-down='cd /Users/eundms/openstack-aws && make down'
```

추가로 AWS Console → Billing & Cost Management → Cost Anomaly Detection 에서 알람(예: 5달러 초과 시 메일)을 걸어두면 잊어도 안전하다.

## 참고 — OpenStack-Helm 공식 권장 사양

단일 노드에 컴퓨트 코어 풀스택을 띄우려면 **8 vCPU / 32GB** 가 OSH 측 권장 최소선이다(OSH CI 의 `1node-32GB` nodeset 기준). 이 랩은 이 최소선과 정확히 일치하는 m5.2xlarge(8 vCPU / 32GB)를 기본으로 쓴다 — 컴퓨트 코어 풀스택 + CirrOS VM 부팅까지 정상 동작을 확인했다. nested KVM 이 안 되는 클라우드 VM 이라 QEMU 소프트웨어 에뮬레이션을 쓰지만, 풀스택 실사용 메모리는 ~8GB 수준이라 32GB 로 충분하다. 여러 VM 을 동시에 띄우거나 옵션 차트(heat/cinder/horizon)를 얹으려면 m5.4xlarge(16 vCPU / 64GB)로 올린다.

- OpenStack release ↔ Host OS ↔ Kubernetes 호환성 매트릭스와 CI nodeset 사양은 [OpenStack-Helm README](https://opendev.org/openstack/openstack-helm) 에서 확인한다.
- 인스턴스 사이즈는 `terraform/variables.tf` 의 `instance_type` 으로 바꾼다(변경 시 EC2 가 재생성된다).
```
