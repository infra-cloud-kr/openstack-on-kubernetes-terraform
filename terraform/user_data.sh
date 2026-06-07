#!/bin/bash
# Bootstraps a single-node Kubernetes cluster (kubeadm v1.34) with Calico CNI.
# Goal of this stage: a healthy single-node K8s. OpenStack-Helm is a later step.
set -euxo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

export DEBIAN_FRONTEND=noninteractive

# ---------- 0. base packages ----------
apt-get update
apt-get install -y \
  curl wget git jq make python3 python3-pip python3-venv \
  apt-transport-https ca-certificates gnupg lsb-release software-properties-common \
  bridge-utils conntrack socat ipset \
  lvm2 thin-provisioning-tools open-iscsi qemu-utils

# ---------- 1. swap off + kernel ----------
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
rbd
kvm
kvm_intel
EOF
modprobe overlay
modprobe br_netfilter
# rbd: required by Rook-Ceph clients (cinder-volume, nova-compute, glance-api
#      when configured with rbd backend) to map RBD images as block devices.
# kvm/kvm_intel: nested KVM. m5.metal allows full hardware passthrough; nova
#      uses virt_type=kvm + cpu_mode=host-passthrough. On non-metal SKUs these
#      modules either don't load or have no effect (fall back to qemu).
modprobe rbd        || echo "rbd module not available"
modprobe kvm        || true
modprobe kvm_intel  || true

cat >/etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# ---------- 2. containerd ----------
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# ---------- 3. kubeadm/kubelet/kubectl (v1.34) ----------
# OSH 2026.1 (Gazpacho) officially supports K8s >=1.33, <=1.35 on Ubuntu Noble
# (see openstack-helm/README.rst compatibility matrix). Calico v3.32 supports
# K8s 1.34-1.36, so 1.34 sits in the intersection of both windows.
# 1.33 should also work; 1.35 works for OSH but is the upper edge for Calico.
K8S_MINOR="v1.34"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# ---------- 4. kubeadm init (single node) ----------
kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --ignore-preflight-errors=NumCPU,Mem

export KUBECONFIG=/etc/kubernetes/admin.conf

mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config

# ---------- 5. Calico CNI ----------
# NOTE: --server-side is REQUIRED. Plain `kubectl apply` fails on tigera-operator
# CRDs because they exceed the 262144-byte annotation size limit
# (last-applied-configuration annotation).
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/tigera-operator.yaml
# Calico v3.32 added Goldmane/Whisker CRDs on top of Installation/APIServer.
# tigera-operator.yaml registers them, but the apiserver needs a moment before
# the CRD objects themselves exist (kubectl wait fails NotFound immediately if
# called too early). Two-step: poll until each CRD exists, then wait for
# condition=Established.
for crd in installations apiservers goldmanes whiskers; do
  for i in $(seq 1 60); do
    kubectl get crd "${crd}.operator.tigera.io" >/dev/null 2>&1 && break
    sleep 2
  done
  kubectl wait --for=condition=Established "crd/${crd}.operator.tigera.io" --timeout=120s
done
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/custom-resources.yaml

# ---------- 6. untaint master so workloads schedule on the single node ----------
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

# ---------- 6b. helm (required by osh/deploy.sh) ----------
# Use the official get-helm-3 installer — the baltocdn apt repo has been flaky.
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3
chmod +x /tmp/get-helm-3
/tmp/get-helm-3

# ---------- 7. wait for Calico to be ready ----------
# Calico takes a couple of minutes to roll out. Block until the node reports Ready
# so that "/var/log/user-data-complete" is a real "K8s is usable" signal, not just
# "kubeadm init returned".
echo "Waiting for node to become Ready (Calico rollout)..."
for i in $(seq 1 60); do
  if kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -qx Ready; then
    echo "Node is Ready."
    break
  fi
  sleep 5
done

# ---------- 8. Cinder LVM VG ----------
# ec2.tf attaches two extra raw EBS volumes (sizes differ on purpose so we can
# tell them apart by size):
#   - cinder disk (var.cinder_volume_gb, default 50G) -> VG "cinder-volumes"
#   - rook disk   (var.rook_volume_gb,   default 80G) -> stays raw for Rook
# If you change those vars in terraform/variables.tf, update the target sizes
# below to match.
pick_dev() {
  local target_gb=$1
  local target_bytes=$(( target_gb * 1024 * 1024 * 1024 ))
  lsblk -bdno NAME,SIZE,TYPE | awk -v t=$target_bytes \
    '$3=="disk" && $2>=t*0.95 && $2<=t*1.05 {print "/dev/"$1; exit}'
}
CINDER_DEV=$(pick_dev 50)
ROOK_DEV=$(pick_dev 80)
echo "CINDER_DEV=$CINDER_DEV  ROOK_DEV=$ROOK_DEV"

if [ -n "$CINDER_DEV" ] && ! vgs cinder-volumes >/dev/null 2>&1; then
  wipefs -af "$CINDER_DEV"
  pvcreate -ff -y "$CINDER_DEV"
  vgcreate cinder-volumes "$CINDER_DEV"
fi
vgs || true

# Rook just needs the device to exist and be unformatted — leave it alone.
[ -n "$ROOK_DEV" ] && wipefs -af "$ROOK_DEV" || true

# ---------- done ----------
touch /var/log/user-data-complete
echo "================================================================"
echo "user_data done. Single-node Kubernetes is up."
echo "Verify from your laptop:  make status"
echo "Or open a shell:          make ssm"
echo "================================================================"
