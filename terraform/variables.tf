variable "region" {
  description = "AWS region. ap-northeast-2 = Seoul (low latency from KR)."
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  # OSH 2024.2 CI's 'openstack-helm-1node-32GB-ubuntu_jammy' nodeset (8 vCPU / 32 GB)
  # is the documented minimum for single-node compute-core. Match it with m5.2xlarge
  # (~$0.48/hr in ap-northeast-2) if you want the cheapest option that still works.
  # m5.4xlarge doubles both axes — extra headroom for QEMU emulation (no nested KVM
  # on m5) when booting multiple guests, and survives running optional charts
  # (heat / cinder / horizon) on top of compute-core without OOM.
  description = "EC2 instance type. m5.2xlarge = OSH 32GB nodeset baseline; m5.4xlarge = comfortable."
  type        = string
  default     = "m5.4xlarge"
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
