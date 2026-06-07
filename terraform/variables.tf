variable "region" {
  description = "AWS region. ap-northeast-2 = Seoul (low latency from KR)."
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  # m5zn.metal: 48 vCPU / 192 GB / ~$3.97/hr in ap-northeast-2. Nested KVM
  # supported. Chosen over m5.metal (96 vCPU) because the default account
  # vCPU limit for "All Standard" Spot+On-Demand is 64 — m5.metal hits
  # VcpuLimitExceeded without a quota increase. m5zn.metal also has the
  # fastest single-core (4.5 GHz) of the metal family.
  description = "EC2 instance type. m5zn.metal = nested KVM + Ceph within default 64-vCPU quota."
  type        = string
  default     = "m5zn.metal"
}

variable "root_volume_gb" {
  description = "Root EBS volume size. 100GB leaves room for container images + libvirt images."
  type        = number
  default     = 100
}

variable "cinder_volume_gb" {
  description = "Extra EBS attached as raw block device for Cinder LVM VG 'cinder-volumes'."
  type        = number
  default     = 50
}

variable "rook_volume_gb" {
  description = "Extra EBS attached as raw block device for Rook-Ceph OSD (no filesystem)."
  type        = number
  default     = 80
}

variable "project_name" {
  type    = string
  default = "osh-lab"
}
