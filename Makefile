# v2e template builder. Run these targets ON the Proxmox host (they use qm + virt-customize).
.DEFAULT_GOAL := help

help:
	@echo "Build Proxmox templates from official cloud images (run on the Proxmox host):"
	@echo "  make ubuntu | debian | parrot | all"
	@echo "Edit config.env first (storage, bridge, VMIDs, image URLs/checksums)."

ubuntu:
	bash build-ubuntu.sh
debian:
	bash build-debian.sh
parrot:
	bash build-parrot.sh
vyos:           ## import a VyOS qcow2 (VYOS_URL, or one built by 'make vyos-build') -> template
	bash build-vyos.sh
vyos-build:     ## build the VyOS qcow2 from source (throwaway Debian builder VM; ~20-40 min)
	bash vyos/build-from-source.sh
all: ubuntu debian parrot vyos

lint:
	shellcheck lib/build-template.sh build-*.sh vyos/build-from-source.sh

.PHONY: help ubuntu debian parrot vyos vyos-build all lint
