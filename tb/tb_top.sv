// =============================================================================
// tb/tb_top.sv — Testbench Top-Level Module
//
// This is the entry point for simulation. It sits at the very top of the
// hierarchy and does four things:
//
//   1. Generates the clock and reset
//   2. Instantiates the DUT (Design Under Test) — our SoC
//   3. Instantiates the virtual interface and connects it to DUT ports
//   4. Passes the virtual interface handle into UVM via config_db,
//      then kicks off the UVM test
//
// In an emulation environment (Zebu/HAPs), this file's equivalent is
// the "partition file" that divides design from verification infrastructure.
// Understanding this file means you understand the full simulation stack.
//
// NOTE: tb_top is a MODULE, not a class. It lives in the hardware domain.
//       The UVM environment lives in the software domain.
//       This file is the ONLY place both worlds touch.
// =============================================================================

`timescale 1ns/1ps
`include "uvm_macros.svh"

import uvm_pkg::*;
import neural_edge_pkg::*;

module tb_top;

    // ── Clock and Reset Generation ────────────────────────────────────────
    // 50 MHz clock → period = 20 ns
    // rst_n is active-low: 0 = in reset, 1 = running
    logic clk;
    logic rst_n;

    initial clk = 0;
    always #10 clk = ~clk;  // toggle every 10 ns → 50 MHz

    // Reset sequence:
    //   - Assert reset (rst_n=0) for 10 clock cycles at simulation start
    //   - Deassert reset (rst_n=1) to let the DUT begin operating
    //   - The UVM run_phase waits for this before sending stimulus
    initial begin
        rst_n = 1'b0;
        repeat(10) @(posedge clk);
        @(negedge clk);        // deassert on negedge to avoid setup violations
        rst_n = 1'b1;
        `uvm_info("TB_TOP", "Reset deasserted — DUT is running", UVM_NONE)
    end

    // ── Virtual Interface Instantiation ───────────────────────────────────
    // The interface bundles all AXI + SoC I/O signals in one handle.
    // We pass clk and rst_n in so the clocking blocks inside can use them.
    neural_edge_if dut_if (
        .clk   (clk),
        .rst_n (rst_n)
    );

    // ── DUT Instantiation ─────────────────────────────────────────────────
    // Connect every DUT port to the corresponding interface signal.
    // This is the only place DUT ports are named explicitly.
    neural_edge_soc u_dut (
        .clk             (clk),
        .rst_n           (rst_n),

        // AXI master port (driven by UVM testbench via interface)
        .m_axi_awvalid   (dut_if.m_axi_awvalid),
        .m_axi_awready   (dut_if.m_axi_awready),
        .m_axi_awaddr    (dut_if.m_axi_awaddr),
        .m_axi_wvalid    (dut_if.m_axi_wvalid),
        .m_axi_wready    (dut_if.m_axi_wready),
        .m_axi_wdata     (dut_if.m_axi_wdata),
        .m_axi_wstrb     (dut_if.m_axi_wstrb),
        .m_axi_bvalid    (dut_if.m_axi_bvalid),
        .m_axi_bready    (dut_if.m_axi_bready),
        .m_axi_bresp     (dut_if.m_axi_bresp),
        .m_axi_arvalid   (dut_if.m_axi_arvalid),
        .m_axi_arready   (dut_if.m_axi_arready),
        .m_axi_araddr    (dut_if.m_axi_araddr),
        .m_axi_rvalid    (dut_if.m_axi_rvalid),
        .m_axi_rready    (dut_if.m_axi_rready),
        .m_axi_rdata     (dut_if.m_axi_rdata),
        .m_axi_rresp     (dut_if.m_axi_rresp),

        // Physical I/O
        .uart_tx         (dut_if.uart_tx),
        .uart_rx         (dut_if.uart_rx),
        .gpio_pins       (dut_if.gpio_pins),
        .irq_to_cpu      (dut_if.irq_to_cpu)
    );

    // ── UART RX tie-off ───────────────────────────────────────────────────
    // Pull uart_rx HIGH (idle state) when no sequence is driving it.
    // Without this, the UART RX FSM would see a false START bit.
    assign dut_if.uart_rx = 1'b1;

    // ── UVM Configuration and Kickoff ─────────────────────────────────────
    // uvm_config_db is UVM's global key-value store.
    // We store the virtual interface handle here so any UVM component
    // can retrieve it with uvm_config_db::get().
    //
    // Key: "vif"  Value: the interface handle  Scope: everything ("*")
    initial begin
        // Store interface in config_db BEFORE run_test() is called
        uvm_config_db #(virtual neural_edge_if)::set(
            null,    // context: null = root
            "*",     // scope: applies to all components
            "vif",   // key name
            dut_if   // the actual interface handle
        );

        // run_test() reads the +UVM_TESTNAME plusarg from the command line
        // and instantiates + runs that test class.
        // Example: +UVM_TESTNAME=mac_sanity_test
        run_test();
    end

    // ── Waveform Dump ─────────────────────────────────────────────────────
    // Dumps all signals to a VCD file for post-sim viewing in GTKWave.
    // In a production flow you'd use FSDB (Verdi) or VPD (DVE).
    initial begin
        $dumpfile("waves/neural_edge_tb.vcd");
        $dumpvars(0, tb_top);  // 0 = dump ALL levels of hierarchy
    end

    // ── Simulation Timeout ────────────────────────────────────────────────
    // Safety net: if simulation runs longer than 1ms (50M cycles at 50MHz),
    // something has hung. Kill it and report an error.
    initial begin
        #1_000_000_000;  // 1 second in ns = 1ms at 50MHz
        `uvm_fatal("TB_TOP", "SIMULATION TIMEOUT — possible infinite loop or deadlock")
    end

endmodule
