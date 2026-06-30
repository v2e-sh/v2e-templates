#!/usr/bin/env bash
# Build the VyOS template by importing a cloud-init qcow2. No virt-customize — VyOS is the
# router and needs no sops/age. The qcow2 comes from either:
#   - VYOS_URL  (a published build, e.g. a GitHub release asset) — fetched + checksum-verified
#   - or a local build produced by vyos/build-from-source.sh  ($IMG_CACHE/vyos-<branch>.qcow2)
# Run ON the Proxmox host.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.env
source "$HERE/config.env"

VMID="$VYOS_VMID"
NAME="$VYOS_NAME"
local_img="${IMG_CACHE}/vyos-${VYOS_BRANCH}.qcow2"

if [[ -n "${VYOS_URL}" ]]; then
  img="${IMG_CACHE}/$(basename "$VYOS_URL")"
  if [[ -f "$img" ]] && [[ -n "$VYOS_SHA256" ]] && echo "${VYOS_SHA256}  ${img}" | sha256sum -c --status; then
    echo ">> using cached ${img}"
  else
    echo ">> downloading ${VYOS_URL}"
    curl -fSL -o "${img}.part" "$VYOS_URL"
    [[ -n "$VYOS_SHA256" ]] && echo "${VYOS_SHA256}  ${img}.part" | sha256sum -c -
    mv "${img}.part" "$img"
  fi
elif [[ -f "$local_img" ]]; then
  img="$local_img"
  echo ">> using locally-built ${img}"
else
  echo "!! No VyOS qcow2 found. Either set VYOS_URL in config.env, or run" >&2
  echo "   vyos/build-from-source.sh first to produce ${local_img}." >&2
  exit 1
fi

echo ">> (re)create template ${VMID} and import the qcow2"
qm destroy "$VMID" --purge 1 2>/dev/null || true
qm create "$VMID" --name "$NAME" --cores 1 --memory 1024 --cpu host \
  --net0 "virtio,bridge=${BRIDGE}" --scsihw virtio-scsi-single \
  --serial0 socket --vga serial0 --ostype l26 --agent enabled=1
qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${img}"
qm disk resize "$VMID" scsi0 10G || true
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0
qm template "$VMID"
echo "OK: template ${VMID} (${NAME}) built from VyOS qcow2"
