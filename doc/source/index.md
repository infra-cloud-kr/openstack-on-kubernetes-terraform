# OpenStack-on-Kubernetes 싱글노드 랩 문서

이 문서는 AWS EC2 한 대 위에 단일 노드 Kubernetes 클러스터를 만들고, 그 위에
**OpenStack-Helm 2026.1.0** 컴퓨트 코어(Keystone·Glance·Nova·Neutron·Placement)를
배포하여 CirrOS VM 부팅까지 도달하는 실습 랩을 다룬다. 모든 과정은
Terraform + SSM + Makefile 로 코드화(IaC)되어 있다.

```{note}
이 저장소는 infra-cloud-kr/openstack-kubernetes 의 빌드/배포 관례를 따라 Sphinx
로 빌드하고 GitHub Actions 로 GitHub Pages 에 배포한다. 다만 본문은 rST 대신
**Markdown(MyST)** 으로 작성한다. 빌드 방법은 [기여 가이드](contributing.md) 참고.
```

```{toctree}
:maxdepth: 2

getting-started/index
architecture/index
operations/index
contributing
```
