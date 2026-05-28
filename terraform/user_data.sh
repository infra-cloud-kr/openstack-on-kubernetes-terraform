#!/bin/bash
# Bootstraps a single-node Kubernetes cluster (kubeadm v1.29) with Calico CNI.
# Goal of this stage: a healthy single-node K8s. OpenStack-Helm is a later step.
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

# ---------- 3. kubeadm/kubelet/kubectl (v1.29) ----------
# OSH 2024.2 (Dalmatian) officially supports K8s >=1.29, <=1.31 on Ubuntu Jammy
# (see openstack-helm/README.rst compatibility matrix). 1.29 is the lower bound
# but is what's verified end-to-end with this lab; bumping to 1.30 or 1.31 should
# work and you may want to also bump the Calico version in step 5 accordingly.
# 1.32+ is outside OSH 2024.2's tested range — chart manifests still use some
# APIs (e.g. policy/v1beta1, autoscaling/v2beta) that may have been removed.
K8S_MINOR="v1.29"
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
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/tigera-operator.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/custom-resources.yaml

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

# ---------- done ----------
touch /var/log/user-data-complete
echo "================================================================"
echo "user_data done. Single-node Kubernetes is up."
echo "Verify from your laptop:  make status"
echo "Or open a shell:          make ssm"
echo "================================================================"
