#!/usr/bin/env bash
# Build the Debian template from the official cloud image. Run ON the Proxmox host.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.env
source "$HERE/config.env"
# shellcheck source=lib/build-template.sh
source "$HERE/lib/build-template.sh"

export VMID="$DEBIAN_VMID" TEMPLATE_NAME="$DEBIAN_NAME"
export IMG_URL="$DEBIAN_URL" IMG_SHA256="$DEBIAN_SHA256"
# cloud image is already cloud-init ready; defaults are fine.
build_template
