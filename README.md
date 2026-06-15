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

