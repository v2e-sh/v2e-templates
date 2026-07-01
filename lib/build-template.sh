#!/usr/bin/env bash
# Shared engine for building a Proxmox VM template from a base cloud image.
#
# Flow (all offline / host-side; no Packer, no API token, no build network):
#   fetch+verify cloud image  ->  virt-customize (bake + seal)  ->  qm import  ->  qm template
#
# A per-image build-<os>.sh sources config.env + this file, sets the vars below, then
# calls  build_template.  Run ON the Proxmox host.
#
# Required (per image):  VMID  TEMPLATE_NAME  IMG_URL  IMG_SHA256
# Optional (per image):  MEMORY(2048)  CORES(2)  DISK_SIZE(20G)
#                        BIOS(seabios)  MACHINE(pc)  EXTRA_PKGS("")  CI_RENDERER("")
# From config.env:       STORAGE  BRIDGE  SOPS_VERSION  AGE_VERSION  IMG_CACHE
set -euo pipefail

build_template() {
  : "${VMID:?}" "${TEMPLATE_NAME:?}" "${IMG_URL:?}" "${IMG_SHA256:?}"
  local img_name="${IMG_NAME:-$(basename "$IMG_URL")}"
  local cache="${IMG_CACHE:-/var/lib/vz/template/iso}"
  local src="${cache}/${img_name}"
  local mem="${MEMORY:-2048}" cores="${CORES:-2}" disk="${DISK_SIZE:-20G}"
  local bios="${BIOS:-seabios}" machine="${MACHINE:-pc}"
  local extra_pkgs="${EXTRA_PKGS:-}" renderer="${CI_RENDERER:-}"

  # 1) fetch + verify (cached in $cache; re-download only if missing or checksum drifts)
  if [[ -f "$src" ]] && echo "${IMG_SHA256}  ${src}" | sha256sum -c --status; then
    echo ">> using cached image: $src"
  else
    echo ">> downloading ${img_name}"
    curl -fSL -o "${src}.part" "$IMG_URL"
    echo "${IMG_SHA256}  ${src}.part" | sha256sum -c -
    mv "${src}.part" "$src"
  fi

  local work; work="$(mktemp -d)"; trap 'rm -rf "$work"' RETURN
  local img="$work/disk.qcow2"
  echo ">> copying base image to work area"
  cp "$src" "$img"

  echo ">> downloading sops v${SOPS_VERSION} + age v${AGE_VERSION}"
  curl -fsSL -o "$work/sops" \
    "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64"
  curl -fsSL \
    "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C "$work"

  # cloud-init drop-in: pin the NoCloud/ConfigDrive datasource (+ NM renderer for desktops)
  printf 'datasource_list: [ NoCloud, ConfigDrive ]\n' > "$work/99-pve.cfg"
  if [[ -n "$renderer" ]]; then
    printf 'system_info:\n  network:\n    renderers: [%s]\n' "$renderer" >> "$work/99-pve.cfg"
  fi

  # Parrot ships /etc/apt/sources.list.d/cloudflared.list stamped with its own suite
  # ("echo"), which pkg.cloudflare.com doesn't serve → apt-get update 404s and cloud-init's
  # first-boot package stage dies. Re-stamp to a Debian suite cloudflare serves (bookworm;
  # cloudflared is a static binary). No-op on images without the file (ubuntu/debian).
  echo ">> virt-customize: qemu-guest-agent${extra_pkgs:+,$extra_pkgs} + sops/age + datasource, then seal"
  virt-customize -a "$img" --network \
    --install "qemu-guest-agent${extra_pkgs:+,$extra_pkgs}" \
    --copy-in "$work/sops:/usr/local/bin/" \
    --copy-in "$work/age/age:/usr/local/bin/" \
    --copy-in "$work/age/age-keygen:/usr/local/bin/" \
    --run-command 'chmod 0755 /usr/local/bin/sops /usr/local/bin/age /usr/local/bin/age-keygen' \
    --run-command 'f=/etc/apt/sources.list.d/cloudflared.list; [ -f "$f" ] && sed -i -E "s#(pkg\.cloudflare\.com/cloudflared) +[^ ]+ +main#\1 bookworm main#" "$f" || true' \
    --upload "$work/99-pve.cfg:/etc/cloud/cloud.cfg.d/99-pve.cfg" \
    --run-command 'systemctl enable qemu-guest-agent || true' \
    --run-command 'cloud-init clean --logs || true' \
    --run-command 'truncate -s0 /etc/machine-id' \
    --run-command 'rm -f /etc/ssh/ssh_host_*'

  echo ">> (re)create VM ${VMID}, import disk, attach cloud-init drive, template"
  qm destroy "$VMID" --purge 1 2>/dev/null || true
  qm create "$VMID" --name "$TEMPLATE_NAME" --memory "$mem" --cores "$cores" \
    --net0 "virtio,bridge=${BRIDGE}" --scsihw virtio-scsi-pci --ostype l26 \
    --bios "$bios" --machine "$machine" --agent enabled=1
  if [[ "$bios" == "ovmf" ]]; then
    qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0"
  fi
  qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${img}"
  qm set "$VMID" --ide2 "${STORAGE}:cloudinit"
  qm set "$VMID" --boot order=scsi0
  qm set "$VMID" --serial0 socket --vga serial0
  qm disk resize "$VMID" scsi0 "$disk" 2>/dev/null || true
  qm template "$VMID"
  echo "OK: template ${VMID} (${TEMPLATE_NAME}) built from ${img_name}"
}
