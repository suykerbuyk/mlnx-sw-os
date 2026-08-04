# Spectrum RDMA investigation

**Status:** 2026-08-03 — desk research plus a **read-only** DCB probe on the
live SN2410. No production switch configuration was changed for this note.

**Scope:** Whether Mellanox / NVIDIA **Spectrum-1** and **Spectrum-2** ASICs
can participate in RDMA fabrics (RoCE / InfiniBand), and how that maps to a
**NVMe-oF over RDMA** proof using **ConnectX-5 EN or newer** hosts.

This document is an investigation record for the `mlnx-sw-os` project. It does
not change the image pipeline. Architecture decisions for the switch OS itself
remain in [`architecture.md`](architecture.md).

---

## 1. Executive answers

| Question | Answer |
|---|---|
| Can Spectrum-1 / Spectrum-2 support **RoCE v2** and RDMA over Ethernet? | **Yes, as the Ethernet fabric.** The ASICs forward lossless / congestion-aware Ethernet; host RNICs (ConnectX, etc.) terminate RDMA. |
| Can the same ASICs be configured for **InfiniBand**? | **No.** Spectrum is Ethernet-only. InfiniBand is the separate **Quantum** product line. |
| Can Spectrum host **IB-mode RDMA**? | **No** — not applicable without an IB fabric. |
| Can Spectrum carry **NVMe-oF RDMA** (NVIDIA RoCE; AMD RoCE NICs)? | **Yes over RoCEv2** on a properly configured Ethernet plane. **Not** via InfiniBand on these switches. |

**One-line summary:** Use Spectrum + ConnectX (Ethernet / RoCE) for
NVMe-oF RDMA proofs. Do not attempt to “put the switch in IB mode.”

---

## 2. Roles: what RDMA actually needs

RDMA is **not** a switch feature that you enable the way you enable a VLAN.
It is a **host-to-host** capability that requires a network path that does not
destroy the traffic under load.

| Component | Responsibility |
|---|---|
| **RNIC** (ConnectX-5 EN+, BlueField, AMD Pensando Pollara, …) | RDMA verbs, queue pairs, DMA, RoCE encapsulation, (usually) DCQCN reaction |
| **Spectrum switch** | Line-rate L2/L3 forward; **PFC** (lossless priority); **ECN** marking; shared buffers; low, predictable latency |
| **Host software** | `mlx5` / OFED stack, `rdma-core`, NVMe initiator/target (`nvme-rdma` / `nvmet-rdma` or SPDK) |

Spectrum ASICs do **not** implement InfiniBand verbs or act as RDMA endpoints.
They are **Ethernet switch** silicon. The Linux Kconfig help text for
`CONFIG_MLXSW_SPECTRUM` states support for Spectrum / Spectrum-2 / Spectrum-3 /
Spectrum-4 **Ethernet Switch ASICs**.

---

## 3. Product lines (do not conflate)

| Line | Fabric | Examples | RDMA relevance |
|---|---|---|---|
| **Spectrum** | Ethernet only | SN2410, SN2700 (Spectrum-1); SN3700C (Spectrum-2); SN4xxx / SN5xxx | RoCE fabric (PFC/ECN/buffers) |
| **Quantum** | InfiniBand | Quantum, Quantum-2, Quantum-X800 | Native IB RDMA fabric |
| **ConnectX / BlueField** | Host adapters (often VPI) | CX-5 EN, CX-6 Dx, CX-7, BlueField-2/3 | Terminate RoCE and/or IB **on the server** |

**VPI (Virtual Protocol Interconnect)** is a property of many **ConnectX**
adapters: the *card* can be bound as Ethernet or InfiniBand. It is **not** a
mode of the Spectrum switch ASIC.

**Spectrum-X** is NVIDIA’s end-to-end **Ethernet AI** platform (typically
Spectrum-4 + SuperNIC/BlueField, adaptive routing, coordinated congestion
control). Spectrum-1/2 support **standard RoCEv2** fabrics; they are **not**
the Spectrum-X stack. A pass on Spectrum-1/2 proves RoCE suitability, not
Spectrum-X claims.

Bridging InfiniBand clusters to Ethernet storage/management is a **gateway**
problem (e.g. NVIDIA Skyway), not a firmware flip on SN2xxx hardware.

---

## 4. RoCE on Spectrum-1 and Spectrum-2

### 4.1 Vendor positioning

Mellanox published Spectrum as a **“RoCE-Ready Switch”**: fabric-side
optimization for RDMA over Converged Ethernet, including:

- Support for **RoCEv1** and **RoCEv2** in the fabric sense (carry and
  accelerate the *network* side of RoCE deployments)
- Simplified RoCE QoS/congestion profiles (on MLNX-OS / Cumulus-style stacks,
  historically a single `roce` style config path)
- **ECN**, including Spectrum **FAST ECN** (mark at **dequeue** / head of
  queue so congestion notification reaches the RNIC sooner than classic
  tail-marking)
- **Fully shared buffers** to absorb microbursts before PFC storms
- Line-rate throughput and low port-to-port latency
- Telemetry aimed at RoCE troubleshooting

Explicit application examples in that material include **NVMe-oF**, ML,
distributed filesystems, and in-memory databases.

Third-party and NVIDIA solution guides have run **NVMe-oF over RoCE** through
Spectrum switches (including SN2010 / SN3700-class) with ConnectX RNICs.

### 4.2 What “support” means technically

| Capability | Spectrum-1/2 | Notes |
|---|---|---|
| Forward RoCEv2 (UDP/4791, routable) | Yes | Needs correct L2 **and** L3 QoS end-to-end |
| Forward RoCEv1 (L2 ethertype) | Yes | Rare on modern stacks; prefer v2 |
| PFC (IEEE 802.1Qbb) | Yes | Required for classical lossless RoCE |
| ETS / DCB | Yes | Priority → TC mapping |
| ECN / DCQCN participation | Yes (silicon + driver path) | Hosts must enable RDMA CC; switch marks |
| Adaptive routing (Spectrum-X) | **No** (gen 1/2) | Spectrum-4 + SuperNIC class feature |
| Terminate RDMA / NVMe-oF | **No** | Host RNICs only |

### 4.3 Live measurement (this project’s fleet)

**2026-08-03, read-only**, `mlnx-2410-cameo` (SN2410, Spectrum-1,
PCI `15b3:cb84`, firmware `13.2010.4406`, Debian 6.1.0-51-amd64,
`mlxsw_spectrum` loaded):

```text
dcb pfc show dev swp1
  pfc-cap 8  macsec-bypass off  delay 0
  prio-pfc 0:off 1:off 2:off 3:off 4:off 5:off 6:off 7:off

dcb ets show dev swp1
  ets-cap 8  ...

dcb buffer show dev swp4
  prio-buffer 0:0 … 7:0
  buffer-size 0:18048b 1:0b …   total-size 28320b
```

Interpretation:

- Under this project’s **Debian + mlxsw** stack, Spectrum-1 **exposes full
  8-priority PFC and ETS** to userspace (`iproute2` `dcb`).
- RoCE is **not configured** on the production plane today (all PFC priorities
  off). Capability is present; policy is not.
- The same driver family and DCB model apply to Spectrum-2 (`15b3:cf6c`, e.g.
  SN3700C); Spectrum-2 was **not** re-probed for this note (no unit on the
  lab management plane). Treat Spectrum-2 as **architecturally equivalent**
  for RoCE fabric features unless a later hardware pass finds a regression.

### 4.4 Project constraints that affect any RoCE lab

From operational rules already recorded for this fleet:

1. **`swp1` on the SN2410 is the production uplink** for the
   `10.10.100.0/22` segment. **Never administratively disable it** and do not
   use it as a RoCE test port without a full outage plan.
2. The production management segment is **locked at MTU 1500**. RoCE / NVMe-oF
   almost always wants **jumbo frames** (commonly 4200+ or 9000). Put the RoCE
   plane on **dedicated ports and a dedicated L2/L3 domain**, not on the
   management subnet.
3. Data and management already share addressing constraints on the live
   switches; do not invent a third identity collision. Lab hosts should use
   **throwaway addressing** on isolated ports.

---

## 5. InfiniBand

**Spectrum-1 and Spectrum-2 cannot be configured as InfiniBand switches.**

Evidence is structural, not a missing config knob:

- Product marketing and silicon lines are separate: **Spectrum = Ethernet**,
  **Quantum = InfiniBand**.
- Kernel and driver naming is Ethernet switchdev (`mlxsw_spectrum`), not an IB
  subnet manager or IB switch stack.
- Industry and NVIDIA materials consistently treat Spectrum-X / Spectrum
  Ethernet as the *Ethernet* alternative to Quantum InfiniBand, not a dual-mode
  ASIC.

Therefore:

- **IB RDMA** (including NVMe-oF over InfiniBand) requires **Quantum** (or
  another IB switch) plus IB-capable HCAs and a subnet manager.
- **ConnectX VPI** on a *server* can still speak IB — but only when cabled into
  an IB fabric, not into Spectrum front-panel Ethernet ports in “IB mode.”

---

## 6. NVMe-oF RDMA (NVIDIA and AMD)

| Transport | On Spectrum-1/2 fabric? |
|---|---|
| **NVMe-oF / RoCEv2** | **Yes** — primary path for this hardware |
| **NVMe-oF / InfiniBand** | **No** on Spectrum |
| **NVMe-oF / TCP** | Yes on any Ethernet; **not** RDMA; out of scope for an RDMA proof |

**NVIDIA path:** ConnectX-5 EN or newer (or BlueField) in Ethernet/RoCE mode,
`nvme-rdma` initiator and `nvmet-rdma` (or SPDK) target, Spectrum leaf with
PFC + ECN + jumbo on lab ports.

**AMD path:** RoCE-capable NICs (e.g. Pensando Pollara class) also target
standards-based Ethernet RoCE. Spectrum is a valid switch; the proof is still
“does RoCEv2 + NVMe-oF work,” not “AMD-specific switch silicon.” Some AMD AI
NIC guidance allows lossy Ethernet with host-side congestion control; a
**lossless PFC + ECN** Spectrum config remains the conservative, ConnectX-aligned
baseline and is what the hardware test plan below assumes.

---

## 7. Hardware test plan — ConnectX-5 EN+ and NVMe-oF RDMA

### 7.1 Purpose

Prove, by **outcome**, that:

1. Two hosts with **Mellanox / NVIDIA ConnectX-5 EN or better** establish
   **RoCEv2** through a Spectrum-1 or Spectrum-2 switch running this project’s
   Debian + `mlxsw` stack.
2. **NVMe-oF over RDMA** can serve block I/O from a target host to an
   initiator host across that path.
3. The result depends on fabric behavior (negative control), not idle-link luck.

This is a **lab** plan. It is not a production rollout for the live
`10.10.100.0/22` management segment.

### 7.2 Success criteria

| ID | Criterion | How verified |
|---|---|---|
| S1 | RoCE devices present on both hosts | `ibv_devinfo`, `rdma link` show Ethernet/RoCE (not IB-only) |
| S2 | Path MTU ≥ 9000 end-to-end | `ping -M do -s 8972` between RoCE IPs |
| S3 | RDMA bandwidth non-zero and stable | `ib_write_bw` / `ib_read_bw` ≥ 60 s, no abort |
| S4 | NVMe-oF connect over **rdma** | `nvme connect -t rdma …`; `nvme list-subsys` shows `rdma` |
| S5 | Sustained block I/O | `fio` against the connected namespace; QP/RNIC counters move |
| S6 | Negative control | Disable PFC (or induce drop) under load → errors/collapse; restore → recover |

**Non-goals:** Spectrum-X adaptive routing; multi-hop leaf-spine fairness at
scale; IB fabrics; production cutover of storage onto the management plane.

### 7.3 Bill of materials

| Role | Minimum | Preferred notes |
|---|---|---|
| **Switch under test (SUT)** | SN2410 or SN2700 (Spectrum-1), or SN3700C (Spectrum-2) | **Spare front-panel ports only.** Never the SN2410 production uplink (`swp1`). Prefer ports with **no** carrier to production gear. |
| **Initiator host** | x86_64 server + **ConnectX-5 EN** (or CX-6 / CX-7 / BlueField EN) | Dual-port useful but not required. Match optic/DAC to switch port speed (25G/100G). |
| **Target host** | Second server + same-class ConnectX EN | Local NVMe (or a spare NVMe) for a real namespace; SPDK null/malloc OK for fabric-only smoke. |
| **Cables** | 2× DAC or AOC appropriate to speed | Avoid mixing breakouts until the simple 1:1 topology works. |
| **Optional** | Third host or second NIC port | Congestion generator for S6 / ECN observation. |

**Software (hosts):** modern Linux (Debian 12/13 or similar) with:

- Kernel modules: `mlx5_core`, `mlx5_ib`, `ib_uverbs`, `ib_core`, `nvme`,
  `nvme-rdma`, `nvmet`, `nvmet-rdma` (names may vary slightly by package set)
- Userspace: `rdma-core`, `perftest` (`ib_write_bw`, …), `nvme-cli`, `fio`
- Either in-tree mlx5 **or** NVIDIA OFED — pick one stack and stick to it for
  the run; do not mix half-installed OFED with distro packages.

**Software (switch):** this project’s Debian image with `mlxsw` loaded (as on
the live fleet). Tooling: `iproute2` (`ip`, `bridge`, `dcb`), `ethtool`.

### 7.4 Topology

```text
   Initiator (ConnectX-5 EN+)              Target (ConnectX-5 EN+)
   roce0  192.168.77.10/24                 roce0  192.168.77.20/24
   MTU 9000                                MTU 9000
        |                                       |
        | DAC/AOC                               | DAC/AOC
        v                                       v
   swpA (SUT lab port)  ---- Spectrum ----  swpB (SUT lab port)
                            L2 bridge
                         (or L3 /30s)
                         MTU 9000
                         PFC on RoCE prio
                         ECN on that TC
```

**Addressing:** dedicated `192.168.77.0/24` (example only). **No** default
route into production management. **No** shared L2 with `mgmt`/`data` on the
live switches unless you deliberately accept that blast radius (default: do
not).

**L2 vs L3:** start with a **simple bridge** between `swpA` and `swpB` for the
shortest proof. Add L3 SVIs later if you need to prove RoCEv2 routing + DSCP
rewrite.

### 7.5 Safety checklist (before any link comes up)

- [ ] Identify lab ports by silkscreen / `ethtool` / LLDP; write them down.
- [ ] Confirm **neither** lab port is the SN2410 uplink (`swp1`) or any port
      that currently carries production traffic (`swp4`, `swp48`, `swp49` on
      the 2410 have had carrier in ops notes — verify live before use).
- [ ] Confirm lab hosts are **not** bridging the RoCE NIC into the management
      network.
- [ ] Have console or known-good SSH on the switch **via mgmt**, independent of
      the lab ports.
- [ ] Snapshot current `ip link`, bridge membership, and `dcb * show` on the
      lab ports so rollback is copy-paste.

### 7.6 Switch configuration outline

Exact TC/priority numbers must match the host DSCP/priority profile. The common
ConnectX RoCE profile uses a **dedicated priority** (often **3**) for RoCE and
leaves best-effort lossy.

Illustrative sequence (adapt names; **lab ports only**):

```sh
# 1. Bring lab ports up with jumbo MTU
ip link set dev swpA up mtu 9000
ip link set dev swpB up mtu 9000

# 2. Minimal L2 path (example: dedicated bridge, not br0/production)
ip link add name br-roce type bridge
ip link set br-roce up mtu 9000
ip link set swpA master br-roce
ip link set swpB master br-roce

# 3. PFC on RoCE priority only (example: priority 3)
dcb pfc set dev swpA prio-pfc 0:off 1:off 2:off 3:on 4:off 5:off 6:off 7:off
dcb pfc set dev swpB prio-pfc 0:off 1:off 2:off 3:on 4:off 5:off 6:off 7:off

# 4. ETS / priority-to-TC mapping as required by your DCB profile
#    (use `dcb ets set …` per current iproute2/mlxsw docs for your kernel)

# 5. APP TLV / DSCP so RoCE (UDP/4791) lands on priority 3
#    (use `dcb app add …` — match the ConnectX trust mode: PCP vs DSCP)

# 6. Record
dcb pfc show dev swpA
dcb pfc show dev swpB
dcb ets show dev swpA
dcb buffer show dev swpA
```

If a step is rejected by `mlxsw` on a given kernel, stop and record the exact
error — that is a first-class finding for this project (Debian/mlxsw surface
vs MLNX-OS one-click RoCE).

### 7.7 Host configuration outline

On **both** initiator and target (interface name `roce0` is an example):

```sh
# Identity of the RNIC
ibv_devinfo
rdma link show
ibdev2netdev   # if available

# IP + jumbo
ip link set dev roce0 up mtu 9000
ip addr add 192.168.77.10/24 dev roce0   # .20 on target

# Confirm RoCE, not IB link layer
# ibv_devinfo "link_layer: Ethernet" is the expected mode for CX EN cards
```

Enable the NVIDIA/Mellanox recommended **RoCE congestion control** for that
NIC generation (DCQCN). Exact sysfs/OFED knobs vary by driver package —
follow the ConnectX RoCE config guide for the installed stack, and record the
commands used.

Optional but useful: set the NIC to trust the same field the switch classifies
on (PCP vs DSCP) so priority 3 is consistent end-to-end.

### 7.8 Execution ladder

#### Phase A — wire and L3 smoke

1. Cable initiator → `swpA`, target → `swpB`.
2. Carrier up on both sides; switch `ip link` shows LOWER_UP.
3. `ping -c 5 192.168.77.20` from initiator.
4. `ping -M do -s 8972 -c 3 192.168.77.20` (S2).

**Abort if:** no carrier, wrong port, or MTU blackhole.

#### Phase B — pure RDMA (no NVMe yet)

On target:

```sh
ib_write_bw -d <ibdev> -F --report_gbits
```

On initiator:

```sh
ib_write_bw -d <ibdev> -F --report_gbits 192.168.77.20
```

Repeat with `ib_read_bw`. Run ≥ 60 seconds under load (S3).

Record: bandwidth, CPU%, any retransmit/retry counters from
`ethtool -S` / RNIC debugfs / `rdma statistic` if available.

#### Phase C — NVMe-oF target

On **target**, using kernel `nvmet` (SPDK is an alternative; document which):

1. Load `nvmet`, `nvmet-rdma`.
2. Create a subsystem NQN, namespace backed by:
   - a real NVMe ns (`/dev/nvme0n1` or a partition), or
   - a file/loop for a weaker but still valid fabric test.
3. Create a port with **`trtype=rdma`**, `traddr=192.168.77.20`,
   `trsvcid=4420` (or another free port), address family IPv4.
4. Enable the subsystem and port.

Example shape (paths vary; treat as outline, not a paste-blind script):

```sh
modprobe nvmet
modprobe nvmet-rdma
# mkdir/configfs under /sys/kernel/config/nvmet/ …
# set attr_trtype = rdma, attr_adrfam = ipv4, attr_traddr, attr_trsvcid
```

#### Phase D — NVMe-oF initiator

On **initiator**:

```sh
modprobe nvme
modprobe nvme-rdma

nvme discover -t rdma -a 192.168.77.20 -s 4420
nvme connect  -t rdma -a 192.168.77.20 -s 4420 -n <subsysnqn>

nvme list
nvme list-subsys   # must show rdma, not tcp  (S4)
```

#### Phase E — block I/O proof

```sh
fio --name=nvmeof-rdma --filename=/dev/nvmeXnY --rw=randread \
    --bs=4k --iodepth=32 --numjobs=4 --time_based --runtime=60 \
    --group_reporting
```

Also run a sequential large-block write/read. Confirm:

- IOPS/BW are non-trivial relative to a local baseline (same drive type if possible).
- RNIC/switch counters move during the run (S5).

#### Phase F — negative control (S6)

Under continuous `fio` or `ib_write_bw`:

1. Turn **PFC off** on the RoCE priority on `swpA`/`swpB`, **or** introduce
   deliberate congestion without ECN/PFC.
2. Expect RDMA retries, NVMe disconnects, or severe throughput collapse.
3. Restore PFC/ECN; reconnect if needed; confirm recovery.

This step is what separates “two hosts on a quiet link” from “the Spectrum
fabric is doing the RoCE job.”

### 7.9 Artifact pack (what to keep)

| Artifact | Contents |
|---|---|
| Topology note | Switch model, ASIC, port IDs, cable type, host PCI IDs (`lspci -nn \| grep -i mellanox`) |
| Switch pre/post | `ip link`, bridge, full `dcb pfc/ets/buffer show` on lab ports |
| Host RDMA | `ibv_devinfo`, `rdma link`, driver package versions |
| Perftest logs | `ib_write_bw` / `ib_read_bw` stdout |
| NVMe | `nvme discover/list/list-subsys`, connect command line |
| fio | job file + summary |
| Negative control | What was broken, symptoms, recovery |
| Limitations | Explicit list of what this run did **not** prove |

### 7.10 Suggested port map for *this* fleet (planning only)

Do **not** treat this as authorization to rewire production. It is a starting
point for a controlled lab window:

| Switch | Avoid | Prefer for lab |
|---|---|---|
| SN2410 (`mlnx-2410-cameo`) | `swp1` (uplink); any port with live carrier to production | Dark 25G/100G ports verified with no LLDP neighbor / no carrier |
| SN2700 (`mlnx-2700-cameo`) | Ports toward the 2410 / production | Same — dark ports only |

If no dark ports exist, use a **bench Spectrum** or schedule a maintenance
window with physical presence — do not steal the uplink “for a quick test.”

### 7.11 Effort estimate

| Phase | Rough effort |
|---|---|
| Hardware assembly + cabling | 1–2 h |
| Switch + host DCB/RoCE bring-up | 2–4 h (first time; less if profile is known) |
| Phases A–E | 2–3 h |
| Phase F + write-up | 1–2 h |
| **Total first pass** | **~1 working day** with two servers and known-good DACs |

---

## 8. Implications for `mlnx-sw-os`

| Topic | Implication |
|---|---|
| Image pipeline | **No change required** for RDMA; switch is a fabric element. |
| DKMS / mlxsw | Already exposes DCB (`dcb pfc` works on live Spectrum-1). Worth regression-testing after major kernel bumps. |
| Runtime contract | Today’s network units target **switch front-panel Ethernet** for L2/L3 ops, not a pre-baked RoCE profile. A future optional “RoCE leaf” profile (PFC/ECN/MTU on selected ports) could be a **separate task**, not a silent default on production uplinks. |
| Documentation | This file is the standing investigation record; amend when Spectrum-2 is probed or when the hardware test is executed. |

---

## 9. Open items

1. **Spectrum-2 live DCB probe** on SN3700C (or other Spectrum-2) when hardware
   is on the bench — confirm `pfc-cap` / buffer behavior matches Spectrum-1.
2. **Execute §7** with ConnectX-5 EN+ and attach results (pass/fail + artifacts).
3. Decide whether a **RoCE lab profile** belongs in-tree (scripts/docs only vs
   optional stage assets) — **operator call**; default remains off on production
   planes.
4. ECN configuration surface under pure Debian/`dcb` for mlxsw: document the
   exact commands that work on 6.1 vs 6.12 once exercised (desk research asserts
   silicon support; the first lab run should paste the working sequence).

---

## 10. References

| Source | Why it matters |
|---|---|
| Mellanox *Spectrum — The RoCE-Ready Switch* (solution brief) | Vendor fabric claims: RoCEv1/v2, FAST ECN, shared buffer, NVMe-oF use case |
| Linux `CONFIG_MLXSW_SPECTRUM` help text | ASIC class is Ethernet switch, Spectrum-1…4 |
| NVIDIA product split (Spectrum Ethernet vs Quantum InfiniBand) | IB is a different line; Spectrum is not dual-mode IB |
| NVIDIA NVMe-oF / RoCE solution material (ConnectX + Spectrum) | End-to-end storage over RoCE is a supported design pattern |
| Live fleet probe 2026-08-03 (`mlnx-2410-cameo`) | `pfc-cap 8` / `ets-cap 8` under this project’s Debian + mlxsw |
| Project `docs/architecture.md` | Switch OS architecture; dual-plane networking; production constraints |
| Project operational rules (resume / doctrine) | Uplink `swp1`, MTU 1500 on management segment, production-change discipline |

---

## 11. Document history

| Date | Change |
|---|---|
| 2026-08-03 | Initial investigation: RoCE yes, InfiniBand no, NVMe-oF/RoCE feasible; ConnectX-5 EN+ hardware test plan drafted. Read-only SN2410 DCB probe recorded. |
