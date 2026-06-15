// =============================================================================
// tb/tests/neural_edge_tests.sv — UVM Test Classes
//
// A UVM "test" is the top of the UVM hierarchy. It:
//   1. Creates the environment
//   2. Configures it (which sequences to run, how many iterations, etc.)
//   3. Starts the sequences via the sequencer
//   4. Waits for completion
//
// Each test class = one test scenario.
// You run a specific test by passing +UVM_TESTNAME=<test_name> to the simulator.
//
// We have 5 tests here, in order of complexity:
//   1. mac_sanity_test       — basic read/write/compute
//   2. mac_dot_product_test  — full dot product with known vectors
//   3. uart_bringup_test     — UART register config (like post-silicon UART test)
//   4. gpio_test             — GPIO direction and data
//   5. rand_stress_test      — 1000 random transactions, full coverage closure
// =============================================================================

`include "uvm_macros.svh"
import uvm_pkg::*;
import neural_edge_pkg::*;

// =============================================================================
// BASE TEST — all other tests extend this
// Handles environment creation and common config
// =============================================================================
class neural_edge_base_test extends uvm_test;
    `uvm_component_utils(neural_edge_base_test)

    neural_edge_env env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = neural_edge_env::type_id::create("env", this);
    endfunction

    // Helper: run a sequence on the agent's sequencer
    task run_sequence(uvm_sequence #(axi4_transaction) seq);
        seq.start(env.agent.sequencer);
    endtask

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        // UVM automatically collects pass/fail from all components
        // and reports a final summary here
    endfunction
endclass

// =============================================================================
// TEST 1: MAC Sanity Test
// The very first test you run on any new design.
// Write known values, compute, check the result.
// In post-silicon bring-up: this is "does the MAC compute at all?"
// =============================================================================
class mac_sanity_test extends neural_edge_base_test;
    `uvm_component_utils(mac_sanity_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        mac_single_op_seq seq;
        phase.raise_objection(this);  // tell UVM: don't end sim yet

        `uvm_info("TEST", "=== MAC Sanity Test START ===", UVM_NONE)

        // Test 1a: 3 * 4 = 12, accumulate from 0
        seq = mac_single_op_seq::type_id::create("seq");
        seq.operand_a = 32'd3;
        seq.operand_b = 32'd4;
        run_sequence(seq);
        // Scoreboard checks result == 12

        // Test 1b: then 5 * 6 = 30, accumulate → 42
        seq = mac_single_op_seq::type_id::create("seq");
        seq.operand_a = 32'd5;
        seq.operand_b = 32'd6;
        run_sequence(seq);
        // Scoreboard checks result == 42

        // Test 1c: clear accumulator, restart
        begin
            axi4_transaction clr_txn = axi4_transaction::type_id::create("clr");
            uvm_sequence #(axi4_transaction) clr_seq;
            // Direct write to ACC_CLEAR
            base_sequence bs = base_sequence::type_id::create("bs");
            bs.start(env.agent.sequencer);
        end

        `uvm_info("TEST", "=== MAC Sanity Test DONE ===", UVM_NONE)
        phase.drop_objection(this);  // tell UVM: simulation can end
    endtask
endclass

// =============================================================================
// TEST 2: MAC Dot Product Test
// Runs a full vector dot product and checks the final accumulated result.
// Models a neural network layer forward pass.
// =============================================================================
class mac_dot_product_test extends neural_edge_base_test;
    `uvm_component_utils(mac_dot_product_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        mac_dot_product_seq seq;
        phase.raise_objection(this);

        `uvm_info("TEST", "=== MAC Dot Product Test START ===", UVM_NONE)

        // Test vector: [1,2,3,4] · [5,6,7,8] = 5+12+21+32 = 70
        seq = mac_dot_product_seq::type_id::create("seq");
        seq.vec_a      = '{1, 2, 3, 4};
        seq.vec_b      = '{5, 6, 7, 8};
        seq.n_elements = 4;
        run_sequence(seq);

        // Second dot product: [10,20,30] · [3,2,1] = 30+40+30 = 100
        seq = mac_dot_product_seq::type_id::create("seq2");
        seq.vec_a      = '{10, 20, 30};
        seq.vec_b      = '{3, 2, 1};
        seq.n_elements = 3;
        run_sequence(seq);

        `uvm_info("TEST", "=== MAC Dot Product Test DONE ===", UVM_NONE)
        phase.drop_objection(this);
    endtask
endclass

// =============================================================================
// TEST 3: UART Bring-up Test
// Configures UART baud rate, verifies readback, checks TX busy behavior.
// This directly mirrors post-silicon UART bring-up: "is the serial port alive?"
// =============================================================================
class uart_bringup_test extends neural_edge_base_test;
    `uvm_component_utils(uart_bringup_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        uart_tx_seq seq;
        phase.raise_objection(this);

        `uvm_info("TEST", "=== UART Bring-up Test START ===", UVM_NONE)

        seq = uart_tx_seq::type_id::create("seq");
        seq.baud_div  = 16'd433;    // 115200 baud at 50MHz
        seq.tx_byte   = 8'h55;      // 0x55 = 01010101 — alternating bits, good for scope
        run_sequence(seq);

        // Send 'A' (0x41) — classic first character in UART bring-up
        seq = uart_tx_seq::type_id::create("seq2");
        seq.baud_div  = 16'd433;
        seq.tx_byte   = 8'h41;
        run_sequence(seq);

        `uvm_info("TEST", "=== UART Bring-up Test DONE ===", UVM_NONE)
        phase.drop_objection(this);
    endtask
endclass

// =============================================================================
// TEST 4: GPIO Test
// Programs GPIO direction, drives output, reads back input.
// GPIO is often the first peripheral tested at bring-up (toggle a LED).
// =============================================================================
class gpio_test extends neural_edge_base_test;
    `uvm_component_utils(gpio_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        base_sequence seq;
        logic [31:0] rdata;
        phase.raise_objection(this);

        `uvm_info("TEST", "=== GPIO Test START ===", UVM_NONE)

        seq = base_sequence::type_id::create("seq");
        seq.start(env.agent.sequencer);

        fork
            begin
                // Set all GPIO as outputs (DIR = 0xFF)
                seq.axi_write(32'h0000_0204, 32'hFF);
                // Drive all HIGH
                seq.axi_write(32'h0000_0200, 32'hFF);
                // Read back DATA_OUT
                seq.axi_read(32'h0000_0200, rdata);
                `uvm_info("TEST", $sformatf("GPIO DATA_OUT readback = 0x%02X", rdata[7:0]), UVM_NONE)
                // Drive alternating pattern 0xAA
                seq.axi_write(32'h0000_0200, 32'hAA);
                seq.axi_read(32'h0000_0200, rdata);
                `uvm_info("TEST", $sformatf("GPIO pattern 0xAA readback = 0x%02X", rdata[7:0]), UVM_NONE)
            end
        join

        `uvm_info("TEST", "=== GPIO Test DONE ===", UVM_NONE)
        phase.drop_objection(this);
    endtask
endclass

// =============================================================================
// TEST 5: Random Stress Test
// Runs 1000 constrained-random transactions to close functional coverage.
// This is the "regression" test — run it nightly to catch regressions.
// =============================================================================
class rand_stress_test extends neural_edge_base_test;
    `uvm_component_utils(rand_stress_test)

    int unsigned num_transactions = 1000;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        rand_stress_seq seq;
        phase.raise_objection(this);

        `uvm_info("TEST", $sformatf("=== Rand Stress Test START (%0d txns) ===",
                                     num_transactions), UVM_NONE)

        seq = rand_stress_seq::type_id::create("seq");
        seq.num_transactions = num_transactions;
        run_sequence(seq);

        `uvm_info("TEST", "=== Rand Stress Test DONE ===", UVM_NONE)
        phase.drop_objection(this);
    endtask
endclass

// =============================================================================
// TEST 6: Full SoC Boot Test
// Mimics the bare-metal firmware boot sequence via UVM sequences.
// Runs: UART init → GPIO init → MAC dot products → checks all results.
// This is "emulation bring-up" — the UVM env plays the role of the CPU.
// =============================================================================
class soc_boot_test extends neural_edge_base_test;
    `uvm_component_utils(soc_boot_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        boot_sequence seq;
        phase.raise_objection(this);

        `uvm_info("TEST", "=== SoC Boot Test START ===", UVM_NONE)
        `uvm_info("TEST", "Mimicking bare-metal boot via UVM sequences", UVM_NONE)

        seq = boot_sequence::type_id::create("seq");
        run_sequence(seq);

        `uvm_info("TEST", "=== SoC Boot Test DONE ===", UVM_NONE)
        phase.drop_objection(this);
    endtask
endclass
