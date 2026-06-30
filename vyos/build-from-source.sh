#!/usr/bin/env bash
# Produce a VyOS rolling cloud-init qcow2 by building FROM SOURCE — fully automated, with
# ZERO impact on the Proxmox host: it clones the Debian template into a throwaway builder
# VM, runs vyos-build (Docker) INSIDE that VM, copies the qcow2 back to IMG_CACHE, and
# destroys the VM. Run ON the Proxmox host. Then run ../build-vyos.sh to template the result.
#
# Output: $IMG_CACHE/vyos-<branch>.qcow2  (+ its sha256 printed, for a GitHub release).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../config.env
source "$HERE/../config.env"

BRANCH="$VYOS_BRANCH"
TPL="$DEBIAN_VMID"            # builder is a clone of the Debian template we built
BVMID="$VYOS_BUILDER_VMID"
BIP="$VYOS_BUILDER_IP"
GW="$BUILD_GW"
OUT="${IMG_CACHE}/vyos-${BRANCH}.qcow2"

keydir="$(mktemp -d)"
cleanup() {
  rm -rf "$keydir"
  qm stop "$BVMID" --skiplock 1 >/dev/null 2>&1 || true
  sleep 2
  qm destroy "$BVMID" --purge 1 >/dev/null 2>&1 || true
}
trap cleanup EXIT
ssh-keygen -t ed25519 -N "" -f "$keydir/id" -q

echo ">> cloning Debian template ${TPL} -> throwaway builder VM ${BVMID}"
qm destroy "$BVMID" --purge 1 >/dev/null 2>&1 || true
qm clone "$TPL" "$BVMID" --name vyos-builder
qm set "$BVMID" --memory 6144 --cores 4 >/dev/null
qm set "$BVMID" --ipconfig0 "ip=${BIP}/24,gw=${GW}" --nameserver 1.1.1.1 \
  --ciuser builder --sshkeys "$keydir/id.pub" >/dev/null
qm disk resize "$BVMID" scsi0 40G >/dev/null || true
qm start "$BVMID" >/dev/null

echo ">> waiting for builder SSH at ${BIP} ..."
ssh_b() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 -i "$keydir/id" "builder@${BIP}" "$@"; }
up=0
for _ in $(seq 1 36); do ssh_b true >/dev/null 2>&1 && { up=1; break; }; sleep 10; done
[[ $up -eq 1 ]] || { echo "!! builder VM never came up on SSH"; exit 1; }

echo ">> uploading flavor + running vyos-build (${BRANCH}); this takes ~20-40 min"
scp -o StrictHostKeyChecking=no -i "$keydir/id" "$HERE/proxmox-cloudinit.toml" "builder@${BIP}:/tmp/flavor.toml"
ssh_b "sudo BRANCH='${BRANCH}' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io git
systemctl enable --now docker
rm -rf /opt/vyos-build
git clone -b "$BRANCH" --single-branch https://github.com/vyos/vyos-build /opt/vyos-build
cp /tmp/flavor.toml /opt/vyos-build/data/build-flavors/proxmox-cloudinit.toml
cd /opt/vyos-build
docker run --rm --privileged -v /opt/vyos-build:/vyos -v /dev:/dev -w /vyos \
  "vyos/vyos-build:${BRANCH}" \
  bash -c "sudo ./build-vyos-image --architecture amd64 --build-by 'v2e' --disk-size 10 proxmox-cloudinit"
REMOTE

echo ">> copying qcow2 back to ${OUT}"
remote="$(ssh_b 'sudo readlink -f "$(sudo find /opt/vyos-build/build -maxdepth 1 -name "*.qcow2" | head -1)"')"
[[ -n "$remote" ]] || { echo "!! build produced no qcow2"; exit 1; }
ssh_b "sudo chmod a+r '$remote'"
scp -o StrictHostKeyChecking=no -i "$keydir/id" "builder@${BIP}:${remote}" "$OUT"
echo "OK: built ${OUT}"
echo "VYOS_SHA256=$(sha256sum "$OUT" | cut -d' ' -f1)"
echo ">> next: bash ../build-vyos.sh   (and upload ${OUT} to a GitHub release to share it)"
