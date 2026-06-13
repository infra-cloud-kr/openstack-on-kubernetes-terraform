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
# OSH 2026.1 (Flamingo) supports K8s >=1.33, <=1.35 on Ubuntu Noble
# (see openstack-helm/README.rst compatibility matrix). 1.34 sits in the middle
# of that range. If you change this, bump the Calico version in step 5 to a
# release that supports the matching K8s minor.
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
CALICO_VER="v3.32.0"
kubectl apply --server-side --force-conflicts -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/tigera-operator.yaml"
# As of recent Calico the tigera-operator registers its CRDs (Installation,
# APIServer, ...) at runtime, so custom-resources.yaml races ahead of the CRDs
# and fails with "no matches for kind Installation". Wait for the CRD, then
# retry the apply until it sticks.
echo "Waiting for tigera-operator CRDs..."
for i in $(seq 1 60); do
  kubectl get crd installations.operator.tigera.io >/dev/null 2>&1 && break
  sleep 5
done
for i in $(seq 1 30); do
  kubectl apply --server-side --force-conflicts -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/custom-resources.yaml" && break
  echo "custom-resources apply not ready yet, retrying ($i)..."
  sleep 5
done

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
