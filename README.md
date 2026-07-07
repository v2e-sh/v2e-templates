# v2e-templates — Proxmox VM template builder

Builds Proxmox VM **templates** from official **cloud images** (and a source-built VyOS)
using `virt-customize` + `qm`, entirely host-side. No Packer, no API token, no build network —
the images are customized offline and imported with `qm`.

## What it produces

For each OS, a Proxmox **template** that Terraform clones into a node. The template is the
image artifact — on Proxmox there is no separate registry; `qm template` *is* the handoff.

| Template | VMID (staging) | Promotes to | Base image |
|----------|----------------|-------------|------------|
| Ubuntu Server 24.04 | 9901 | 9001 | official cloud image |
| Debian 13 | 9902 | 9002 | official cloud image |
| Parrot Home 7.2 | 9903 | 9003 | official desktop qcow2 |
| VyOS | 9900 | 9000 | *special — see below* |

## The flow

Each `make <os>` runs, **on the Proxmox host**:

```
fetch     download the official image by pinned URL + SHA256, verify, cache in IMG_CACHE
customize virt-customize OFFLINE: install qemu-guest-agent (+ extras), copy in sops & age,
          pin the NoCloud cloud-init datasource, then SEAL (machine-id, ssh host keys)
import    qm create + import the disk + attach a cloud-init drive
template  qm template   ->  the artifact Terraform clones
```

No Packer, **no Proxmox API token, no build network** — it's all local `qm` + `virt-customize`
as root. The image is customized *offline* (never booted), so there's nothing to network into.

## Use it / reproduce on another host

1. Copy this repo onto the Proxmox host (or `git clone` there).
2. Edit **`config.env`**: `STORAGE`, `BRIDGE`, the per-image `*_VMID`, and (if you want
   different versions) the image `*_URL` + `*_SHA256`.
3. Run on the host:
   ```sh
   make ubuntu      # or: make debian | make parrot | make all
   ```
   It auto-downloads the official image (no manual download needed), verifies the checksum,
   builds the template. Re-runs reuse the cached image.

**Requirements on the host:** root, internet, `libguestfs-tools` (`virt-customize`), and a
storage with a `cloudinit` drive capable backend (e.g. `local-lvm`).

### Promote staging → production

Builds target `9900-9903` so they never clobber in-use `9000-9003`. Once verified, either
point Terraform at the staging VMID (`ubuntu_template_id = 9901`), or edit the `*_VMID` in
`config.env` to the prod IDs and re-run `make`:
```sh
sed -i 's/^UBUNTU_VMID=.*/UBUNTU_VMID="9001"/' config.env && make ubuntu
```
VMIDs come from `config.env` (each `build-*.sh` re-sources it), so a `VMID=…` on the command
line is ignored.

## Layout

```
config.env            all tunables (storage, bridge, versions, per-image VMID/URL/sha256)
lib/build-template.sh shared engine: fetch+verify -> virt-customize -> import -> template
build-ubuntu.sh       thin: Ubuntu params -> build_template
build-debian.sh       thin: Debian params
build-parrot.sh       Parrot params (UEFI, NetworkManager renderer, btrfs-progs, +cloud-init)
Makefile              make ubuntu|debian|parrot|all|lint
```

## Per-image notes

- **Ubuntu / Debian** — official cloud images, already cloud-init ready. Minimal bake
  (agent + sops/age). Fast (~2 min).
- **Parrot Home** — official *desktop* qcow2: not cloud-ready, UEFI (ovmf/q35), btrfs root,
  NetworkManager. We install `cloud-init` + `network-manager` + `btrfs-progs` and set the
  NetworkManager cloud-init renderer. First boot runs a package upgrade if the clone has
  Proxmox's `ciupgrade` on — set `ciupgrade=0` in Terraform to skip it (Ansible owns patching).
- **VyOS** — *not* in this pattern (no cloud image upstream). Built **from source** via
  `vyos/build-from-source.sh` (a throwaway Debian builder VM runs `vyos-build` in Docker →
  cloud-init qcow2), then `build-vyos.sh` imports it. **Trust-me users** instead leave the
  source build alone — set `VYOS_URL` in `config.env` to the published release qcow2 (+
  `VYOS_SHA256`) and `build-vyos.sh` fetches and verifies it. `make vyos-build` builds it;
  `make vyos` imports it.

## Verifying a template

Clone it with a cloud-init drive and confirm cloud-init applies an IP:
```sh
qm clone <VMID> 9950 --name verify
qm set 9950 --ide2 local-lvm:cloudinit --ipconfig0 ip=10.0.0.50/24,gw=10.0.0.1 --ciuser verify --cipassword verify
qm start 9950
qm guest exec 9950 -- cloud-init status   # -> done ; ip shows 10.0.0.50 ; sops/age present
qm stop 9950 && qm destroy 9950 --purge
```
