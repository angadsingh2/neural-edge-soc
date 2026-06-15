// =============================================================================
// uvm/scoreboard.sv
// Self-Checking Scoreboard
//
// The scoreboard is the "brain" of verification — it decides PASS or FAIL.
//
// How it works:
//   1. Receives every observed transaction from the monitor (via analysis port)
//   2. Maintains a "golden reference model" — a software model of what the
//      DUT SHOULD do (called a "reference model" or "C model" in industry)
//   3. Compares DUT output vs reference model output
//   4. Reports PASS/FAIL and tracks error counts
//
// The reference model here mirrors the MAC register file in software.
// If the RTL and the software model diverge, we found a bug.
//
// In Amazon's context: the scoreboard IS the validation plan in code form.
// Every functional requirement has a check here.
// =============================================================================

class scoreboard extends uvm_scoreboard;
    `uvm_component_utils(scoreboard)

    // Analysis export: receives transactions from monitor
    uvm_analysis_imp #(axi4_transaction, scoreboard) analysis_export;

    // ── Reference Model (shadow register file) ────────────────────────────
    // We maintain a software copy of every register.
    // After each write, we update this model.
    // After each read, we compare the DUT's returned value to this model.
    logic [31:0] ref_mac_operand_a;
    logic [31:0] ref_mac_operand_b;
    logic [31:0] ref_mac_result;     // predicted accumulated result
    logic [31:0] ref_uart_baud_div;

    // ── Statistics ────────────────────────────────────────────────────────
    int unsigned num_checks;
    int unsigned num_errors;
    int unsigned num_writes;
    int unsigned num_reads;

    // Pending read-address queue: track what address each read was for
    // (The monitor gives us addr on AR phase and data on R phase separately)
    logic [31:0] pending_read_addr[$];  // FIFO queue

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        analysis_export = new("analysis_export", this);
        // Initialize reference model
        ref_mac_operand_a = '0;
        ref_mac_operand_b = '0;
        ref_mac_result    = '0;
        ref_uart_baud_div = 433;  // default baud divider
        num_checks = 0; num_errors = 0;
        num_writes = 0; num_reads  = 0;
    endfunction

    // write(): called by analysis port every time monitor sees a transaction
    // This is UVM's subscriber pattern — the port calls this function automatically
    function void write(axi4_transaction txn);
        if (txn.op == axi4_transaction::AXI_WRITE)
            process_write(txn);
        else
            process_read(txn);
    endfunction

    // ── Process Write Transaction ──────────────────────────────────────────
    function void process_write(axi4_transaction txn);
        num_writes++;

        // Check 1: All writes to valid addresses should return OKAY
        if (txn.addr inside {[32'h0:32'h3F], [32'h100:32'h11F], [32'h200:32'h20F]}) begin
            check("WRITE BRESP", txn.bresp, 2'b00,
                  $sformatf("Write to 0x%08X returned non-OKAY response", txn.addr));
        end

        // Update reference model based on what was written
        case (txn.addr)
            32'h0000_0000: ref_mac_operand_a = txn.data;
            32'h0000_0004: ref_mac_operand_b = txn.data;
            32'h0000_0008: begin  // MAC CTRL — triggers computation in our model
                if (txn.data[0]) begin
                    // Predict the MAC result
                    ref_mac_result = ref_mac_result +
                                     (ref_mac_operand_a * ref_mac_operand_b);
                    `uvm_info("SCB", $sformatf("Reference MAC: %0d + %0d*%0d = %0d",
                              ref_mac_result - ref_mac_operand_a*ref_mac_operand_b,
                              ref_mac_operand_a, ref_mac_operand_b,
                              ref_mac_result), UVM_MEDIUM)
                end
            end
            32'h0000_0014: begin  // ACC_CLEAR
                if (txn.data[0]) ref_mac_result = '0;
            end
            32'h0000_0108: ref_uart_baud_div = {16'b0, txn.data[15:0]};
        endcase
    endfunction

    // ── Process Read Transaction ───────────────────────────────────────────
    function void process_read(axi4_transaction txn);
        logic [31:0] expected;
        num_reads++;

        // Check response code
        check("READ RRESP", {30'b0, txn.rresp}, {30'b0, 2'b00},
              $sformatf("Read from 0x%08X returned non-OKAY response", txn.addr));

        // Check data against reference model
        case (txn.addr)
            32'h0000_0000: check("MAC OPERAND_A", txn.data, ref_mac_operand_a,
                                 "MAC OPERAND_A readback mismatch");
            32'h0000_0004: check("MAC OPERAND_B", txn.data, ref_mac_operand_b,
                                 "MAC OPERAND_B readback mismatch");
            32'h0000_000C: check("MAC RESULT", txn.data, ref_mac_result,
                                 "MAC RESULT mismatch — computation error!");
            32'h0000_0108: check("UART BAUD_DIV", txn.data, ref_uart_baud_div,
                                 "UART BAUD_DIV readback mismatch");
            // STATUS and other registers: just log, don't check value
            // (STATUS depends on timing which the reference model doesn't track)
            default: `uvm_info("SCB", $sformatf("Read from 0x%08X = 0x%08X (not checked)",
                               txn.addr, txn.data), UVM_HIGH)
        endcase
    endfunction

    // ── Generic Check Helper ──────────────────────────────────────────────
    function void check(string name, logic [31:0] got, logic [31:0] expected,
                        string msg);
        num_checks++;
        if (got !== expected) begin
            num_errors++;
            `uvm_error("SCB", $sformatf("[FAIL] %s: got=0x%08X expected=0x%08X — %s",
                                         name, got, expected, msg))
        end else begin
            `uvm_info("SCB", $sformatf("[PASS] %s: 0x%08X", name, got), UVM_HIGH)
        end
    endfunction

    // ── Final Report ──────────────────────────────────────────────────────
    function void report_phase(uvm_phase phase);
        `uvm_info("SCB", "============================================", UVM_NONE)
        `uvm_info("SCB", $sformatf("  Writes:  %0d", num_writes),  UVM_NONE)
        `uvm_info("SCB", $sformatf("  Reads:   %0d", num_reads),   UVM_NONE)
        `uvm_info("SCB", $sformatf("  Checks:  %0d", num_checks),  UVM_NONE)
        `uvm_info("SCB", $sformatf("  Errors:  %0d", num_errors),  UVM_NONE)
        if (num_errors == 0)
            `uvm_info("SCB", "  Result:  ** PASS **", UVM_NONE)
        else
            `uvm_error("SCB", $sformatf("  Result:  ** FAIL ** (%0d errors)", num_errors))
        `uvm_info("SCB", "============================================", UVM_NONE)
    endfunction

endclass
