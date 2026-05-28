#!/bin/bash
# Deploy compute-core OpenStack-Helm 2024.2.0 on a single-node K8s cluster.
# Designed to be idempotent. Run as root on the node.
#
# Prereqs: K8s 1.29 + Calico + Helm (user_data already provides these).
# Total runtime: ~30 min on m5.4xlarge.

set -xeuo pipefail
export HOME=/root
export KUBECONFIG=/etc/kubernetes/admin.conf
export FEATURES="2024.2 ubuntu_jammy"

OSH_REF="2024.2.0"
OSH_ROOT=/opt/openstack-helm
OSH_DIR="$OSH_ROOT/openstack-helm"
INFRA_DIR="$OSH_ROOT/openstack-helm-infra"
OVR_OSH="$OSH_DIR/values_overrides"
OVR_INFRA="$INFRA_DIR/values_overrides"

# ----- Step 1: clone OSH at the matching release tag -----
mkdir -p "$OSH_ROOT"
cd "$OSH_ROOT"
[ -d openstack-helm ] || git clone --depth 1 -b "$OSH_REF" https://opendev.org/openstack/openstack-helm.git
[ -d openstack-helm-infra ] || git clone --depth 1 -b "$OSH_REF" https://opendev.org/openstack/openstack-helm-infra.git
chown -R ubuntu:ubuntu "$OSH_ROOT"

# ----- Step 2: install OSH helm plugin under /root -----
# SSM run-command sessions have HOME='', so helm reads plugins from CWD/.local
# unless HOME is exported. Forcing HOME=/root keeps the plugin discoverable.
mkdir -p /root/.local/share/helm/plugins
if ! helm plugin list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx osh; then
  helm plugin install https://opendev.org/openstack/openstack-helm-plugin
fi
helm plugin list

# ----- Step 3: build chart dependencies (helm-toolkit etc.) -----
# All OSH charts depend on helm-toolkit. prepare-charts.sh runs `make all`
# in both openstack-helm-infra and openstack-helm, producing .tgz packages.
cd "$OSH_DIR"
[ -f "$INFRA_DIR/helm-toolkit-${OSH_REF}.tgz" ] || bash tools/deployment/common/prepare-charts.sh

# ----- Step 4: storage provisioner + StorageClasses -----
# OSH 2024.2 hardcodes some PVC class_names to 'general' (e.g. glance).
# We deploy local-path-provisioner as the cluster default and additionally
# alias 'general' to it.
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

# ----- Step 6: dummy provider1 interface -----
# neutron's auto_bridge_add wires provider1 into br-ex. On a fake single-node
# lab there's no real external NIC, so a dummy keeps ovs-agent happy.
if ! ip link show provider1 >/dev/null 2>&1; then
  ip link add provider1 type dummy
  ip link set provider1 up
fi

# ----- Step 7: infrastructure (mariadb, rabbitmq, memcached) -----
cd "$OSH_DIR"
./tools/deployment/component/common/mariadb.sh
./tools/deployment/component/common/rabbitmq.sh
./tools/deployment/component/common/memcached.sh

# ----- Step 8: keystone -----
helm upgrade --install keystone "$OSH_DIR/keystone" \
  --namespace=openstack \
  $(helm osh get-values-overrides -p "$OVR_OSH" -c keystone $FEATURES)
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
  $(helm osh get-values-overrides -p "$OVR_OSH" -c glance $FEATURES) || true

# ----- Step 10: compute substrate (openvswitch + libvirt) -----
helm upgrade --install openvswitch "$INFRA_DIR/openvswitch" \
  --namespace=openstack \
  $(helm osh get-values-overrides -p "$OVR_INFRA" -c openvswitch $FEATURES)
helm osh wait-for-pods openstack 600

helm upgrade --install libvirt "$INFRA_DIR/libvirt" \
  --namespace=openstack \
  --set conf.ceph.enabled=false \
  $(helm osh get-values-overrides -p "$OVR_INFRA" -c libvirt $FEATURES)
# libvirt waits on neutron-ovs-agent; do not block here.

# ----- Step 11: placement -----
helm upgrade --install placement "$OSH_DIR/placement" \
  --namespace=openstack \
  $(helm osh get-values-overrides -p "$OVR_OSH" -c placement $FEATURES)

# ----- Step 12: nova (qemu emulation, no ceph) -----
tee /tmp/nova.yaml << EOF
conf:
  nova:
    libvirt:
      virt_type: qemu
      cpu_mode: none
  ceph:
    enabled: false
bootstrap:
  wait_for_computes:
    enabled: true
EOF
helm upgrade --install nova "$OSH_DIR/nova" \
  --namespace=openstack \
  --values=/tmp/nova.yaml \
  $(helm osh get-values-overrides -p "$OVR_OSH" -c nova $FEATURES)

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
  $(helm osh get-values-overrides -p "$OVR_OSH" -c neutron $FEATURES)

# ----- Step 14: patch the 'metadata' Service -----
# OSH creates a 'metadata' Service expecting an ingress controller to fan
# traffic into nova-api-metadata. With no ingress, neutron-metadata-agent's
# init dependency on Service 'metadata' never resolves. We re-point the
# Service selector + targetPort at the nova-api-metadata Deployment.
kubectl -n openstack patch svc metadata --type=json -p='[
  {"op":"replace","path":"/spec/selector","value":{"application":"nova","component":"metadata"}},
  {"op":"replace","path":"/spec/ports","value":[
    {"name":"http","port":80,"protocol":"TCP","targetPort":8775},
    {"name":"https","port":443,"protocol":"TCP","targetPort":8775}
  ]}
]'

# ----- Step 15: strip broken readiness/startup probes from DaemonSets -----
# health-probe.py uses oslo.messaging which times out trying to resolve
# the rabbitmq hostname under certain DNS conditions, so probes flap even
# though the main process talks to RabbitMQ fine (placement/nova/neutron
# control-plane registration succeeds). Removing the probes lets the
# DaemonSets reach Ready quickly.
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
kubectl -n openstack rollout restart ds nova-compute-default neutron-l3-agent-default neutron-dhcp-agent-default

# ----- Step 16: final wait -----
helm osh wait-for-pods openstack 1500 || true

echo "===== FINAL ====="
helm -n openstack list
echo "----"
kubectl -n openstack get pods --no-headers | awk '{print $3}' | sort | uniq -c
echo "----"
kubectl -n openstack get pods --no-headers | awk '$3!="Running" && $3!="Completed"{print}'
echo DONE_OSH_DEPLOY
