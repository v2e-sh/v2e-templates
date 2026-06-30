#!/usr/bin/env bash
# Build the Ubuntu Server template from the official cloud image. Run ON the Proxmox host.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.env
source "$HERE/config.env"
# shellcheck source=lib/build-template.sh
source "$HERE/lib/build-template.sh"

export VMID="$UBUNTU_VMID" TEMPLATE_NAME="$UBUNTU_NAME"
export IMG_URL="$UBUNTU_URL" IMG_SHA256="$UBUNTU_SHA256"
# cloud image is already cloud-init ready; defaults (seabios, 2048MB, 20G) are fine.
build_template
