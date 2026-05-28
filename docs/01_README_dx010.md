# Celestica Seastone DX010

## Overview

The Celestica Seastone DX010 is a 1U top-of-rack (ToR) data center switch with 32 QSFP28 ports, providing 3.2 Tbps of aggregate switching capacity. It is built around the Broadcom BCM56960 Tomahawk ASIC and is designed for open networking: the switch ships with ONIE (Open Network Install Environment) and supports network operating systems such as SONiC and ONL.

The DX010 belongs to the 100G generation of data center switches. Each of its 32 front-panel ports operates at 100 Gb/s using QSFP28 transceivers, and the ASIC supports flexible breakout configurations down to 25G or 10G per lane. This makes it suitable for both leaf-layer (server-facing) and spine-layer (aggregation) roles in spine–leaf data center fabrics.

| Attribute             | Value                                             |
| --------------------- | ------------------------------------------------- |
| Vendor                | Celestica                                         |
| Model                 | Seastone DX010                                    |
| Form Factor           | 1U rack-mount                                     |
| Switching ASIC        | Broadcom BCM56960 (Tomahawk I)                    |
| Front-Panel Ports     | 32x QSFP28 (100G each)                            |
| Total Throughput      | 3.2 Tbps                                          |
| Management CPU        | Intel Atom C2000 (Rangeley), dual-core, 1.7 GHz   |
| RAM                   | 4 GB DDR3L-1600 ECC SO-DIMM (expandable to 16 GB) |
| Storage               | mSATA SSD                                         |
| Power Supplies        | 2x 800W Delta (redundant, hot-swappable)          |
| Cooling               | 5x hot-swappable fan modules, front-to-rear       |
| Software              | ONIE, SONiC, ONL                                  |

## Physical Layout

### Front Panel

The front panel is divided into two zones:

| Zone   | Ports                                                                                  |
| ------ | -------------------------------------------------------------------------------------- |
| Center | 32x QSFP28 data ports (two rows of 16)                                                 |
| Right  | 1x RJ45 management, 1x RJ45 serial console, 1x USB Type-A, 1x SFP (management uplink)  |

The 32 QSFP28 cages in the center connect directly to the Tomahawk ASIC and carry all data-plane traffic. The management RJ45, console RJ45, USB, and SFP ports are wired to the Intel Atom management CPU and operate independently of the data path. The SFP cage provides an optional fiber-based out-of-band management link for environments where copper is impractical; it is not commonly used under SONiC.

<img src="../pics/Celestica-Seastone-DX010-Front-Ports.jpg" alt="DX010 front panel with 32 QSFP28 ports" width="700">

### Rear Panel

The rear panel holds the two power supply bays on opposite sides and five hot-swappable fan modules in the center. The power supplies are placed on opposite ends to simplify A+B redundant power cabling in rack deployments. Each PSU has an orange ejector handle (release latch) that allows the unit to be unlatched and slid out under power for hot-swap replacement. The orange color is an industry convention for marking field-serviceable, hot-swappable components.

<img src="../pics/Celestica-Seastone-DX010-Rear.jpg" alt="DX010 rear panel with PSUs and fan modules" width="700">

## Two-Board PCB Architecture

Internally, the DX010 uses a two-PCB design that physically separates the data plane from the control plane. Understanding this split is helpful context for the component sections that follow.

<img src="../pics/Celestica-Seastone-DX010-Two-PCBs-2.jpg" alt="DX010 lower control-plane PCB" width="500">

### Upper PCB: Data Plane (Switching Board)

The upper board carries the Broadcom Tomahawk ASIC and the 32 QSFP28 front-panel connectors. All 128 high-speed SerDes lanes are routed across this board from the centrally placed ASIC to the front-panel cages.

### Lower PCB: Control Plane (Management Board)

The lower board carries the management CPU complex (Intel Atom C2000), RAM, storage, power regulation, and fan/thermal management circuitry. This board is thinner and simpler because it handles only low-speed management traffic and I2C communication with the transceivers.

### Board Interconnect

The two boards connect via an internal board-to-board connector. The ASIC on the upper board communicates with the CPU on the lower board over a PCIe link, which the NOS uses to program forwarding tables, read counters, and manage the ASIC.

## Switching ASIC: Broadcom Tomahawk (BCM56960)

The BCM56960, marketed as Tomahawk (first generation), is a data center Ethernet switch SoC from Broadcom's StrataXGS product line. It is the specific NPU used in the DX010 and the component that performs all packet forwarding. Understanding this ASIC is essential because its capabilities and constraints define everything the switch can and cannot do.

<img src="../pics/Celestica-Seastone-DX010-Tomahawk-Heatsink-1.jpg" alt="Tomahawk ASIC under heatsink" width="500">

### SerDes Lanes

The BCM56960 contains exactly 128 SerDes lanes at 25 Gb/s each (NRZ signaling). Each port macro controls four lanes and maps to one QSFP28 cage. This yields:

- **128 lanes total** — the full I/O budget of the chip
- **4 lanes per port** — each QSFP28 port bonds 4 lanes for 100G (4 × 25G)
- **32 port macros** — one per QSFP28 cage, each controlling 4 lanes

> For background on SerDes operation, lane bonding, and port macro architecture, see [SerDes and Lanes](https://github.com/ManiAm/net-lab-switch-serdes/blob/master/docs/02_README_serdes.md)

### Port Breakout

Each 4-lane port macro supports the following breakout modes:

| Breakout Mode | Logical Ports | Lanes per Logical Port | Speed per Logical Port |
| ------------- | ------------- | ---------------------- | ---------------------- |
| 1x 100G       | 1             | 4 (4 × 25G NRZ)        | 100G                   |
| 1x 40G        | 1             | 4 (4 × 10G NRZ)        | 40G                    |
| 2x 50G        | 2             | 2 (2 × 25G NRZ)        | 50G                    |
| 4x 25G        | 4             | 1 (1 × 25G NRZ)        | 25G                    |
| 4x 10G        | 4             | 1 (1 × 10G NRZ)        | 10G                    |

At maximum breakout (all 32 ports split to 4x25G), the switch exposes 128 logical ports at 25G each — still totaling 3.2 Tbps.

**BCM56960 constraint:** Within a single port macro, all four lanes must run at the same base signaling rate (all 25G NRZ or all 10G NRZ). Mixed lane rates within one cage are not supported. Each port macro is independently configurable: port 1 can be 1x100G while port 2 is 4x25G, because they use separate Falcon SerDes cores.

> For a general explanation of breakout mechanics, constraints, and cabling, see [SerDes and Lanes — Ports and Breakout](https://github.com/ManiAm/net-lab-switch-serdes/blob/master/docs/02_README_serdes.md#ports-and-breakout)

### FEC Configuration

The BCM56960 supports two FEC modes:

| FEC Mode           | IEEE Clause | Algorithm         | Correction Strength | Latency   |
| ------------------ | ----------- | ----------------- | ------------------- | --------- |
| FC-FEC (Base-R)    | Clause 74   | FireCode          | Low (~1 error burst per frame) | ~50–100 ns |
| RS-FEC             | Clause 91   | Reed-Solomon      | High (corrects multi-symbol burst errors) | ~100–200 ns |

**RS-FEC (CL91)** is the standard for 100G Ethernet (IEEE 802.3bj). It uses an RS(528,514) code — for every 514 data symbols transmitted, 14 parity symbols are appended, allowing the receiver to correct substantial burst errors. This is the correct default for 100G QSFP28 links.

**FC-FEC (CL74)** is a simpler, older code originally designed for 10GBASE-KR. It has lower latency but weaker correction. It is occasionally used for 25G single-lane links where latency sensitivity outweighs error correction strength.

> For background on FEC principles, NRZ vs PAM4 requirements, and why both ends must match, see [Digital Signal Fundamentals — FEC](https://github.com/ManiAm/net-lab-switch-serdes/blob/master/docs/03_signal_basics.md#forward-error-correction-fec).


### Forwarding Pipeline

The Tomahawk uses a four-core architecture. The 32 front-panel ports are divided among the four cores, with each core handling a subset of ports. Every packet entering any port passes through a three-stage forwarding pipeline:

1. **Ingress parsing and tunnel termination** — the packet is parsed, and any encapsulation (VXLAN, NVGRE, MPLS) is identified and terminated if needed.
2. **L2/L3 lookup** — the forwarding table is consulted for MAC learning, IP routing, or ECMP resolution.
3. **Egress processing** — the packet is queued, scheduled, and any required encapsulation or modification is applied before transmission.

Forwarding latency is approximately **500 ns** in standard L2/L3 mode. When configured for pure L2 switching with simplified processing, latency drops to approximately **300 ns**.

The pipeline reaches wire-rate (3.2 Tbps) for packet sizes of 250 bytes and above. Below that size, per-packet processing overhead reduces effective throughput.

### Forwarding Tables

The Tomahawk uses a **Unified Forwarding Table (UFT)** with 128K total entries. The entries are stored in shared memory banks that can be partitioned across different lookup types depending on the deployment profile:

| Profile  | Description                                                                                |
| -------- | ------------------------------------------------------------------------------------------ |
| Default  | 128K entries shared dynamically across L2 (MAC), L3 (LPM), and host (ARP/neighbor) lookups |
| Filter   | 8K L2 + 16K L3 LPM + 8K host + 64K ACL (fixed partitioning for ACL-heavy deployments)      |

This flexibility allows the same hardware to be tuned for L2-heavy environments (large MAC tables), L3-heavy environments (large routing tables), or security-heavy environments (large ACL sets).

### Packet Buffer

The BCM56960 provides **16 MB** of on-chip packet buffer, divided into four 4 MB pools (one per core). This buffer absorbs traffic bursts when output ports are temporarily congested. Each port is allocated buffer space from its core's pool, and the allocation can be tuned through memory management profiles in the NOS.

For context, 16 MB is modest by today's standards (newer 25.6T/51.2T ASICs use 64–256 MB), but it is sufficient for most data center ToR workloads where latency-sensitive traffic (such as RoCEv2) relies on PFC and ECN to prevent sustained queue buildup rather than deep buffering.

**Incast caveat:** Under many-to-one (incast) traffic patterns — common in storage clusters and distributed training — multiple senders simultaneously target a single 100G port. The 4 MB per-core buffer can exhaust in microseconds under such conditions. For RoCEv2 workloads on Tomahawk 1, lossless Ethernet tuning is not optional: PFC thresholds and ECN marking (DCQCN) must be precisely configured in SONiC. Without this, the shallow buffers will silently drop RDMA packets, causing go-back-N retransmissions that collapse effective throughput.

### Queuing

The ASIC provides **10 queues per port** for data traffic. These queues support strict priority scheduling, weighted round-robin, and WRED (Weighted Random Early Detection). Additionally, there are **48 CPU-bound queues** (between the ASIC and the management CPU) reserved for control-plane traffic such as LLDP, BGP, ARP, and LACP.

The 10-queue-per-port design is important for quality-of-service (QoS). In RoCEv2/RDMA deployments, dedicated queues are assigned to lossless traffic classes using Priority Flow Control (PFC), while best-effort traffic is placed in separate lossy queues.

### Thermal and Power

Broadcom does not publicly publish exact TDP figures for merchant silicon outside of NDA documentation. However, hardware engineering references and data center system analyses place the BCM56960 TDP at approximately **150–180 W**.

This heat is highly concentrated in two areas of the die: the central packet-processing pipelines (where all forwarding decisions execute at line rate) and the perimeter SerDes lanes (128 lanes, each running at 25 Gbps NRZ). The combination of concentrated heat flux and a large BGA package is why the chip requires the massive grooved metallic heatsink visible in teardown photographs — without sustained forced airflow from the fan tray, junction temperature would exceed safe limits within seconds.

### Supported Features

| Category              | Capabilities                                                        |
| --------------------- | ------------------------------------------------------------------- |
| **L2**                | MAC learning, VLANs, STP/RSTP, LAG/MLAG, LLDP                       |
| **L3**                | IPv4/IPv6 routing, ECMP, VRF, BGP, OSPF (in NOS)                    |
| **Overlay**           | VXLAN, NVGRE, MPLS (tunnel termination and encapsulation)           |
| **RDMA**              | RoCE v1, RoCEv2, PFC, ECN/DCQCN                                     |
| **Telemetry**         | BroadView (microburst detection, buffer monitoring, flow tracking)  |
| **SDN**               | OpenFlow 1.3+                                                       |
| **ACL**               | Ingress and egress ACLs, carved from UFT or dedicated TCAM          |

## ASIC-to-Port Signal Path

This section traces the physical path that serialized electrical signals take from the ASIC die to the front-panel QSFP28 cage, building on the ASIC architecture described above. For background on differential signaling, SerDes operation, and signal integrity concepts referenced here, see [Digital Signal Fundamentals](https://github.com/ManiAm/net-lab-switch-serdes/blob/master/docs/03_signal_basics.md) and [Link Equalization and Training](https://github.com/ManiAm/net-lab-switch-serdes/blob/master/docs/04_signal_training.md).

### Step 1: SerDes Output (Inside the ASIC)

After the forwarding pipeline selects an egress port, the packet data is serialized by the corresponding SerDes block into a high-speed electrical signal. Per the IEEE 802.3by standard that governs 25G Ethernet, each lane uses **differential signaling** — two complementary voltage waveforms (TX+ and TX−) that together represent one serial bitstream.

For a 100G QSFP28 port, four lanes drive four TX differential pairs simultaneously (4 × 25G = 100G). In the receive direction, four RX differential pairs carry data from the transceiver back to the ASIC.

### Step 2: BGA Package

The BCM56960 uses a **Ball Grid Array (BGA)** package (confirmed by the part number: BCM56960B1KFS**BG**, where "BG" denotes Ball Grid). The serialized differential signals exit the ASIC die, pass through the package substrate, and connect to the PCB via solder balls on the underside of the chip.

### Step 3: PCB Traces

From the BGA landing pads, the high-speed signals are routed across the upper PCB to the 32 QSFP28 cages on the front edge.

The [ServeTheHome](https://www.servethehome.com/inside-a-celestica-seastone-dx010-32x-100gbe-switch/) teardown makes two relevant observations about this board:

1. **The ASIC sits near the center of the board**, with the QSFP28 cages arrayed along the front edge (visible in the board photos).

2. **The upper PCB is unusually thick** — quote: *"The PCB this switch chip is on is very thick. If you are accustomed to most server or consumer motherboards, this is several times thicker than what you are used to. The reason is simple, it has to take 3.2Tbps of traffic from the switch chip to the QSFP28 connectors on the front of the switch."*

The thickness is needed because routing 128 differential pairs (256 signal traces) at 25 Gb/s requires a multi-layer PCB with controlled impedance, ground reference planes, and crosstalk isolation between adjacent lanes. The exact layer count of the DX010's upper PCB is not publicly documented.

### Step 4: Retimer

A **retimer** is a chip placed mid-path between the ASIC and the front-panel cage. It receives a degraded signal, recovers the clock and data, and retransmits a clean copy. Retimers are used when the PCB trace is long enough that the signal degrades beyond the receiver's ability to sample it reliably.

The ServeTheHome teardown of the upper PCB notes: *"The large heatsink one may first assume is for multiple ICs. Instead, it is simply there to cool the Broadcom Tomahawk chip."* No other active ICs between the ASIC and the QSFP28 cages are identified in the teardown photos or text. This is consistent with the absence of retimers, but the teardown does not explicitly confirm it. There is no public DX010 schematic to verify definitively.

For context: 25G NRZ signals are more tolerant of PCB trace loss than higher-speed PAM4 signals, and the distances inside a 1U chassis are short. Both factors reduce the need for retimers in this design.

### Step 5: QSFP28 Cage

At the front edge of the upper PCB, the traces terminate at 32 **QSFP28 cage connectors** — the metal receptacles visible on the front panel. Per the QSFP28 MSA specification, each cage provides a standardized electrical and mechanical interface: when a transceiver module is inserted, its edge connector mates with contacts inside the cage, connecting the four TX and four RX differential pairs from the PCB to the module's host-side interface.

### Step 6: Transceiver Module

Once the electrical signal reaches the module inside the cage, signal handling passes to the transceiver's internal circuitry:

- **Optical transceiver (e.g., 100G-SR4, 100G-LR4):** The module converts the electrical signal to optical and drives it into the fiber.
- **DAC cable (Direct Attach Copper):** No conversion occurs. The electrical signal passes through the module's passive copper twinax conductors to the remote end.
- **AOC cable (Active Optical Cable):** The module contains optics permanently attached to the cable, converting electrical to optical at each end.

For details on transceiver types and their operation, see [The Pluggable Transceiver Model](https://github.com/ManiAm/net-lab-transceiver/blob/master/docs/01_README_module.md).

### Signal Path Summary

```
                   DX010 Signal Path (TX direction)

  ┌──────────────────────────────────────────────────────┐
  │  Tomahawk ASIC (BCM56960)                            │
  │  ┌──────────────┐                                    │
  │  │  SerDes      │  25G NRZ per lane                  │
  │  │  (128 lanes) │  4 lanes per 100G port             │
  │  └──────┬───────┘                                    │
  └─────────┼────────────────────────────────────────────┘
            │  BGA solder balls
  ══════════╪══════════════════════════════════════════════
  │         │         Upper PCB (Data Plane)              │
  │         │                                             │
  │    High-speed differential traces                     │
  │    (multi-layer PCB, exact layer count unknown)       │
  │         │                                             │
  │         │    No retimer ICs visible in teardown       │
  │         │                                             │
  │         ▼                                             │
  │  ┌──────────────┐                                     │
  │  │  QSFP28 Cage │  Per QSFP28 MSA specification       │
  │  └──────┬───────┘                                     │
  ══════════╪══════════════════════════════════════════════
            │
            ▼
  ┌──────────────────┐
  │ Transceiver      │  Optical module, DAC, or AOC
  │ Module           │
  └──────┬───────────┘
         │
         ▼
    Fiber or Copper to remote device
```

## Management CPU: Intel Atom C2000 (Rangeley)

The management CPU is an Intel Atom C2000-series processor (codename Rangeley). This is a low-power x86 processor that runs the network operating system. It does not participate in packet forwarding — all data-plane switching is handled by the Tomahawk ASIC at wire speed. The CPU's role is exclusively control-plane:

- Running the NOS (SONiC, ONL, etc.)
- Executing routing protocols (BGP, OSPF) and computing forwarding tables
- Programming the ASIC's forwarding tables via Broadcom's SAI (Switch Abstraction Interface) or SDK
- Handling management traffic (SSH, SNMP, REST API)
- Communicating with transceivers over I2C (reading DOM data, controlling TX disable)
- Monitoring temperature sensors, fan speeds, and PSU status

<img src="../pics/Celestica-Seastone-DX010-Atom-C2000.jpg" alt="Intel Atom C2000 under heatsink on control board" width="500">

### AVR54 Bug (Intel Atom C2000 Defect)

Early steppings of the Intel Atom C2000 (different from the fixed C0 stepping shipped from mid-2017 onward) contain a silicon defect known as AVR54. This bug causes the clock signal output from the LPC (Low Pin Count) bus to gradually degrade over time. Eventually the degradation reaches a point where the processor can no longer boot.

The failure is sudden and permanent: the switch works normally until one day it fails to power on after a reboot or power cycle. There is no warning and no software workaround.

To check whether a DX010 has the fixed silicon:

```
setpci -s 00:00.0 8.w
```

If the result is `0003`, the unit has the C0 stepping (bug fixed). Any other value indicates the affected stepping.


## Platform Management: CPLDs, No BMC

The DX010 does not have a Baseboard Management Controller (BMC). All platform management — fan speed control, thermal monitoring, PSU status, LED state — is handled by CPLDs on the management board, accessed over I2C from the main CPU running the NOS.

This means there is no independent out-of-band management processor. If the NOS crashes or the CPU hangs, no separate controller can monitor thermals or initiate a safe shutdown. The CPLDs continue driving the fans at their last commanded speed, but there is no intelligent failsafe beyond that.

The successor platform, the Seastone2 DX030, adds an optional BMC with IPMI 2.0, Serial over LAN, NC-SI shared management port, and remote firmware upgrade — a fully independent management plane that operates regardless of NOS state.


## Memory

From the factory, the DX010 management board is typically shipped with **one** DDR3 SO-DIMM installed and **one empty slot**. The populated module is usually a **4 GB, DDR3-1600, ECC, unbuffered** SO-DIMM (204-pin, 1.35 V, single rank). The board supports **single-bit ECC**; the CPU and BIOS expect **ECC SO-DIMM** modules, not standard laptop (non-ECC) memory.

| Attribute          | Typical factory value |
| ------------------ | --------------------- |
| Installed capacity | **4 GB** (one module) |
| Empty slots        | **1** (second SO-DIMM socket unpopulated) |
| Module type        | **ECC, unbuffered SO-DIMM** (72-bit / ×72 organization) |
| Speed              | **DDR3-1600** (PC3-12800 / PC3L-12800E) |
| Form factor        | **204-pin SO-DIMM** |
| Voltage            | **1.35 V** (DDR3L; dual 1.35 V / 1.5 V modules are acceptable) |

Under SONiC, `free -h` on a stock unit usually reports about **3.8 GiB** total RAM. That is expected: some memory is reserved by firmware and the kernel, and the full container stack (`syncd`, `swss`, `database`, routing daemons, platform monitoring, and optional lab tools) consumes most of what remains. With only **4 GB** installed, reported utilization often sits **near 100%** even when the switch is not forwarding heavy traffic. That behavior is normal for this platform; it is not necessarily a memory leak, but it does leave little headroom for upgrades, debugging, or extra services running on-box.

**8 GB** is the practical target for a lab or production SONiC deployment on this switch. Sixteen gigabytes is supported by the board in principle but is rarely necessary for control-plane workloads on the Atom management CPU.

### Why Upgrade

SONiC's process and container footprint is large relative to the stock **4 GB**:

- **ASIC sync** (`syncd` and related SAI/SDK components) is the largest consumer.
- **Switch orchestration** (`swss`, `orchagent`, Redis `database`, BGP, LLDP, SNMP, `pmon`, etc.) adds steady baseline usage.
- **Optional tooling** (remote editors, extra monitoring, or debug agents) can push a 4 GB system into swap pressure or OOM risk.

Upgrading RAM improves stability during image upgrades, config reloads, and parallel container restarts, and it avoids operating with effectively no free memory on a stock 4 GB unit.

### Physical Location

The SO-DIMM sockets are on the **lower control-plane PCB** (management board), in the same area as the **mSATA SSD** and the **Intel Atom** heatsink—not on the upper Tomahawk switching board.

<img src="../pics/Celestica-Seastone-DX010-RAM-and-mSATA.jpg" alt="DDR3 SO-DIMM slots and mSATA SSD on the DX010 control board" width="500">

To access the memory:

1. **Power off** the switch and **disconnect AC** from both power supplies (or remove both PSUs from the chassis).
2. Remove the **top cover** (the DX010 uses many screws along the sides; set them aside in order if possible).
3. Locate the **lower PCB**. The two **SO-DIMM slots** sit near the **mSATA** connector; one slot is usually populated, the other empty.
4. Install or replace modules with the slot **latches fully open**, align the notch, press firmly until **both side clips snap closed**.

Only SO-DIMM modules belong in these sockets. The Tomahawk board has no user-serviceable system RAM.

**Do not install** non-ECC laptop SODIMMs. They are the wrong organization (64-bit) for a board that expects ECC (72-bit) SO-DIMMs and may fail to POST or behave unpredictably. Example OEM-style 4 GB modules seen in the field include Netlist **NLQ517235107C-D12T** and Hynix **HMT451A7BFR8A-PB**. Equivalent retail families include Kingston **KVR16LSE11/4** and Supermicro **MEM-DR340L-HL02-ES16** (Hynix-based).

### Verification After Upgrade

After installing memory and booting SONiC:

```bash
free -h
sudo decode-dimms
```



## Power Supplies

The DX010 uses two hot-swappable 800W Delta DPS-800AB-16 A power supply units. The two PSUs provide 1+1 redundancy: either PSU can power the entire switch alone if the other fails or is removed for service.

<img src="../pics/Celestica-Seastone-DX010-800W-Delta-PSU.jpg" alt="Delta 800W hot-swappable PSU" width="400">

The 800W rating per PSU is the maximum capacity, not the typical draw. Under normal operation with DAC cables or low-power optics, the switch consumes approximately **150–200W** total. The high PSU rating exists to support worst-case scenarios: all 32 ports populated with high-power long-reach optical transceivers (such as LR4 or ER4 modules), which can each draw 3–5W.

## Power Consumption

Celestica does not publish official power draw figures for the DX010. However, system-level consumption can be estimated from the known power characteristics of each subsystem.

### Power Contributors

The total power draw of the switch is the sum of five subsystems:

| Subsystem              | Description                                         | Typical Power    |
| ---------------------- | --------------------------------------------------- | ---------------- |
| Switching ASIC         | Broadcom BCM56960 (Tomahawk I), 28 nm, 3.2 Tbps     | 150–180 W (TDP)  |
| Transceivers           | QSFP28 modules (per port, depends on optic type)    | 3.5–5.0 W each   |
| Management CPU         | Intel Atom C2000 (Rangeley), dual-core              | 10–20 W          |
| Cooling                | 5x high-speed fan modules                           | 15–30 W          |
| Miscellaneous          | PCB voltage regulators, PHYs, SSD, RAM              | 5–15 W           |

The switching ASIC is the dominant consumer. Its power draw scales with the number of active SerDes lanes, traffic volume, and table utilization. At idle the chip still maintains clocks, PLLs, and SerDes bias, drawing roughly 100–120 W. Under sustained line-rate traffic across all 32 ports, it approaches the full 150–180 W TDP envelope.

Transceiver power depends on the optic type inserted. Common QSFP28 modules:

| Optic Type   | Reach     | Power per Module |
| ------------ | --------- | ---------------- |
| SR4          | 100 m     | 3.5 W            |
| CWDM4        | 2 km      | 3.5–4.5 W        |
| LR4          | 10 km     | 4.0–5.0 W        |
| DAC cable    | ≤ 5 m     | < 0.5 W          |

A fully populated switch with 32 LR4 optics adds ~150 W from transceivers alone; a lab setup with a few DAC cables adds almost nothing.

### Estimated System Power by Scenario

| Scenario                                   | Estimated Wall Power |
| ------------------------------------------ | -------------------- |
| Idle (no transceivers, no traffic)         | 150–170 W            |
| Light lab use (4–8 DAC ports, low traffic) | 160–190 W            |
| Typical DC (16 ports, SR4, moderate load)  | 250–300 W            |
| Full load (32x LR4, line-rate traffic)     | 370–420 W            |

These are AC wall-draw estimates that include PSU conversion losses (~10–15 % at partial load for an 80 PLUS Platinum-class supply like the Delta DPS-800AB).

### Implications for Home Lab Use

- A single 800 W PSU is more than sufficient for any realistic workload; the second PSU provides redundancy, not additional capacity.
- At idle the switch draws roughly what a mid-range desktop PC does (~150 W). Expect a monthly electricity cost of approximately $15–20 at US residential rates (assuming ~$0.15/kWh, 24/7 operation).
- Fan noise and power both increase under thermal load. In a quiet home environment with few or no optics, replacing the high-speed Nidec fans with quieter aftermarket models is a common modification (at the cost of reduced thermal headroom).

## Software Ecosystem

The DX010 is an **open networking** switch. It ships with ONIE, which is a boot loader environment that allows operators to install any compatible NOS. The most common choices are:

| NOS   | Description                                                                   |
| ----- | ----------------------------------------------------------------------------- |
| SONiC | Open-source NOS originally developed by Microsoft for Azure.                  |
| ONL   | Open Network Linux — a minimal Linux distribution for bare-metal switches.    |

SONiC communicates with the Tomahawk ASIC through the **SAI (Switch Abstraction Interface)**, which provides a vendor-neutral API for programming forwarding tables, ACLs, QoS policies, and reading counters. Broadcom provides the SAI implementation for the BCM56960 as part of their SDK (OpenNSA / SDKLT). This software model means the DX010 has no vendor-locked CLI. All configuration is done through SONiC's config DB, CLI (`show`, `config`), or REST/gNMI interfaces.
