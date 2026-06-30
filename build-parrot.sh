#!/usr/bin/env bash
# Build the Parrot Home template from the official desktop qcow2. Run ON the Proxmox host.
# Parrot is a DESKTOP image: not cloud-ready, UEFI, btrfs root, NetworkManager. So we
# install cloud-init + network-manager + btrfs-progs and use the NetworkManager renderer.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.env
source "$HERE/config.env"
# shellcheck source=lib/build-template.sh
source "$HERE/lib/build-template.sh"

export VMID="$PARROT_VMID" TEMPLATE_NAME="$PARROT_NAME"
export IMG_URL="$PARROT_URL" IMG_SHA256="$PARROT_SHA256"
export BIOS="ovmf" MACHINE="q35" MEMORY="8192" CORES="4" DISK_SIZE="64G"
export EXTRA_PKGS="cloud-init,network-manager,btrfs-progs"
export CI_RENDERER="network-manager"
build_template
