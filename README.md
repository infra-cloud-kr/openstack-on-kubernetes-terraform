# OpenStack on Kubernetes

AWS EC2 한 대 위에 단일 노드 Kubernetes 와 OpenStack-Helm 컴퓨트 코어를 배포하고,
CirrOS 가상머신 부팅까지 end-to-end 로 검증하는 실습 학습 환경이다.

![license](https://img.shields.io/badge/license-Apache--2.0-blue)
![OpenStack-Helm](https://img.shields.io/badge/OpenStack--Helm-2026.1.0-red)
![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326ce5)

- **OpenStack-Helm 2026.1.0** 컴퓨트 코어 — Keystone · Glance · Nova · Neutron · Placement
- **Kubernetes 1.34** + Calico, Ubuntu 24.04(Noble)
- 단일 노드, **Terraform + SSM + Makefile** 로 전 과정 코드화(IaC)
- SSH 없이 **SSM Session Manager** 로만 접근

## 왜 이렇게 만들었나

프로덕션급 OpenStack 을 깔려는 게 아니다. VM 하나를 띄우는 최소 경로 — 컴퓨트 코어 —
가 Kubernetes 위에서 어떻게 도는지 한 대로 끝까지 눈으로 보려는 학습용 랩이다.
끝까지 돌리면 OpenStack-Helm 이 각 컴포넌트를 K8s 리소스(Deployment · DaemonSet ·
StatefulSet)로 어떻게 올리는지, CirrOS VM 부팅이 Keystone → Glance → Nova → Neutron →
Placement 로 어떻게 흐르는지 이해하게 된다.

설계 선택마다 이유가 있다:

- **단일 노드** — 컨트롤 플레인과 데이터 플레인을 한 노드에 함께 올려 최소 비용으로
  end-to-end 흐름만 확인한다. HA·다중 노드 같은 프로덕션 요소는 일부러 뺐다.
- **SSM 만, SSH 없이** — SSH 키 관리와 보안 그룹 22번 개방 없이 접근한다. 자격증명
  노출면을 줄이는 의도적 선택이다.
- **m5.2xlarge (8 vCPU / 32GB)** — OSH 가 컴퓨트 코어 풀스택에 권장하는 최소 사양과
  정확히 일치한다. 더 작으면 파드가 안 뜨고, 더 크면 과금만 는다.
- **Terraform + Makefile** — 생성부터 정리까지 전 과정을 코드로 두어 한 줄 명령으로
  재현하고, 실습이 끝나면 흔적 없이 내린다.

## 빠른 시작

```bash
make init           # 최초 1회 세팅
make up             # EC2 + VPC 생성 (~2분)
make ready          # K8s 부트스트랩 완료 대기 (~3분)
make osh-deploy     # OpenStack-Helm 풀스택 배포 (~20분)
make osh-vm         # CirrOS VM 부팅으로 검증 (~3분)
make down           # 끝나면 반드시 실행
```

`make help` 로 전체 타겟을 확인한다.

> **비용 경고.** m5.2xlarge 기준 한 사이클(~1시간)이 약 $0.8 다. 인스턴스를 안 내리면
> 하루 약 $12씩 쌓인다. 실습이 끝나면 반드시 `make down` 으로 내린다 

## 저장소 구조

```
.
├── Makefile                # 단축 명령: make up / down / osh-deploy / osh-vm 등
├── terraform/              # AWS 인프라 (VPC · IAM · EC2 · user_data)
│   ├── ec2.tf              #   m5.2xlarge, Ubuntu 24.04(Noble), 100 GB gp3
│   └── user_data.sh        #   부팅 시 K8s 1.34 + Calico + helm 자동 설치
└── osh/                    # OpenStack-Helm 배포 (노드에서 실행)
    ├── deploy.sh           #   OSH 2026.1.0 컴퓨트 코어 풀스택 설치 (~20분)
    └── cirros-boot.sh      #   CirrOS VM 부팅으로 검증 (~3분)
```

## 라이선스

Apache License 2.0 — [LICENSE](LICENSE) 참고.
