// =============================================================================
// uvm/neural_edge_pkg.sv
// UVM Package — collects all UVM classes into one namespace
//
// In UVM, a "package" is like a C++ namespace or Python module.
// Everything in here is compiled once and reused across all tests.
// Order matters: base classes before derived classes.
// =============================================================================

`include "uvm_macros.svh"

package neural_edge_pkg;
    import uvm_pkg::*;

    // ── 1. Transaction (the fundamental data object) ──────────────────────
    `include "axi4_transaction.sv"

    // ── 2. Sequencer (generates sequences of transactions) ────────────────
    // (UVM base uvm_sequencer is used directly — no custom class needed)

    // ── 3. Driver (converts transactions to pin wiggles) ──────────────────
    `include "axi4_driver.sv"

    // ── 4. Monitor (observes pins and creates transactions) ───────────────
    `include "axi4_monitor.sv"

    // ── 5. Scoreboard (checks results) ───────────────────────────────────
    `include "scoreboard.sv"

    // ── 6. Coverage Collector ────────────────────────────────────────────
    `include "coverage_collector.sv"

    // ── 7. Agent (bundles driver + monitor + sequencer) ──────────────────
    `include "axi4_agent.sv"

    // ── 8. Environment (bundles everything) ──────────────────────────────
    `include "neural_edge_env.sv"

    // ── 9. Sequences (what to actually send) ─────────────────────────────
    `include "sequences/base_sequence.sv"
    `include "sequences/mac_single_op_seq.sv"
    `include "sequences/mac_dot_product_seq.sv"
    `include "sequences/uart_tx_seq.sv"
    `include "sequences/boot_sequence.sv"
    `include "sequences/rand_stress_seq.sv"

endpackage
