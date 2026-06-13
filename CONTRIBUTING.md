# 기여 가이드

이 프로젝트(단일 노드 OpenStack-on-Kubernetes 랩)에 기여하는 방법을 정리한다.
문서(Sphinx) 작성·빌드 규칙은 별도로 [문서 기여 가이드](doc/source/contributing.md)를 참고한다.

## 저장소 구성

- `terraform/` — AWS 인프라(VPC, EC2, IAM/SSM 등). 노드 부팅 시 `user_data.sh` 가
  K8s + Calico + helm 을 설치한다.
- `osh/` — 노드에서 실행되는 OpenStack-Helm 배포(`deploy.sh`)와 CirrOS 부팅
  검증(`cirros-boot.sh`).
- `Makefile` — `make up / ready / status / osh-deploy / osh-vm / down` 등 단축 명령.
- `doc/` — Sphinx 문서.

## 개발 환경

로컬 도구는 [설치 문서](doc/source/getting-started/install.md)에 정리되어 있다
(`awscli`, `terraform`, `session-manager-plugin`, `jq`, `make`). AWS 자격증명과
ap-northeast-2 리전 접근 권한이 필요하다.

## 변경을 검증하는 법

인프라·OSH 스크립트를 바꿨다면 실제 한 사이클을 돌려 확인한다.

```bash
make up             # EC2 + VPC 생성
make ready          # K8s 부트스트랩 완료 대기 (K8S_READY)
make osh-deploy     # OpenStack-Helm 풀스택 (~20분)
make osh-vm         # CirrOS VM 부팅 검증
make down           # 반드시 정리
```

> ⚠️ 검증이 끝나면 **반드시 `make down`** 으로 리소스를 내린다. 인스턴스를 켜둔 채로
> 두면 시간당 과금이 누적된다(비용은 [비용 문서](doc/source/operations/cost.md) 참고).

## 코드 규칙

- **Terraform**: PR 전에 `make fmt`(= `terraform fmt -recursive`)와
  `make validate`(= `terraform validate`)를 통과시킨다. 변수 기본값을 바꿀 때는
  근거를 주석으로 남긴다.
- **셸 스크립트**(`osh/*.sh`, `user_data.sh`): 멱등(idempotent)하게 유지한다 —
  이미 적용된 리소스는 건너뛰고, 다시 실행해도 안전해야 한다.
- 버전(OSH / K8s / Ubuntu)을 바꿀 때는 `osh/deploy.sh` 의 `OSH_REF`,
  `terraform/user_data.sh` 의 `K8S_MINOR`, `terraform/ec2.tf` 의 AMI 필터를 함께
  맞추고 OSH 지원 매트릭스 범위 안에 있는지 확인한다.

## Pull Request

- 한 PR 은 하나의 논리적 변경에 집중한다.
- 인프라/OSH 변경은 위 사이클로 검증한 결과를 PR 설명에 적는다.
- 문서를 함께 수정했다면 `tox -e docs` 가 통과하는지 확인한다.
