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

## 빠른 시작

```bash
make init           # 최초 1회 세팅
make up             # EC2 + VPC 생성 (~2분)
make ready          # K8s 부트스트랩 완료 대기 (~3분)
make osh-deploy     # OpenStack-Helm 풀스택 배포 (~20분)
make osh-vm         # CirrOS VM 부팅으로 검증 (~3분)
make down           # 끝나면 반드시 실행
```

`make help` 로 전체 타겟을 확인한다. 처음이면 [설치](doc/source/getting-started/install.md)부터
따라가고, 막히면 [트러블슈팅](doc/source/operations/troubleshooting.md)을 본다.

## 문서

문서는 `doc/source/` 에 Markdown(MyST)으로 작성하고 Sphinx 로 빌드해 GitHub Pages 로
배포한다. 빌드·작성 방법은 [문서 기여 가이드](doc/source/contributing.md)를 참고한다.

| 문서 | 내용 |
|---|---|
| [설치](doc/source/getting-started/install.md) | 로컬 도구 · AWS 자격증명 · 한 줄 사이클 |
| [설치 확인](doc/source/getting-started/verify.md) | 노드 접속 · `KUBECONFIG` · 3계층 점검 |
| [아키텍처](doc/source/architecture/overview.md) | K8s 리소스 매핑 · 서비스 디스커버리 · VM 부팅 흐름 (다이어그램) |
| [OpenStack 이용](doc/source/operations/using-openstack.md) | `openstack` CLI 로 VM·네트워크 다루기 |
| [트러블슈팅](doc/source/operations/troubleshooting.md) | 에러 치트시트 · 진행 추적 · 함정과 해결 |
| [비용](doc/source/operations/cost.md) | 한 사이클 비용 · 비용 관리 · 권장 사양 |

## 저장소 구조

```
.
├── Makefile                # 단축 명령: make up / down / osh-deploy / osh-vm 등
├── terraform/              # AWS 인프라 (VPC · IAM · EC2 · user_data)
│   ├── ec2.tf              #   m5.2xlarge, Ubuntu 24.04(Noble), 100 GB gp3
│   └── user_data.sh        #   부팅 시 K8s 1.34 + Calico + helm 자동 설치
├── osh/                    # OpenStack-Helm 배포 (노드에서 실행)
│   ├── deploy.sh           #   OSH 2026.1.0 컴퓨트 코어 풀스택 설치 (~20분)
│   └── cirros-boot.sh      #   CirrOS VM 부팅으로 검증 (~3분)
└── doc/                    # 문서 (Markdown + Sphinx, tox -e docs 로 빌드)
```

## 라이선스

Apache License 2.0 — [LICENSE](LICENSE) 참고.
