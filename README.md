# OpenStack on Kubernetes

**English** | [한국어](README.ko.md)

A hands-on learning environment that deploys Kubernetes and OpenStack-Helm (Keystone, Nova, Neutron, Glance) on a single AWS EC2 instance, validated end-to-end by successfully booting a CirrOS virtual machine.

## Quick start

```bash
make init           # one-time setup
make up             # create EC2 + VPC (~2 min)
make ready          # wait for K8s bootstrap to finish (~3 min)
make osh-deploy     # full OpenStack-Helm stack (~20 min)
make osh-vm         # validate by booting a CirrOS VM (~3 min)
make down           # always run when you're done
```

What each command does exactly, and where to look when you get stuck, is covered in the docs below.

## Documentation

1. [Install](docs/en/1-install.md) — local tools / AWS credentials / the one-line cycle
2. [Verify](docs/en/2-verify.md) — connecting to the node, `KUBECONFIG` explained, the 3-layer check (K8s → OpenStack → end-to-end VM)
3. [How K8s and OpenStack fit together](docs/en/3-architecture.md) — Deployment / DaemonSet / StatefulSet / Job mapping, Service DNS, Secret flow, the virtualization path
4. [Using OpenStack (the playground)](docs/en/4-using-openstack.md) — launch and tear down VMs and build networks with the `openstack` CLI
5. [Troubleshooting](docs/en/5-troubleshooting.md) — error cheatsheet, tracking osh-deploy progress, 5 common pitfalls and fixes
6. [Instance sizes and cost](docs/en/6-cost.md) — AWS instance options compared with their hourly cost
7. [Notes & constraints](docs/en/7-design-decisions.md) — SSM-only access, pinned versions, ClusterIP-only services, no local kubectl

## Repository layout

```
.
├── Makefile                # shortcuts: make up / down / osh-deploy / osh-vm, etc.
├── docs/                   # the 7 docs above, in en/ and ko/
├── terraform/              # AWS infrastructure
│   ├── providers.tf        #   AWS provider (Seoul region)
│   ├── vpc.tf              #   VPC + public subnet + egress-only SG
│   ├── iam.tf              #   IAM role for SSM Session Manager (no SSH)
│   ├── ec2.tf              #   m5.4xlarge, Ubuntu 24.04 (Noble), 100 GB gp3
│   ├── user_data.sh        #   on boot, auto-installs K8s 1.34 + Calico + helm
│   ├── outputs.tf          #   instance_id, region, ssm_command
│   └── variables.tf
└── osh/                    # OpenStack-Helm deployment (runs on the node)
    ├── deploy.sh           #   install OSH 2026.1.0 compute-core full stack (~20 min)
    └── cirros-boot.sh      #   validate by booting a CirrOS VM (~3 min)
```

## Where to start

Run `make help` to see the available targets, then work through the docs starting from [1. Install](docs/en/1-install.md).

Already brought it up once? Jump straight to [2. Verify](docs/en/2-verify.md) (the check commands) or [4. Using OpenStack](docs/en/4-using-openstack.md) (the playground).

Stuck? See [5. Troubleshooting](docs/en/5-troubleshooting.md).
