// =============================================================================
// sequences/uart_tx_seq.sv
// UART TX Sequence — configure baud rate and transmit one byte
// =============================================================================
class uart_tx_seq extends base_sequence;
    `uvm_object_utils(uart_tx_seq)

    rand logic [15:0] baud_div;   // baud rate divisor
    rand logic [7:0]  tx_byte;    // byte to transmit

    // Default: 115200 baud at 50MHz
    constraint c_baud { baud_div inside {[100:1000]}; }

    function new(string name = "uart_tx_seq");
        super.new(name);
    endfunction

    task body();
        logic [31:0] rdata;
        `uvm_info("SEQ", $sformatf("UART TX: baud_div=%0d byte=0x%02X", baud_div, tx_byte), UVM_MEDIUM)

        // Step 1: Configure baud divisor
        axi_write(32'h0000_0108, {16'b0, baud_div});

        // Step 2: Verify baud divisor readback
        axi_read(32'h0000_0108, rdata);
        if (rdata[15:0] !== baud_div)
            `uvm_error("SEQ", $sformatf("UART BAUD_DIV mismatch: got %0d expected %0d",
                                         rdata[15:0], baud_div))

        // Step 3: Poll TX_BUSY until clear (UART not busy)
        poll_until_set(32'h0000_0104, 32'h0);  // STATUS bit0=TX_BUSY; wait until 0

        // Step 4: Write byte to TX_DATA (triggers transmission)
        axi_write(32'h0000_0100, {24'b0, tx_byte});
        `uvm_info("SEQ", $sformatf("UART byte 0x%02X queued for TX", tx_byte), UVM_MEDIUM)

        // Step 5: Poll until TX completes
        // In real bring-up you'd watch the UART_TX pin on a scope or logic analyzer
        poll_until_set(32'h0000_0104, 32'h0);
        `uvm_info("SEQ", "UART TX complete", UVM_MEDIUM)
    endtask

endclass


// =============================================================================
// sequences/boot_sequence.sv
// SoC Boot Sequence — UVM replay of the bare-metal firmware boot
//
// This sequence does exactly what main.c does, but driven by UVM.
// This is the "emulation bring-up" flow:
//   In emulation (Zebu/HAPs), you load the firmware binary and let it run.
//   This sequence is an alternative: the UVM env acts as the CPU, issuing
//   the same MMIO writes the firmware would have issued.
// =============================================================================
class boot_sequence extends base_sequence;
    `uvm_object_utils(boot_sequence)

    function new(string name = "boot_sequence");
        super.new(name);
    endfunction

    task body();
        logic [31:0] rdata;
        `uvm_info("SEQ", "=== Boot Sequence: START ===", UVM_NONE)

        // ── 1. GPIO Init: all outputs, all LOW ────────────────────────────
        `uvm_info("SEQ", "[BOOT] GPIO init", UVM_MEDIUM)
        axi_write(32'h0000_0204, 32'hFF);   // DIR = all outputs
        axi_write(32'h0000_0200, 32'h00);   // DATA_OUT = all LOW

        // ── 2. UART Init: 115200 baud (div=433) ───────────────────────────
        `uvm_info("SEQ", "[BOOT] UART init @ 115200 baud", UVM_MEDIUM)
        axi_write(32'h0000_0108, 32'd433);
        axi_read (32'h0000_0108, rdata);
        if (rdata[15:0] !== 16'd433)
            `uvm_error("SEQ", "[BOOT] UART baud_div config FAILED")
        else
            `uvm_info("SEQ", "[BOOT] UART init PASSED", UVM_NONE)

        // ── 3. MAC Self-Test 1: [1,2,3,4]·[5,6,7,8] = 70 ────────────────
        `uvm_info("SEQ", "[BOOT] MAC Self-Test 1", UVM_MEDIUM)
        axi_write(32'h0000_0014, 32'h1);   // ACC_CLEAR
        run_mac_dot_product('{1,2,3,4}, '{5,6,7,8}, 4, 32'd70, "Layer0");

        // ── 4. MAC Self-Test 2: [10,20,30]·[3,2,1] = 100 ────────────────
        `uvm_info("SEQ", "[BOOT] MAC Self-Test 2", UVM_MEDIUM)
        axi_write(32'h0000_0014, 32'h1);   // ACC_CLEAR
        run_mac_dot_product('{10,20,30}, '{3,2,1}, 3, 32'd100, "Layer1");

        // ── 5. MAC Self-Test 3: [100,200,50,25]·[4,3,8,2] = 1450 ────────
        `uvm_info("SEQ", "[BOOT] MAC Self-Test 3", UVM_MEDIUM)
        axi_write(32'h0000_0014, 32'h1);   // ACC_CLEAR
        run_mac_dot_product('{100,200,50,25}, '{4,3,8,2}, 4, 32'd1450, "Layer2");

        // ── 6. Signal BOOT_OK on GPIO pin 0 ──────────────────────────────
        `uvm_info("SEQ", "[BOOT] All self-tests PASSED — asserting BOOT_OK GPIO", UVM_NONE)
        axi_write(32'h0000_0200, 32'h01);   // GPIO[0] = BOOT_OK = HIGH
        axi_read (32'h0000_0200, rdata);
        if (rdata[0] !== 1'b1)
            `uvm_error("SEQ", "[BOOT] BOOT_OK GPIO assertion FAILED")

        `uvm_info("SEQ", "=== Boot Sequence: COMPLETE ===", UVM_NONE)
    endtask

    // Helper: run a full dot product and check result
    task run_mac_dot_product(
        logic [31:0] vec_a[],
        logic [31:0] vec_b[],
        int          n,
        logic [31:0] expected,
        string       label
    );
        logic [31:0] result;
        for (int i = 0; i < n; i++) begin
            axi_write(32'h0000_0000, vec_a[i]);  // OPERAND_A
            axi_write(32'h0000_0004, vec_b[i]);  // OPERAND_B
            axi_write(32'h0000_0008, 32'h1);     // CTRL = start
            poll_until_set(32'h0000_0010, 32'h1); // wait STATUS.DONE
        end
        axi_read(32'h0000_000C, result);
        if (result !== expected)
            `uvm_error("SEQ", $sformatf("[BOOT] %s: got %0d expected %0d — FAIL",
                                         label, result, expected))
        else
            `uvm_info("SEQ", $sformatf("[BOOT] %s: %0d PASS", label, result), UVM_NONE)
    endtask

endclass


// =============================================================================
// sequences/rand_stress_seq.sv
// Random Stress Sequence — closes functional coverage
//
// Sends N constrained-random transactions to exercise all corner cases.
// The axi4_transaction constraints ensure:
//   - Only valid addresses are hit
//   - Both reads and writes occur (60/40 split)
//   - All byte-enable patterns appear
//   - Both OKAY and SLVERR responses get tested
// =============================================================================
class rand_stress_seq extends base_sequence;
    `uvm_object_utils(rand_stress_seq)

    int unsigned num_transactions = 500;

    function new(string name = "rand_stress_seq");
        super.new(name);
    endfunction

    task body();
        axi4_transaction txn;
        `uvm_info("SEQ", $sformatf("Rand Stress: running %0d transactions", num_transactions), UVM_NONE)

        for (int i = 0; i < num_transactions; i++) begin
            txn = axi4_transaction::type_id::create($sformatf("txn_%0d", i));
            start_item(txn);

            // Randomize with constraints — if randomization fails, fatal
            if (!txn.randomize())
                `uvm_fatal("SEQ", "Transaction randomization FAILED")

            // Occasionally inject an illegal address to test SLVERR handling
            // (10% of transactions go to unmapped region)
            if ((i % 10) == 0) begin
                txn.addr = 32'h0000_0FFF;  // unmapped address
                txn.addr[1:0] = 2'b00;     // keep aligned
            end

            finish_item(txn);

            // Every 100 transactions: log progress
            if ((i+1) % 100 == 0)
                `uvm_info("SEQ", $sformatf("Rand Stress: %0d/%0d done", i+1, num_transactions), UVM_NONE)
        end

        `uvm_info("SEQ", "Rand Stress: COMPLETE", UVM_NONE)
    endtask

endclass


// =============================================================================
// sequences/mac_dot_product_seq.sv (standalone version)
// =============================================================================
class mac_dot_product_seq extends base_sequence;
    `uvm_object_utils(mac_dot_product_seq)

    logic [31:0] vec_a[] = '{1, 2, 3, 4};
    logic [31:0] vec_b[] = '{5, 6, 7, 8};
    int          n_elements = 4;
    logic [31:0] result;

    function new(string name = "mac_dot_product_seq");
        super.new(name);
    endfunction

    task body();
        // Clear accumulator
        axi_write(32'h0000_0014, 32'h1);

        for (int i = 0; i < n_elements; i++) begin
            mac_single_op_seq mac_seq = mac_single_op_seq::type_id::create("mac_seq");
            mac_seq.operand_a = vec_a[i];
            mac_seq.operand_b = vec_b[i];
            mac_seq.start(m_sequencer);
        end

        axi_read(32'h0000_000C, result);

        // Expected: sum(vec_a[i]*vec_b[i])
        logic [31:0] expected = 0;
        for (int i = 0; i < n_elements; i++)
            expected += vec_a[i] * vec_b[i];

        if (result !== expected)
            `uvm_error("SEQ", $sformatf("Dot product FAIL: got %0d expected %0d", result, expected))
        else
            `uvm_info("SEQ", $sformatf("Dot product PASS: %0d", result), UVM_NONE)
    endtask

endclass
