# mlnx-sw-os

Open-source **Debian image builder** for **Mellanox / NVIDIA Spectrum** enterprise
switches — Spectrum-1 through Spectrum-4 ASICs.

The goal is a **repeatable, scriptable** process that produces a bootable image
you can `dd` onto the switch, with `mlxsw` switchdev drivers, dual-plane
networking, and an upgrade path that does **not** require re-imaging. Hardware
validation so far covers **Spectrum-1 and Spectrum-2** only; Spectrum-3 and
Spectrum-4 are supported by the same driver build (PCI IDs in tree) but have
not yet been tested on this pipeline.

> **Inspired by** the [IPng Networks SN2700 write-up](https://ipng.ch/s/articles/2023/11/11/debian-on-mellanox-sn2700-32x100g/).

## Why this exists

Debian does **not** ship the `mlxsw` driver. Stock configs carry
`# CONFIG_MLXSW_CORE is not set`, while every dependency mlxsw needs
(`NET_SWITCHDEV`, `VXLAN`, `PTP`, …) is already enabled. Putting Spectrum
switches on pure upstream Debian therefore needs a first-class way to build and
maintain that driver — not a one-off kernel fork that freezes while Debian
moves on.

This project answers that with a stock kernel, a small DKMS package, and a
slaved-VM image pipeline designed to stay maintainable as open source.

## Status

| Track | State |
|---|---|
| **Debian 12 (bookworm) on hardware** | Proven in the field — SN2410 (56 ports) and SN2700 (32 ports) |
| **Debian 13 (trixie) driver path** | Proven to module load under QEMU (6.12, **zero source patches**) |
| **Image pipeline (trixie)** | Stages land incrementally; full automated end-to-end boot test still in progress |
| **Port enumeration on trixie** | Hardware-only — QEMU has no Spectrum ASIC |

Target for new images is **trixie only**. Live fleet switches remain on bookworm
until re-imaged with the trixie artifact.

## Target hardware

One `mlxsw_spectrum` build covers Spectrum-1 through Spectrum-4 (PCI IDs
`cb84` / `cf6c` / `cf70` / `cf80`). Port count is absorbed by a `Name=swp*`
network glob — **no per-model image**. Tested platforms below are Spectrum-1
and Spectrum-2; later generations share the same artifact.

| Model | ASIC | Ports | Boot | Field status |
|---|---|---|---|---|
| SN2410 | Spectrum-1 | 48×25G + 8×100G | BIOS | ✅ tested / in service |
| SN2700 | Spectrum-1 | 32×100G | BIOS | ✅ tested / in service |
| SN3700C | Spectrum-2 | 32×100G | UEFI (believed) | ⏳ untested on this pipeline |
| *(any Spectrum-3/4 SKU)* | Spectrum-3 / 4 | model-dependent | BIOS or UEFI | ⏳ driver-supported, not yet tested |

Shared platform: Intel Celeron 1047UE @ 1.4 GHz, 8 GB RAM, 512 GB SATA SSD.

## What makes this different

### 1. Stock Debian kernel + DKMS — not a fork

Ship Debian’s kernel untouched. Deliver mlxsw as **`mlxsw-dkms`**, a ~350 KB
source package that rebuilds against whatever kernel `apt` installs.

- **Zero source patches** against Debian’s own `linux-source` tree (verified by
  tree diff on both 6.1 and 6.12).
- Object list is **derived** from the kernel’s own `Makefile`
  (`scripts/mlxsw-objs.awk`), not hand-maintained — a series bump cannot
  silently drop objects.
- Rebuild on the switch itself is ~2 minutes at `-j2` — automatic on every
  `apt upgrade` via DKMS `AUTOINSTALL`.
- Requires the **`linux-headers-amd64` metapackage** (never a versioned
  `linux-headers-$(uname -r)` alone), so headers track the image package and
  rebuilds do not fail silently.

Package generator: `scripts/mk-mlxsw-dkms.sh`  
Artifacts: `mlnx-switch-packages/dkms/`

### 2. Slaved-VM pipeline from an official cloud image

The image is **not** assembled with a distro-specific bootstrapper
(`mmdebstrap`, etc.). Instead:

1. Fetch Debian’s official **`generic`** cloud qcow2 (checksum-verified).
2. Boot it under **QEMU** with a cloud-init NoCloud seed (SSH key for a build user).
3. Drive the guest over plain **ssh**.
4. Install packages, configs, and the DKMS driver inside a real booted OS.
5. Generalize and export a raw disk image ready to `dd`.

**Build-host dependencies:** `qemu`, `xorriso`/`xorrisofs`, `curl` — no
archive keyring on the host, no cross-distro packaging stack.

The distro-specific surface is deliberately tiny (base-image URL + package
commands in `scripts/vm.sh`), so the pipeline is not locked to a Debian-only
bootstrap path.

### 3. One artifact, both boot modes

The `generic` base is GPT with **both** a BIOS boot partition and an ESP.
`grub-cloud-amd64` already dual-installs GRUB for PC and EFI. The pipeline
**asserts** that bootloader rather than reinventing it — one image for SN2410 /
SN2700 (BIOS) and SN3700C (UEFI).

Identity is **not** baked in: hostname is derived from DMI at first boot;
addressing is DHCP. No MAC assignments are shipped (so every switch does not
clone the same L2 identity).

### 4. Lean image, grown on first boot

Ship a small (~8 GB) image; on first boot **`systemd-repart`** grows the root
partition and **`x-systemd.growfs`** grows the filesystem to fill the disk.

- Root must be the **last** partition; swap is a **file**, never a partition
  after root (otherwise growth fails silently).
- Growth tooling is systemd-native on purpose — not Debian-only
  `cloud-initramfs-growroot` / `growpart`.

### 5. Dual-plane networking that survives driver failure

| Plane | How | Why it matters |
|---|---|---|
| **Management** | `active-backup` bond over the two 1 GbE ports (`e1000e`) | Stock in-tree drivers — SSH survives mlxsw / data-plane loss |
| **Data** | All front-panel `swp*` ports bridged | Glob-matched; one config for 32- or 56-port models |

Units match on **`Driver=`**, not hand-enumerated names. Data is IPv4 DHCP with
**no default route** (`UseRoutes`/`UseGateway` off); management holds routing.
`swp*` stay MTU 9000 (transit); the data bridge’s own L3 interface is MTU 1500
so it does not blackhole a 1500-only management segment.

Port naming: udev rule on `mlxsw_spectrum*` → `sw` + `phys_port_name` → `swpN`.

### 6. Self-maintenance after the first image

Once imaged, the switch stays on **`apt update && apt upgrade`**:

- New kernels install through Debian.
- DKMS rebuilds mlxsw against the new headers.
- A four-rung **userspace recovery ladder** handles the “booted fine, modules
  missing” failure (detect → `dkms autoinstall` → optional `grub-reboot` to
  last-known-good → stay reachable and fail loudly). GRUB alone cannot catch
  that class of failure — the kernel *does* boot.

## Repository layout

```
assets/                 # networkd units, udev, GRUB drop-ins, repart, first-boot bits
docs/architecture.md    # decisions, evidence, risks (authoritative deep dive)
mlnx-switch-packages/   # built mlxsw-dkms .debs (installable + frozen fixtures)
scripts/
  vm.sh                 # slaved VM: fetch | up | ssh | provision | probe | …
  mk-mlxsw-dkms.sh      # build / restamp the DKMS package
  mlxsw-objs.awk        # derive object list from kernel Makefile
  stage-runtime-contract.sh
  stage-grub-fallback.sh
  stage-generalize.sh
  mlxsw-premise-audit.sh
tests/test-derive.sh    # offline derivation / package fixture regression
```

Legacy proof-of-concept scripts (`build.image.sh`, `deb12_image_builder.sh`)
remain for reference; the active path is `scripts/vm.sh` plus the stage
scripts above.

## Quick start (build host)

```bash
# Host needs: qemu-system-x86_64, xorriso (or xorrisofs), curl, ssh
# Work dir defaults to /var/tmp/mlnx-sw-os-vm (not /tmp — avoid tmpfs)

./scripts/vm.sh fetch      # download + verify official cloud image
./scripts/vm.sh up         # boot with NoCloud seed, wait for ssh
./scripts/vm.sh provision  # full-upgrade, headers, build tooling
./scripts/vm.sh probe      # record disk/layout facts
./scripts/vm.sh status

# Drive stages over the guest (ordering matters; see docs/architecture.md)
# ./scripts/stage-runtime-contract.sh run
# ./scripts/stage-grub-fallback.sh …
# ./scripts/stage-generalize.sh prepare | strip | verify | export
```

Offline tests (no VM, no root, no network):

```bash
./tests/test-derive.sh
./scripts/stage-runtime-contract.sh selftest
./scripts/stage-grub-fallback.sh selftest
./scripts/stage-generalize.sh selftest
```

## Design principles (short)

1. **Floor, never ceiling** on kernel-header dependencies — an upper bound makes
   apt *remove* the driver package at the next series bump.
2. **Assert by outcome**, not by a tool’s exit status alone.
3. **Never bake passwords** — root + operator account, SSH key only.
4. **Management plane uses stock drivers** so a broken data plane is recoverable.
5. **Prefer systemd-native mechanisms** over Debian-only helpers where the
   pipeline must stay portable in spirit.

## Documentation

| Document | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Full architecture: AD-1…AD-5, network model, package spec, risks, measurements |
| [Mellanox mlxsw wiki](https://github.com/Mellanox/mlxsw/wiki) | Upstream driver / firmware reference |

## Out of scope (for now)

- Control-plane routing stacks (FRR, BGP, …) — this image is the foundation
- ASIC firmware updates
- Shipping a non-Debian switch OS as a supported deliverable

## License

See repository license files when present; package and script provenance is
intended for open reuse alongside upstream Debian and Linux sources.
