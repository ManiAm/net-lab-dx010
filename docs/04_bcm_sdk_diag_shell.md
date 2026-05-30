# Broadcom SDK Diagnostic Shell on SONiC

On a SONiC switch with a Broadcom ASIC (Tomahawk, Trident, etc.), the SDK diagnostic shell provides direct read/write access to NPU hardware state — SerDes parameters, port configuration, registers, counters, and memory tables. This document covers the shell's architecture, port naming, the command set, and common debugging workflows.

> **Prerequisites:** This document assumes familiarity with SerDes architecture, equalization (CTLE, DFE, TX FIR), NRZ/PAM4 signaling, eye diagrams, and port breakout. These topics are covered in the [net-lab-switch-serdes](https://github.com/ManiAm/net-lab-switch-serdes) project.

---

## Architecture

### SAI (Switch Abstraction Interface)

[SAI](https://github.com/opencomputeproject/SAI) is an open-source API that provides a vendor-neutral interface to switch ASICs. SONiC programs hardware exclusively through SAI — it never calls the Broadcom SDK directly. The SAI library for Broadcom is a shim that translates SAI API calls into the underlying SDK operations (register writes, table programming, SerDes tuning). The diagnostic shell bypasses SAI and talks to the SDK layer directly, which is why it can expose hardware details that SAI does not surface.

### Client–Server Model

The diagnostic shell uses a client–server model. All components run inside the `syncd` container:

```
┌─────────────────────────────────────────────────────────┐
│  syncd container                                        │
│                                                         │
│  ┌─────────┐      Unix domain socket         ┌────────┐ │
│  │ bcmcmd  │─────(/var/run/sswsyncd/──────>  │dsserve │ │
│  │ bcmsh   │      sswsyncd.socket)           │   │    │ │
│  └─────────┘                                 │   ▼    │ │
│   (clients)                                  │ syncd  │ │
│                                              │   │    │ │
│                                              │   ▼    │ │
│                                              │  SDK   │ │
│                                              └───┼────┘ │
└──────────────────────────────────────────────────┼──────┘
                                                   ▼
                                              Broadcom ASIC
```

`syncd` is the ASIC management daemon. It loads the Broadcom SAI library, which initializes the SDK and programs the hardware. This is the heavy process (~500 MB+ RSS). `dsserve` is a lightweight socket relay that wraps `syncd`. It launches `syncd` as a child process, creates a Unix domain socket at `/var/run/sswsyncd/sswsyncd.socket`, accepts client connections, and bridges them to the SDK's built-in diagnostic shell stdin/stdout. It uses negligible CPU and memory.

This is visible in the process tree inside the container:

```
root@sonic:/# ps aux
USER   PID %CPU %MEM    VSZ    RSS TTY  STAT  TIME COMMAND
root     1  0.0  0.4  29888  17132 pts/0 Ss+  0:07 /usr/bin/python3 /usr/local/bin/supervisord
root    19  0.0  0.0  87704    168 pts/0 Sl   0:00 /usr/bin/dsserve /usr/bin/syncd --diag -u -s ...
root    33 16.0 13.5 2809092 540700 pts/0 Sl  43:18 /usr/bin/syncd --diag -u -s -B null -p /etc/sai.d/s...
```

`supervisord` (PID 1) is the container's init process. `dsserve` (PID 19) is the parent of `syncd` (PID 33) — the `syncd` command line appears as `dsserve`'s argument because `dsserve` exec'd it as a child.

The `bcm` prefix in both utilities stands for "Broadcom Command Monitor". `bcmcmd` is a compiled client that connects to the socket, sends a single command, prints the response, and exits — designed for scripting and one-shot queries. `bcmsh` is a bash wrapper around `socat` that opens an interactive `readline` session over the same socket, giving a persistent `drivshell>` prompt for exploratory debugging.

> Only one client can connect at a time. If `bcmsh` holds the socket, a concurrent `bcmcmd` call blocks until the interactive session ends.

The full command path: **client → Unix socket → dsserve → syncd → SDK → ASIC registers/memory**. Although `syncd` hosts both SAI and the SDK in the same process, diagnostic shell commands are handled by the SDK's built-in command interpreter (`sh_process_command`) and never pass through SAI. Normal SONiC operations (orchagent programming the ASIC) go through SAI, but the diagnostic shell bypasses it entirely.





## Port Naming and SONiC Mapping

The SDK names ports by speed-class prefix and index. SONiC uses `EthernetN`. Understanding the mapping is necessary before interpreting any command output.

### SDK Port Prefixes

| Prefix | Speed Class    | Typical Lane Count |
| ------ | -------------- | ------------------ |
| `ce`   | 100G (Century) | 4 lanes (4×25G NRZ) or 2 lanes (2×50G PAM4) |
| `xe`   | 10G or 25G     | 1 lane |
| `ge`   | 1G             | 1 lane |

Each port also has an internal physical port number shown in parentheses in command output, e.g., `ce4(34)`.

### Mapping to SONiC Interfaces

On a typical 32×100G Tomahawk 1 platform, `ce0` through `ce31` map to `Ethernet0` through `Ethernet124` with a stride of 4 (each 100G port consumes 4 logical lane indices in SONiC).

```bash
# From the host (outside syncd) — show current interface mapping
show interface status

# Or inspect the platform file directly
cat /usr/share/sonic/device/<platform>/<hwsku>/port_config.ini
```

### Breakout Configuration

A 100G port can be broken out into smaller ports — for example, 4×25G or 2×50G — by splitting the underlying SerDes lanes into independent logical ports. Under breakout, the `ce` port disappears and individual `xe` ports appear instead. The breakout mode is configured through SONiC (`config interface breakout ...`) and reflected in `platform.json` or `port_config.ini`.


## Accessing the Shell

```bash
# Enter the syncd container from the host
docker exec -it syncd bash
```

| Utility  | Mode                           | Best For |
| -------- | ------------------------------ | -------- |
| `bcmcmd` | Non-interactive (one-shot)      | Scripting, collecting a single data point |
| `bcmsh`  | Interactive (persistent prompt) | Exploratory debugging, running multiple commands |

```bash
# Non-interactive
bcmcmd "ps"
bcmcmd "phy diag ce4 dsc"

# Interactive
bcmsh
drivshell> ps
drivshell> phy diag ce4 dsc
drivshell> # Ctrl+C to exit
```

Available commands vary by SDK version and build flags. Use `help` to list all commands recognized by the running shell, and `help <command>` for usage details on a specific command:

```bash
bcmcmd "help"
bcmcmd "help phy"
```

---

## Command Reference

### Version — `version`

Prints the SDK version, build date, and platform information. Include this in any bug report or comparison between switches.

```
root@sonic:/# bcmcmd "version"
Broadcom Command Monitor: Copyright (c) 1998-2025 Broadcom
Release: sdk-6.5.30-SP4 built 20250422 (Tue Apr 22 03:55:07 2025)
From root@0db4417a01c3:/__w/1/s/output/x86-xgsall-deb/xgs-sdk-src/hsdk-all-6.5.30
Platform: X86
OS: Unix (Posix)
```

### Port Status — `ps`

Displays all physical ports with link state, speed, lane count, interface type, and STP state.

```
drivshell> ps
       ce0( 68)  down   4  100G  FD   SW  No   Forward          None    F    KR4  9122    No
       ce4( 34)  up     4  100G  FD   SW  No   Forward          None    F    KR4  9122    No
       xe0( 69)  !ena   1   25G  FD None  No   Disable  TX RX   None   FA  XGMII  9412    No
```

| Column | Meaning |
| ------ | ------- |
| Port name `(N)` | SDK prefix + index, with internal physical port number in parentheses |
| `up` / `down` / `!ena` | `up` = enabled and link is active; `down` = enabled but no link; `!ena` = administratively disabled |
| `Lns` | Number of SerDes lanes bonded into this port |
| Speed / Duplex | Configured line rate and duplex mode (`FD` = full duplex) |
| Link scan | `SW` = software link polling; `HW` = hardware interrupt-driven link detection |
| Interface | Electrical/encoding interface type (`KR4`, `CR4`, `XGMII`, etc.) |

### PHY Information — `phy info` / `phy <port>`

```bash
# Show PHY/SerDes driver summary for all ports
bcmcmd "phy info"

# Show detailed PHY control properties for a specific port
bcmcmd "phy ce4"
```

`phy info` lists the phymod driver bound to each port. `phy <port>` shows per-port PHY control variables (autoneg, FEC mode, medium type, preemphasis, etc.).

### SerDes Diagnostics — `phy diag <port> dsc`

Displays the live SerDes state for every lane in a port: CDR lock, equalization settings, TX FIR taps, and eye margins.

```
drivshell> phy diag ce4 dsc
 tscf_phy_pmd_info_dump:516 type = 16384 laneMask = 0xF
SerDes type = falcon_tsc
CORE  VCO_RATE   COM_CLK   UCODE_VER  LIVE_TEMP  PLL_LOCK
 00   25.750GHz  156.25MHz  D10B_23     61C         1*

LN  SD LCK  PF(M,L)  VGA  DFE(1,2,3,4,5,6)       TXEQ(n1,m,p1,2,3)  EYE(L,R,U,D)
 0  1*  1*   0,0      12   22,-6, 2, 4, 2,-1      00,100,12, 0, 0     343,328,155,158
 1  1*  1*   0,1      13   23,-8, 3, 4,-2, 2      00,100,12, 0, 0     296,328,155,155
```

**Core-level fields:**

| Field | Meaning |
| ----- | ------- |
| `VCO_RATE` | Voltage-Controlled Oscillator frequency — the SerDes baud clock. 25.750 GHz corresponds to 25G NRZ. |
| `COM_CLK` | Reference clock input frequency (typically 156.25 MHz for 25G Ethernet). |
| `UCODE_VER` | SerDes microcode firmware version. |
| `LIVE_TEMP` | Die temperature in degrees Celsius at the SerDes core. |
| `PLL_LOCK` | Phase-Locked Loop lock status (`1` = locked, `0` = unlocked — unlocked means the VCO is not frequency-locked and the core cannot operate). |

**Per-lane fields:**

| Field | Meaning |
| ----- | ------- |
| `SD` | Signal Detect. `1` = electrical/optical energy is present on this lane. `0` = no signal (cable unplugged or far-end TX off). |
| `LCK` | CDR Lock. `1` = clock and data recovery circuit is locked and the receiver is sampling data correctly. `0` = CDR has not acquired lock (could be due to no signal, wrong speed, or severe signal degradation). |
| `PF(M,L)` | CTLE peaking filter settings. `M` = main peaking, `L` = low-frequency boost. Higher values apply more high-frequency gain to compensate for lossy channels. |
| `VGA` | Variable Gain Amplifier setting. The analog gain applied after the CTLE; auto-adapted by the SerDes firmware. |
| `DFE(1..6)` | DFE tap coefficients. Tap 1 is dominant; taps 2–6 handle longer-tail ISI. Larger absolute values indicate the channel introduces more inter-symbol interference that the DFE is correcting. |
| `TXEQ(n1,m,p1,2,3)` | TX FIR filter taps: `n1` = pre-cursor, `m` = main cursor, `p1/p2/p3` = post-cursor 1/2/3. These are the far-end transmitter's settings as reported to the local receiver via link training or static configuration. |
| `EYE(L,R,U,D)` | Eye margin — `L`/`R` in mUI (horizontal), `U`/`D` in mV (vertical). One mUI (milli Unit Interval) = 1/1000 of a symbol period. See the Signal Quality Assessment section below for healthy thresholds. |

**Identifying the SerDes core:** Different Broadcom ASICs embed different SerDes PHY IP cores. The output header identifies which core is active, and the core determines the available equalization parameters and signaling modes:

| Output String       | SerDes Core    | Signaling | ASIC Generations |
| ------------------- | -------------- | --------- | ---------------- |
| `falcon_tsc`        | Falcon (TSCF)  | 25G NRZ   | Tomahawk 1, Tomahawk 2, Trident 3 |
| `blackhawk7_v1l8p2` | Blackhawk7 (TSCBH) | 50G PAM4 | Tomahawk 3, Tomahawk 4, Trident 4 |
| `peregrine_...`     | Peregrine      | 100G PAM4 | Tomahawk 5 |

The function name prefix (`tscf_phy_pmd_info_dump` vs `tscbh_phy_pmd_info_dump`) also identifies the active phymod driver.

All `phy diag` subcommands accept two optional targeting parameters:

- `unit=N` — selects which PHY device on the port. `0` is the internal SerDes (directly connected to the MAC), `1` is the first external PHY (if present).
- `if=line|sys` — selects the line-side or system-side interface of a multi-interface PHY (relevant when an external PHY sits between the MAC and the connector).

On the DX010 (no external PHY), these can be omitted — all commands default to the internal SerDes.

### Eye Scan — `phy diag <port> eyescan`

Runs a full 2D eye diagram measurement across all lanes. The output is an ASCII plot of BER contours at various phase and voltage offsets.

```
drivshell> phy diag ce4 eyescan
```

This takes several seconds per lane. A wide-open eye confirms good signal quality; a closed or pinched eye indicates excessive channel loss, crosstalk, or equalization failure.

### Loopback — `phy diag <port> loopback`

Puts the SerDes into loopback mode for isolation testing. In local loopback, TX data is looped back to RX at the local SerDes — traffic never reaches the cable. In remote loopback, data received from the far end is retransmitted back. Comparing error behavior with and without loopback isolates whether the problem is in the local SerDes, the cable/channel, or the far-end device.

```bash
# Enable local (internal) loopback
bcmcmd "phy diag ce4 loopback set mode=local"

# Enable remote loopback
bcmcmd "phy diag ce4 loopback set mode=remote"

# Disable loopback
bcmcmd "phy diag ce4 loopback set mode=none"
```

### PRBS Testing — `phy diag <port> prbs`

PRBS (Pseudo-Random Bit Sequence) generates a known test pattern on the SerDes to measure raw bit error rate independently of normal traffic. Useful for isolating whether errors are in the physical link or in the protocol/forwarding stack.

```bash
# Start PRBS generator and checker on a port (polynomial 31)
bcmcmd "phy diag ce4 prbs set p=3"

# Read PRBS lock status and error count
bcmcmd "phy diag ce4 prbs get"

# Clear PRBS counters
bcmcmd "phy diag ce4 prbs clear"
```

Both ends of the link must be configured with the same PRBS polynomial. `p=0` is PRBS-7, `p=1` is PRBS-15, `p=2` is PRBS-23, `p=3` is PRBS-31.

### PRBS BER Statistics — `phy diag <port> prbsstat`

Periodically collects PRBS error counters and computes BER based on the port configuration. PRBS must already be running on the target ports.

```bash
# Start periodic collection (default interval)
bcmcmd "phy diag ce4 prbsstat start"

# Start with a custom interval (seconds)
bcmcmd "phy diag ce4 prbsstat start i=60"

# Read accumulated error counters
bcmcmd "phy diag ce4 prbsstat counters"

# Read computed BER
bcmcmd "phy diag ce4 prbsstat ber"

# Clear counters
bcmcmd "phy diag ce4 prbsstat clear"

# Stop collection
bcmcmd "phy diag ce4 prbsstat stop"
```

### FEC Statistics — `phy diag <port> fecstat`

Periodically collects FEC counters — corrected and uncorrected codewords, symbol errors, and bit errors — and computes pre-FEC BER and per-lane symbol error rate.

```bash
# Start periodic collection
bcmcmd "phy diag ce4 fecstat start"

# Start with a custom interval (seconds)
bcmcmd "phy diag ce4 fecstat start i=10"

# Read FEC counters
bcmcmd "phy diag ce4 fecstat counters"

# Read computed pre-FEC BER
bcmcmd "phy diag ce4 fecstat ber"

# Clear counters
bcmcmd "phy diag ce4 fecstat clear"

# Stop collection
bcmcmd "phy diag ce4 fecstat stop"
```

### BER Projection — `phy diag <port> berproj`

Projects post-FEC BER based on current link conditions. Runs a statistical measurement to estimate the error floor without waiting for actual uncorrectable errors to occur.

```bash
bcmcmd "phy diag ce4 berproj"

# With custom sample time (milliseconds)
bcmcmd "phy diag ce4 berproj sample_time=80"

# With custom histogram error count threshold
bcmcmd "phy diag ce4 berproj hist_errcnt_threshold=4"
```

### Port Configuration — `port`

```bash
# Show all port properties
bcmcmd "port ce4"

# Enable / disable a port
bcmcmd "port ce4 en=1"
bcmcmd "port ce4 en=0"

# Change speed (port must support the target mode)
bcmcmd "port ce4 sp=40000"
```

### Registers and Memory Tables

```bash
# List registers matching a substring
bcmcmd "listreg port"

# Read a named register
bcmcmd "getreg <REGISTER_NAME>"

# Write a register value
bcmcmd "setreg <REGISTER_NAME> <value>"

# Read-modify-write specific fields of a register
bcmcmd "modreg <REGISTER_NAME> <FIELD>=<value>"

# List the entry format (fields) for a memory table
bcmcmd "listmem <TABLE_NAME>"

# Dump an indexed memory table entry
bcmcmd "dump <TABLE_NAME> <index>"
```

Register and table names are ASIC-specific. Use `listreg` and `listmem` to discover available names. `modreg` is safer than `setreg` when changing individual fields — it preserves all other fields in the register.

### Counters

```bash
# Show MAC/RMON counters for a port
bcmcmd "show counters ce4"

# Clear all counters
bcmcmd "clear counters"
```

Counters include TX/RX frames, bytes, FCS errors, alignment errors, symbol errors, pause frames, and sobject-drop counters.

### Link Scan — `linkscan`

Controls how the SDK detects link-state changes. Software scanning (`sw`) polls PHY status registers periodically. Hardware scanning (`hw`) uses interrupt-driven detection for faster response.

```bash
# Show current link scan configuration
bcmcmd "linkscan"

# Set software scan interval (in microseconds)
bcmcmd "linkscan sw=250000"
```

### Temperature — `temperature`

Reads on-chip thermal sensors. Useful when investigating margin degradation or link instability that correlates with thermal load. On platforms that use a generic board driver (like the DX010), the command returns no sensor data:

```
root@sonic:/# bcmcmd "temperature"
Using generic board type
drivshell>
```

On platforms with a board-specific SDK driver, this command reports per-sensor temperatures from the ASIC die. When it is not available, use the SONiC host command `show platform temperature` instead.

### Cable Diagnostics — `cablediag`

Runs TDR (Time-Domain Reflectometry) cable diagnostics on copper ports. Reports cable length, pair status, and fault location. Only applicable to copper — not relevant for optics or DAC cables.

```bash
bcmcmd "cablediag ce4"
```

---

## Debugging Workflows

### Link-Down Troubleshooting

```bash
bcmcmd "phy diag ce4 dsc"       # 1. Check SD — is signal present on each lane?
                                 #    Check LCK — has CDR locked?
                                 #    If SD=0: cable/transceiver/far-end issue.
                                 #    If SD=1, LCK=0: speed mismatch, severe signal degradation, or FEC mismatch.

bcmcmd "phy diag ce4 eyescan"   # 2. If CDR is locked but link still flaps, inspect the eye.
                                 #    Closed or marginal eye → channel loss or crosstalk problem.

bcmcmd "show counters ce4"      # 3. If link is up but errors are climbing:
                                 #    FCS errors → bit errors on the wire.
                                 #    Alignment errors → lane skew or framing issue.
                                 #    Symbol errors → encoding violations (potential SerDes issue).
```

### Signal Quality Assessment

Read the `EYE(L,R,U,D)` values from `phy diag <port> dsc`:

| Margin | Healthy | Marginal | Critical |
| ------ | ------- | -------- | -------- |
| Horizontal (L or R) | >200 mUI | 150–200 mUI | <150 mUI |
| Vertical (U or D) | >100 mV | 80–100 mV | <80 mV |

Marginal margins may work today but fail under temperature shifts or transceiver aging. Critical margins indicate the link is at risk of uncorrectable errors.

### TX Equalization Tuning

If the far-end receiver reports poor eye margins, adjust the local TX FIR taps:

```bash
# Read current TX FIR taps (look at the TXEQ row in the per-lane output)
bcmcmd "phy diag ce4 dsc"

# Or view the PHY control variables directly
bcmcmd "phy ce4"

# Adjust a TX tap (example: increase post-cursor 1)
bcmcmd "phy ce4 PHY_TX_FIR_POST=0x000C"
```

After changing a tap, re-run `phy diag <port> dsc` on the far-end switch to verify the eye margin improved. TX FIR tuning is iterative — adjust one tap at a time and measure the effect.
