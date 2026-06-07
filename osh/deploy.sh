#!/bin/bash
# Deploy compute-core OpenStack-Helm 2026.1.0 on a single-node K8s cluster.
# Designed to be idempotent. Run as root on the node.
#
# Prereqs: K8s 1.34 + Calico + Helm (user_data already provides these).
# Total runtime: ~30 min on m5.4xlarge.

set -xeuo pipefail
export HOME=/root
export KUBECONFIG=/etc/kubernetes/admin.conf
export FEATURES="2026.1 ubuntu_noble"

OSH_REF="2026.1.0"
OSH_ROOT=/opt/openstack-helm
OSH_DIR="$OSH_ROOT/openstack-helm"
# In 2026.1 the separate openstack-helm-infra repo was absorbed into openstack-helm.
# helm-toolkit, mariadb, rabbitmq, memcached, openvswitch, libvirt all live under
# $OSH_DIR now, and values_overrides moved from per-chart subdirs to a single
# top-level $OSH_DIR/values_overrides/ tree.
OVR="$OSH_DIR/values_overrides"

# ----- Step 1: clone OSH at the matching release tag -----
mkdir -p "$OSH_ROOT"
cd "$OSH_ROOT"
[ -d openstack-helm ] || git clone --depth 1 -b "$OSH_REF" https://opendev.org/openstack/openstack-helm.git
chown -R ubuntu:ubuntu "$OSH_ROOT"
# After chown, root (which runs this script via SSM) sees the repo as owned
# by another user and refuses git operations ("dubious ownership"). OSH's
# tools/chart_version.sh calls git inside prepare-charts.sh, so allow it.
git config --global --add safe.directory "$OSH_DIR"

# ----- Step 2: install OSH helm plugin under /root -----
# SSM run-command sessions have HOME='', so helm reads plugins from CWD/.local
# unless HOME is exported. Forcing HOME=/root keeps the plugin discoverable.
mkdir -p /root/.local/share/helm/plugins
if ! helm plugin list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx osh; then
  helm plugin install https://opendev.org/openstack/openstack-helm-plugin
fi
helm plugin list

# ----- Step 3: build chart dependencies (helm-toolkit etc.) -----
# All OSH charts depend on helm-toolkit. prepare-charts.sh now runs `make all`
# in openstack-helm only (single repo since 2026.1).
cd "$OSH_DIR"
[ -f "$OSH_DIR/helm-toolkit-${OSH_REF}.tgz" ] || bash tools/deployment/common/prepare-charts.sh

# ----- Step 4: storage provisioner + StorageClasses -----
# OSH hardcodes some PVC class_names to 'general' (e.g. glance — verify on
# 2026.1 first run; if PVCs Bind on default SC alone, this alias is unnecessary).
# Deploy local-path-provisioner as cluster default and additionally alias 'general'.
LP_VER="v0.0.27"
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LP_VER}/deploy/local-path-storage.yaml"
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: general
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s

# ----- Step 5: openstack namespace + node labels -----
kubectl get ns openstack >/dev/null 2>&1 || kubectl create ns openstack
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
for L in openstack-control-plane openstack-compute-node \
         openvswitch linuxbridge ovs-host \
         l3-agent dhcp-agent metadata-agent \
         ceph-mon ceph-osd ceph-mds ceph-mgr ceph-rgw; do
  kubectl label nodes "$NODE" "${L}=enabled" --overwrite
done

# OSH 2026.1 charts' ServiceAccounts don't grant endpointslices on K8s 1.33+,
# but kubernetes-entrypoint's dependency resolver now lists endpointslices, so
# every "wait for service X" init container loops "is forbidden" forever.
# Grant read-only endpointslices to every SA in the openstack ns as a blanket
# workaround until OSH fixes its per-chart Roles. Inlined because Makefile
# ships only this script to the node via SSM.
kubectl apply -f - <<'RBAC_EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: openstack-endpointslices-read
  namespace: openstack
rules:
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: openstack-endpointslices-read
  namespace: openstack
subjects:
- kind: Group
  name: system:serviceaccounts:openstack
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: openstack-endpointslices-read
  apiGroup: rbac.authorization.k8s.io
RBAC_EOF

# ----- Step 6: dummy provider1 interface -----
# neutron's auto_bridge_add wires provider1 into br-ex. On a fake single-node
# lab there's no real external NIC, so a dummy keeps ovs-agent happy.
if ! ip link show provider1 >/dev/null 2>&1; then
  ip link add provider1 type dummy
  ip link set provider1 up
fi

# ----- Step 7: infrastructure (mariadb, rabbitmq, memcached) -----
# In 2026.1 the mariadb helper moved from tools/deployment/component/common/
# to tools/deployment/db/. rabbitmq/memcached helpers stayed in their old path.
# Disable mariadb-exporter: its SA's RBAC doesn't grant endpointslices on
# K8s 1.33+, so the create-sql-user Job init loops forever and blocks
# wait-for-pods. We don't need prom monitoring on this lab anyway.
cd "$OSH_DIR"
MONITORING_HELM_ARGS="--set monitoring.prometheus.enabled=false" \
  ./tools/deployment/db/mariadb.sh
./tools/deployment/component/common/rabbitmq.sh
./tools/deployment/component/common/memcached.sh

# ----- Step 8: keystone -----
helm upgrade --install keystone "$OSH_DIR/keystone" \
  --namespace=openstack \
  $(helm osh get-values-overrides -p "$OVR" -c keystone $FEATURES)
helm osh wait-for-pods openstack 600

# ----- Step 9: glance (PVC storage) -----
tee /tmp/glance.yaml <<EOF
storage: pvc
EOF
# post-install hook will time out because of probe weirdness on first try,
# but the chart itself + bootstrap jobs end up Completed. We allow failure
# and the wait below confirms readiness.
helm upgrade --install glance "$OSH_DIR/glance" \
  --namespace=openstack \
  --values=/tmp/glance.yaml \
  --timeout=300s \
  $(helm osh get-values-overrides -p "$OVR" -c glance $FEATURES) || true

# ----- Step 10: compute substrate (openvswitch + libvirt) -----
helm upgrade --install openvswitch "$OSH_DIR/openvswitch" \
  --namespace=openstack \
  $(helm osh get-values-overrides -p "$OVR" -c openvswitch $FEATURES)
helm osh wait-for-pods openstack 600

helm upgrade --install libvirt "$OSH_DIR/libvirt" \
  --namespace=openstack \
  --set conf.ceph.enabled=false \
  $(helm osh get-values-overrides -p "$OVR" -c libvirt $FEATURES)
# libvirt waits on neutron-ovs-agent; do not block here.

# ----- Step 11: placement -----
helm upgrade --install placement "$OSH_DIR/placement" \
  --namespace=openstack \
  $(helm osh get-values-overrides -p "$OVR" -c placement $FEATURES)

# ----- Step 12: nova (KVM on m5.metal, no ceph backend) -----
# m5.metal exposes vmx so we get hardware-accelerated nested KVM. Without metal
# the kvm modules don't load and you'd want virt_type=qemu / cpu_mode=none.
tee /tmp/nova.yaml << EOF
conf:
  nova:
    libvirt:
      virt_type: kvm
      cpu_mode: host-passthrough
  ceph:
    enabled: false
bootstrap:
  wait_for_computes:
    enabled: true
EOF
helm upgrade --install nova "$OSH_DIR/nova" \
  --namespace=openstack \
  --values=/tmp/nova.yaml \
  $(helm osh get-values-overrides -p "$OVR" -c nova $FEATURES)

# ----- Step 13: neutron (simplified, with agent node-selector labels) -----
tee /tmp/neutron.yaml << EOF
network:
  interface:
    tunnel: null
conf:
  neutron:
    DEFAULT:
      l3_ha: False
      max_l3_agents_per_router: 1
      l3_ha_network_type: vxlan
      dhcp_agents_per_network: 1
  auto_bridge_add:
    br-ex: provider1
  plugins:
    ml2_conf:
      ml2_type_flat:
        flat_networks: public
    openvswitch_agent:
      agent:
        tunnel_types: vxlan
      ovs:
        bridge_mappings: public:br-ex
labels:
  agent:
    l3:
      node_selector_key: l3-agent
      node_selector_value: enabled
    dhcp:
      node_selector_key: dhcp-agent
      node_selector_value: enabled
    metadata:
      node_selector_key: metadata-agent
      node_selector_value: enabled
EOF
helm upgrade --install neutron "$OSH_DIR/neutron" \
  --namespace=openstack \
  --values=/tmp/neutron.yaml \
  $(helm osh get-values-overrides -p "$OVR" -c neutron $FEATURES)

# ----- Step 14: patch the 'metadata' Service (single-node workaround) -----
# 2024.2 needed this because OSH wired the 'metadata' Service to an ingress
# controller selector that didn't exist on single-node labs. Re-verify on 2026.1
# before assuming necessity; if `kubectl -n openstack get svc metadata -o
# jsonpath='{.spec.selector}'` already targets nova-api-metadata, drop this.
kubectl -n openstack patch svc metadata --type=json -p='[
  {"op":"replace","path":"/spec/selector","value":{"application":"nova","component":"metadata"}},
  {"op":"replace","path":"/spec/ports","value":[
    {"name":"http","port":80,"protocol":"TCP","targetPort":8775},
    {"name":"https","port":443,"protocol":"TCP","targetPort":8775}
  ]}
]' 2>/dev/null || true

# ----- Step 15: strip broken readiness/startup probes from DaemonSets -----
# 2024.2 health-probe.py timed out on RabbitMQ DNS resolution under some single-
# node DNS conditions even though the agent itself was healthy. 2026.1 may have
# fixed this — observe DaemonSet readiness on first run; if they reach 1/1
# without help, drop this block.
strip_probes() {
  local ds="$1"
  for k in startupProbe readinessProbe livenessProbe; do
    kubectl -n openstack patch ds "$ds" --type=json \
      -p='[{"op":"remove","path":"/spec/template/spec/containers/0/'"$k"'"}]' 2>&1 || true
  done
}
strip_probes nova-compute-default
strip_probes neutron-l3-agent-default
strip_probes neutron-dhcp-agent-default
kubectl -n openstack rollout restart ds nova-compute-default neutron-l3-agent-default neutron-dhcp-agent-default 2>/dev/null || true

# ----- Step 16: Rook-Ceph (mon=1 / osd=1 / replication=1 single-node) -----
# Adds a real Ceph cluster on the 80G raw EBS attached as ROOK_DEV. We don't
# wire OpenStack chart backends to RBD here (that would require ceph keys in
# glance/cinder/nova which is a much bigger integration) — Rook gives us a
# CephCluster + RBD StorageClass that lab can experiment with from K8s side.
ROOK_VER="v1.18.5"
helm repo add rook-release https://charts.rook.io/release 2>/dev/null || true
helm repo update
helm upgrade --install rook-ceph rook-release/rook-ceph \
  --namespace rook-ceph --create-namespace \
  --version "$ROOK_VER" \
  --wait --timeout=10m

# Locate the 80G raw block device on the host (matches user_data's ROOK_DEV).
ROOK_DEV=$(lsblk -bdno NAME,SIZE,TYPE \
  | awk '$3=="disk" && $2>=85899345920*0.95 && $2<=85899345920*1.05 {print "/dev/"$1; exit}')
echo "ROOK_DEV=$ROOK_DEV"
if [ -z "$ROOK_DEV" ]; then
  echo "WARN: 80G Rook disk not found — skipping CephCluster"
else
  kubectl apply -f - <<CEPH_EOF
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  cephVersion:
    image: quay.io/ceph/ceph:v19.2.0
  dataDirHostPath: /var/lib/rook
  mon:
    count: 1
    allowMultiplePerNode: true
  mgr:
    count: 1
    allowMultiplePerNode: true
  dashboard:
    enabled: false
  storage:
    useAllNodes: false
    useAllDevices: false
    nodes:
    - name: "$NODE"
      devices:
      - name: "$ROOK_DEV"
---
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: replicapool
  namespace: rook-ceph
spec:
  failureDomain: osd
  replicated:
    size: 1
    requireSafeReplicaSize: false
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-ceph-block
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
  csi.storage.k8s.io/fstype: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true
CEPH_EOF
fi

# ----- Step 17: Cinder with LVM backend -----
# Backed by VG cinder-volumes (created by user_data on the 50G raw EBS).
# OSH's cinder chart defaults to ceph backend, so we override conf.backends.
if ! vgs cinder-volumes >/dev/null 2>&1; then
  echo "WARN: VG cinder-volumes not found on host — Cinder install will fail"
fi

tee /tmp/cinder.yaml << CINDER_EOF
# OSH cinder chart defaults to ceph backend. We override to LVM. Two pieces:
# 1) conf.* — point cinder.conf at cinder-volumes VG via LVMVolumeDriver
# 2) manifests.job_*_storage_init=false — these jobs only make sense for ceph
#    pools. The chart's pod dependency list references them anyway, so leaving
#    them enabled (default) blocks every cinder pod's init on a job that's
#    never templated. Turning the manifest off drops the dep too.
# 3) manifests.deployment_backup=false — backup uses ceph; skip on this lab.
conf:
  ceph:
    enabled: false
  cinder:
    DEFAULT:
      enabled_backends: lvmdriver-1
      default_volume_type: lvmdriver-1
      glance_api_servers: "http://glance-api.openstack.svc.cluster.local:9292"
  backends:
    rbd1: null
    lvmdriver-1:
      volume_driver: cinder.volume.drivers.lvm.LVMVolumeDriver
      volume_backend_name: lvmdriver-1
      volume_group: cinder-volumes
      target_protocol: iscsi
      target_helper: tgtadm
      # Ubuntu Noble AWS kernel (linux-aws) lacks dm-thin-pool by default,
      # so cinder's modprobe at startup fails and LVMVolumeDriver stays
      # uninitialized ("Volume driver not ready"). Valid lvm_type values
      # per cinder source: [default, thin, auto]. "default" == standard
      # LVs (thick), no dm-thin-pool needed.
      lvm_type: default
manifests:
  job_storage_init: false
  job_backup_storage_init: false
  deployment_backup: false
bootstrap:
  volume_types:
    volume_type_1:
      name: lvmdriver-1
      properties:
        volume_backend_name: lvmdriver-1
storage: pvc
CINDER_EOF
helm upgrade --install cinder "$OSH_DIR/cinder" \
  --namespace=openstack \
  --values=/tmp/cinder.yaml \
  --timeout=600s \
  $(helm osh get-values-overrides -p "$OVR" -c cinder $FEATURES) || true

# ----- Step 18: final wait -----
helm osh wait-for-pods openstack 1500 || true

echo "===== FINAL ====="
helm -n openstack list
echo "----"
helm -n rook-ceph list
echo "----"
kubectl -n openstack get pods --no-headers | awk '{print $3}' | sort | uniq -c
echo "----"
kubectl -n openstack get pods --no-headers | awk '$3!="Running" && $3!="Completed"{print}'
echo "----"
kubectl get sc
echo DONE_OSH_DEPLOY
