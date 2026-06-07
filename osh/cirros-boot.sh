#!/bin/bash
# End-to-end VM boot validation: upload CirrOS image, create a tenant network,
# boot a VM, wait for ACTIVE. Runs an ephemeral openstack-client pod inside
# the cluster (no host docker / no resolv.conf coredns plumbing needed).

set -xeuo pipefail
export HOME=/root
export KUBECONFIG=/etc/kubernetes/admin.conf

# Disposable openstack-client pod with admin creds mounted via envFrom.
kubectl -n openstack delete pod osc --ignore-not-found
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: osc
  namespace: openstack
spec:
  restartPolicy: Never
  containers:
  - name: cli
    image: quay.io/airshipit/openstack-client:2026.1-ubuntu_noble
    command: ["sleep","7200"]
    envFrom:
    - secretRef:
        name: keystone-keystone-admin
EOF
kubectl -n openstack wait --for=condition=Ready pod/osc --timeout=120s

echo "===== sanity ====="
kubectl -n openstack exec osc -- openstack compute service list
kubectl -n openstack exec osc -- openstack hypervisor list
kubectl -n openstack exec osc -- openstack network agent list

echo "===== image ====="
kubectl -n openstack exec osc -- bash -c '
  set -e
  if ! openstack image show cirros >/dev/null 2>&1; then
    curl -sL https://download.cirros-cloud.net/0.6.2/cirros-0.6.2-x86_64-disk.img -o /tmp/cirros.img
    openstack image create --file /tmp/cirros.img --disk-format qcow2 --container-format bare --public cirros
  fi
  openstack image list
'

echo "===== flavor ====="
kubectl -n openstack exec osc -- bash -c '
  openstack flavor show m1.tiny >/dev/null 2>&1 || \
    openstack flavor create --ram 256 --disk 1 --vcpus 1 m1.tiny
'

echo "===== tenant network ====="
kubectl -n openstack exec osc -- bash -c '
  openstack network show demo-net >/dev/null 2>&1 || openstack network create demo-net
  openstack subnet show demo-subnet >/dev/null 2>&1 || \
    openstack subnet create --network demo-net --subnet-range 10.10.10.0/24 demo-subnet
'

echo "===== boot test-vm ====="
kubectl -n openstack exec osc -- bash -c '
  NET_ID=$(openstack network show demo-net -f value -c id)
  openstack server show test-vm >/dev/null 2>&1 || \
    openstack server create --flavor m1.tiny --image cirros --nic net-id=$NET_ID test-vm
'

echo "===== wait ACTIVE (up to 4 min) ====="
S=UNKNOWN
for i in $(seq 1 48); do
  S=$(kubectl -n openstack exec osc -- openstack server show test-vm -f value -c status 2>/dev/null | tr -d '\r' || echo UNKNOWN)
  echo "[t+$((i*5))s] status=$S"
  case "$S" in ACTIVE|ERROR) break;; esac
  sleep 5
done

echo "===== FINAL ====="
kubectl -n openstack exec osc -- openstack server list
echo DONE_CIRROS_BOOT
