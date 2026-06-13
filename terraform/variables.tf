variable "region" {
  description = "AWS region. ap-northeast-2 = Seoul (low latency from KR)."
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  # OSH 2026.1 CI's 'openstack-helm-1node-32GB-ubuntu_noble' nodeset (8 vCPU / 32 GB)
  # is the documented minimum for single-node compute-core. m5.2xlarge matches it
  # exactly (~$0.48/hr in ap-northeast-2) and is verified to run the full compute-core
  # stack plus a CirrOS VM boot (full-stack working set is ~8 GB, well under 32 GB).
  # Bump to m5.4xlarge (16 vCPU / 64 GB) for headroom when booting multiple guests or
  # adding optional charts (heat / cinder / horizon) on top of compute-core.
  description = "EC2 instance type. m5.2xlarge = OSH 32GB nodeset baseline (verified); m5.4xlarge = comfortable."
  type        = string
  default     = "m5.2xlarge"
}

variable "root_volume_gb" {
  description = "Root EBS volume size. 100GB leaves room for container images + libvirt images."
  type        = number
  default     = 100
}

variable "project_name" {
  type    = string
  default = "osh-lab"
}
