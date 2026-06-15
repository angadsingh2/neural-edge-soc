// =============================================================================
// uvm/coverage_collector.sv
// Functional Coverage Collector
//
// Coverage answers: "Have we tested everything we need to test?"
//
// There are two types of coverage:
//   1. Code coverage  — did we execute every line of RTL? (tool-generated)
//   2. Functional coverage — did we exercise every SCENARIO? (engineer-defined)
//
// This file defines functional coverage. We declare "covergroups" which are
// buckets of scenarios. The simulator fills the buckets as scenarios occur.
// When all buckets are full = 100% functional coverage.
//
// The Amazon JD asks for someone who can "develop test plans" — a coverage
// model IS the executable form of a test plan.
// =============================================================================

class coverage_collector extends uvm_subscriber #(axi4_transaction);
    `uvm_component_utils(coverage_collector)

    axi4_transaction txn;  // current transaction being processed

    // ── Covergroup 1: Register Access Coverage ────────────────────────────
    // Have we read and written every register?
    covergroup mac_reg_cg;
        cp_op: coverpoint txn.op {
            bins write_op = {axi4_transaction::AXI_WRITE};
            bins read_op  = {axi4_transaction::AXI_READ};
        }
        cp_mac_addr: coverpoint txn.addr iff
                     (txn.addr inside {[32'h0:32'h1F]}) {
            bins operand_a  = {32'h0000_0000};
            bins operand_b  = {32'h0000_0004};
            bins ctrl       = {32'h0000_0008};
            bins result     = {32'h0000_000C};
            bins status     = {32'h0000_0010};
            bins acc_clear  = {32'h0000_0014};
        }
        // Cross coverage: did we both READ and WRITE every register?
        cx_op_addr: cross cp_op, cp_mac_addr;
    endgroup

    // ── Covergroup 2: Data Pattern Coverage ───────────────────────────────
    // Have we tested edge cases in the data values?
    covergroup data_pattern_cg;
        cp_data: coverpoint txn.data {
            bins zero       = {32'h0000_0000};
            bins all_ones   = {32'hFFFF_FFFF};
            bins walking_1  = {32'h0000_0001, 32'h0000_0002, 32'h0000_0004,
                               32'h0000_0008, 32'h0000_0010, 32'h0000_0020};
            bins mid_range  = {[32'h0000_0010 : 32'h0000_00FF]};
            bins large      = {[32'h0001_0000 : 32'hFFFE_FFFF]};
        }
    endgroup

    // ── Covergroup 3: Write Strobe Coverage ───────────────────────────────
    // AXI wstrb selects which bytes to write. Have we tested all patterns?
    covergroup wstrb_cg;
        cp_wstrb: coverpoint txn.wstrb iff (txn.op == axi4_transaction::AXI_WRITE) {
            bins full_word  = {4'b1111};  // write all 4 bytes
            bins byte0_only = {4'b0001};  // write only byte 0
            bins byte3_only = {4'b1000};  // write only byte 3
            bins lower_half = {4'b0011};  // write bytes 0 and 1
            bins upper_half = {4'b1100};  // write bytes 2 and 3
        }
    endgroup

    // ── Covergroup 4: Back-to-Back Transaction Coverage ───────────────────
    // Have we seen consecutive writes, consecutive reads, and alternating?
    axi4_transaction::axi_op_e prev_op;
    covergroup consecutive_cg;
        cp_seq: coverpoint {prev_op, txn.op} {
            bins wr_wr = {2'b00};  // write then write
            bins wr_rd = {2'b01};  // write then read
            bins rd_wr = {2'b10};  // read then write
            bins rd_rd = {2'b11};  // read then read
        }
    endgroup

    // ── Covergroup 5: Response Coverage ───────────────────────────────────
    // Have we seen both OKAY and SLVERR responses?
    covergroup response_cg;
        cp_bresp: coverpoint txn.bresp iff (txn.op == axi4_transaction::AXI_WRITE) {
            bins okay   = {2'b00};
            bins slverr = {2'b10};
        }
        cp_rresp: coverpoint txn.rresp iff (txn.op == axi4_transaction::AXI_READ) {
            bins okay   = {2'b00};
            bins slverr = {2'b10};
        }
    endgroup

    // Instantiate all covergroups
    mac_reg_cg     mac_reg_cov;
    data_pattern_cg data_pat_cov;
    wstrb_cg        wstrb_cov;
    consecutive_cg  consec_cov;
    response_cg     resp_cov;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        mac_reg_cov  = new();
        data_pat_cov = new();
        wstrb_cov    = new();
        consec_cov   = new();
        resp_cov     = new();
        prev_op      = axi4_transaction::AXI_READ;  // initial "previous"
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
    endfunction

    // write(): called for every observed transaction — sample all covergroups
    function void write(axi4_transaction t);
        txn = t;
        mac_reg_cov.sample();
        data_pat_cov.sample();
        wstrb_cov.sample();
        consec_cov.sample();
        resp_cov.sample();
        prev_op = t.op;
    endfunction

    // report coverage at end of simulation
    function void report_phase(uvm_phase phase);
        `uvm_info("COV", $sformatf("MAC Reg Coverage:   %.1f%%", mac_reg_cov.get_coverage()),  UVM_NONE)
        `uvm_info("COV", $sformatf("Data Pattern Cov:   %.1f%%", data_pat_cov.get_coverage()), UVM_NONE)
        `uvm_info("COV", $sformatf("WSTRB Coverage:     %.1f%%", wstrb_cov.get_coverage()),    UVM_NONE)
        `uvm_info("COV", $sformatf("Back-to-Back Cov:   %.1f%%", consec_cov.get_coverage()),   UVM_NONE)
        `uvm_info("COV", $sformatf("Response Coverage:  %.1f%%", resp_cov.get_coverage()),     UVM_NONE)
    endfunction

endclass
