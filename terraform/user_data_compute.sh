#!/bin/bash
# Bootstraps node-b: a compute-only host for the live-migration-webhook track.
# Installs K8s binaries (kubelet/kubeadm/kubectl) and containerd but does NOT
# run `kubeadm init` — that would make node-b its own single-node cluster
# instead of joining node-a's. Cluster join happens in L2, out of scope here.
set -euxo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

export DEBIAN_FRONTEND=noninteractive

# ---------- 0. base packages ----------
apt-get update
apt-get install -y \
  curl wget git jq make python3 python3-pip python3-venv \
  apt-transport-https ca-certificates gnupg lsb-release software-properties-common \
  bridge-utils conntrack socat ipset

# ---------- 1. swap off + kernel ----------
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

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
# Must match node-a's minor version for `kubeadm join` in L2 to work.
K8S_MINOR="v1.34"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# ---------- done ----------
# NOTE: no kubeadm init, no Calico, no taint removal, no helm — this node is not
# part of a cluster yet. `kubeadm join` (L2) is what makes it one.
touch /var/log/user-data-complete
echo "================================================================"
echo "user_data done. node-b has K8s binaries installed, not yet joined to a cluster."
echo "Verify from your laptop:  make ready-compute"
echo "Or open a shell:          make ssm-compute"
echo "================================================================"
