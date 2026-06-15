# Neural Edge SoC — Pre-Silicon Emulation & Validation Environment

> An end-to-end SoC validation project. 
> Covers RTL design, bare-metal firmware bring-up, UVM-based pre-silicon emulation, and functional coverage closure.

---

## What This Is

This project implements the full pre-silicon validation pipeline for a custom **MAC (Multiply-Accumulate) Accelerator SoC** — the same class of hardware that powers on-device neural inference in Amazon Echo devices.

The pipeline covers:

| Layer | What | Files |
|-------|------|-------|
| **RTL Design** | AXI-4 Lite SoC with MAC accelerator, UART, GPIO | `rtl/` |
| **Bare-Metal Firmware** | C boot drivers, MMIO config, self-test (no OS) | `firmware/` |
| **UVM Emulation Env** | Transactors, monitors, scoreboard, coverage | `uvm/`, `tb/` |

This mirrors what an SoC Validation Engineer does daily on an emulation platform (Zebu / HAPs):  
develop the infrastructure → write bare-metal drivers → run test plans → close coverage → hand off to silicon bring-up.

---

## SoC Architecture

```
                    ┌─────────────────────────────────────┐
  UVM Testbench     │         neural_edge_soc.sv          │
  (acts as CPU)     │                                     │
       │            │   AXI-4 Lite Interconnect / MUX     │
       │ AXI-4 Lite │                                     │
       └────────────┤  ┌──────────┐ ┌──────┐ ┌────────┐  │
                    │  │   MAC    │ │ UART │ │  GPIO  │  │
                    │  │  Accel   │ │      │ │        │  │
                    │  └──────────┘ └──────┘ └────────┘  │
                    └─────────────────────────────────────┘
```

### Address Map

| Address Range | Peripheral | Key Registers |
|--------------|-----------|---------------|
| `0x0000_0000–0x3F` | MAC Accelerator | `OPERAND_A`, `OPERAND_B`, `CTRL`, `RESULT`, `STATUS`, `ACC_CLEAR` |
| `0x0000_0100–0x11F` | UART | `TX_DATA`, `STATUS`, `BAUD_DIV`, `RX_DATA` |
| `0x0000_0200–0x20F` | GPIO | `DATA_OUT`, `DIR`, `DATA_IN` |

---

## Repository Structure

```
neural-edge-soc/
├── rtl/
│   ├── mac_accelerator.sv      # MAC engine — AXI-4 Lite slave, FSM, SVA, covergroup
│   ├── uart_peripheral.sv      # UART TX/RX — baud generator, FSM, SVA
│   ├── gpio_peripheral.sv      # GPIO — tristate, 2-FF CDC synchronizer
│   └── neural_edge_soc.sv      # Top-level — address decode, AXI MUX, IRQ aggregation
│
├── firmware/
│   ├── start.S                 # RISC-V boot entry — stack setup, BSS zero, → main()
│   ├── main.c                  # Bare-metal drivers + self-test boot sequence
│   └── link.ld                 # Linker script — ROM/SRAM memory map
│
├── uvm/
│   ├── neural_edge_pkg.sv      # Package — includes all UVM classes in order
│   ├── axi4_transaction.sv     # Sequence item — rand fields + constraints
│   ├── axi4_driver.sv          # Drives AXI signals from transactions
│   ├── axi4_monitor.sv         # Observes bus, broadcasts via analysis port
│   ├── scoreboard.sv           # Reference model + correctness checking
│   ├── coverage_collector.sv   # 5 covergroups — closes functional coverage
│   ├── axi4_agent.sv           # Bundles driver + monitor + sequencer
│   ├── neural_edge_env.sv      # Top-level env — wires agent → scoreboard → coverage
│   └── sequences/
│       ├── base_sequence.sv         # axi_write(), axi_read(), poll_until_set()
│       ├── mac_single_op_seq.sv     # One MAC compute: write A, B, CTRL; poll; read RESULT
│       ├── remaining_sequences.sv   # uart_tx_seq, boot_sequence, rand_stress_seq, mac_dot_product_seq
│
├── tb/
│   ├── neural_edge_if.sv       # Virtual interface — clocking blocks, modports, AXI assertions
│   ├── tb_top.sv               # Testbench top — clock/reset, DUT inst, config_db, run_test()
│   └── tests/
│       └── neural_edge_tests.sv # 6 test classes: sanity → dot product → UART → GPIO → boot → stress
│
├── Makefile                    # make sim / make sim_all / make waves / make fw
└── README.md
```

---

## Quick Start

### Prerequisites

```bash
# Simulation (free)
sudo apt install iverilog gtkwave

# UVM library (open-source port for Icarus)
git clone https://github.com/antmicro/uvm-sv  ~/uvm-1.2
export UVM_HOME=~/uvm-1.2

# Firmware (optional — only if you want to compile the C firmware)
sudo apt install gcc-riscv64-unknown-elf
```

### Run a Test

```bash
# Run the MAC dot product test
make sim TEST=mac_dot_product_test

# Run ALL 6 tests
make sim_all

# Open waveforms
make waves
```

### Available Tests

| Test | What it validates | Scenario |
|------|-----------------|---------|
| `mac_sanity_test` | Basic MAC read/write/compute | Write A=3,B=4 → expect RESULT=12 |
| `mac_dot_product_test` | Accumulated dot product | [1,2,3,4]·[5,6,7,8] = 70 |
| `uart_bringup_test` | UART peripheral config | Baud div write/readback, TX byte |
| `gpio_test` | GPIO direction + data | Set DIR=0xFF, drive 0xAA, readback |
| `soc_boot_test` | Full boot flow via UVM | UVM replays the bare-metal boot sequence |
| `rand_stress_test` | Coverage closure | 1000 constrained-random transactions |

### Compile Firmware

```bash
make fw
# Produces: firmware/firmware.elf, firmware.bin, boot_rom.mem
```

---

## Design Details

### MAC Accelerator State Machine

```
IDLE ──(CTRL=1)──► BUSY ──(next cycle)──► DONE ──(next cycle)──► IDLE
                   (acc += A×B)          (assert IRQ 1 cycle)
```

- Accumulator clears via `ACC_CLEAR` register write
- IRQ is a single-cycle pulse — enforced by SVA assertion
- 3-state FSM implemented in `always_ff` with active-low reset

### AXI-4 Lite Handshake

Transfer occurs when `VALID && READY` are both high on the same `posedge clk`.  
Three interface-level SVA assertions enforce VALID-stability for AW, W, and AR channels.

### CDC Handling (GPIO)

GPIO input pins pass through a **2-FF synchronizer** to prevent metastability — the same technique used in the async FIFO project and validated by Questa CDC.

### Bare-Metal Boot Sequence

```
reset → start.S (stack, BSS) → uart_init(433) → UART banner
     → mac_dot_product × 3 (self-test) → GPIO BOOT_OK → idle loop
```

---

## UVM Environment Architecture

```
neural_edge_env
├── axi4_agent (ACTIVE)
│   ├── uvm_sequencer ◄── sequences start here
│   ├── axi4_driver   ──► drives AXI signals on virtual interface
│   └── axi4_monitor  ──► observes bus, publishes transactions
│        │
│        └── analysis_port (broadcast)
│             ├──► scoreboard       (correctness: got == expected?)
│             └──► coverage_collector (completeness: all bins hit?)
```

### Functional Coverage Model (5 covergroups)

| Covergroup | What it measures |
|-----------|----------------|
| `mac_reg_cg` | Cross of op×address — every register read AND written |
| `data_pattern_cg` | Zero, all-ones, walking-1, mid-range, large values |
| `wstrb_cg` | All byte-enable patterns: full word, byte0, byte3, halves |
| `consecutive_cg` | Back-to-back sequences: WR-WR, WR-RD, RD-WR, RD-RD |
| `response_cg` | Both OKAY and SLVERR responses observed |

---

## Relation to Amazon AZ1 Neural Edge

| Amazon JD Requirement | This Project |
|----------------------|-------------|
| Develop testbenches, transactors, monitors for emulation | `axi4_driver.sv`, `axi4_monitor.sv` |
| Develop baremetal drivers to configure SoC subsystems | `firmware/main.c` — MAC, UART, GPIO drivers |
| Develop/review subsystem testplans | `coverage_collector.sv` — 5 covergroups |
| Implement tests and scenarios on multiple platforms | 6 test classes in `tb/tests/` |
| Debug and resolve issues | SVA assertions in RTL + interface |
| Port emulation testplans to post-silicon | `boot_sequence.sv` — same plan, different platform |
| ARM and RISC-V ISA experience | RV32I firmware in `start.S`, `main.c` |
| SOC fabrics, memory controllers, peripherals | AXI-4 interconnect, UART, GPIO |
| Maximize utilization through automation | `Makefile` — one command runs all tests |

---

## Open Source Contribution

**OpenTitan (Google):** SVA assertions for `uart_tx` verification module — [PR #29750](https://github.com/lowRISC/opentitan/pull/29750)

---

*Built as a demonstration of pre-silicon SoC validation methodology — RTL design through UVM emulation infrastructure.*
