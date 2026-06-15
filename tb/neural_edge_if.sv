// =============================================================================
// neural_edge_if.sv — Virtual Interface
//
// A virtual interface is the BRIDGE between the UVM world (class-based,
// object-oriented) and the RTL world (signal-based, hardware).
//
// Problem: UVM components are SystemVerilog classes. Classes live in software
// space — they can't directly access module ports (hardware signals).
// Solution: define an interface (a bundle of signals), pass a "virtual" handle
// to it into every UVM component, and let them drive/sample through that handle.
//
// Think of it like a USB cable:
//   - The interface   = the physical USB port on the device
//   - virtual if vif  = the cable plugged in — any component holding the cable
//                       can talk to the device
//
// This file declares ALL signals that cross the hardware/software boundary.
// tb_top.sv instantiates this interface and connects it to the DUT ports.
// The UVM env receives a handle via uvm_config_db.
// =============================================================================

interface neural_edge_if (
    input logic clk,
    input logic rst_n
);

    // ── AXI-4 Lite Master Signals (driven by UVM driver, read by DUT) ─────
    // Write address channel
    logic        m_axi_awvalid;
    logic        m_axi_awready;   // driven by DUT
    logic [31:0] m_axi_awaddr;

    // Write data channel
    logic        m_axi_wvalid;
    logic        m_axi_wready;    // driven by DUT
    logic [31:0] m_axi_wdata;
    logic [3:0]  m_axi_wstrb;

    // Write response channel
    logic        m_axi_bvalid;   // driven by DUT
    logic        m_axi_bready;
    logic [1:0]  m_axi_bresp;    // driven by DUT

    // Read address channel
    logic        m_axi_arvalid;
    logic        m_axi_arready;  // driven by DUT
    logic [31:0] m_axi_araddr;

    // Read data channel
    logic        m_axi_rvalid;   // driven by DUT
    logic        m_axi_rready;
    logic [31:0] m_axi_rdata;    // driven by DUT
    logic [1:0]  m_axi_rresp;    // driven by DUT

    // ── SoC I/O (observed by monitor) ────────────────────────────────────
    logic        uart_tx;        // driven by DUT
    logic        uart_rx;        // driven by testbench
    logic [7:0]  gpio_pins;      // bidirectional
    logic        irq_to_cpu;     // driven by DUT

    // ── Clocking Block (for driver — synchronous stimulus) ────────────────
    // The clocking block adds one-cycle setup time automatically.
    // Inputs sampled on negedge (after DUT drives them on posedge).
    // Outputs driven on posedge with #1 skew to avoid race conditions.
    clocking master_cb @(posedge clk);
        default input #1step output #1;

        output m_axi_awvalid, m_axi_awaddr;
        output m_axi_wvalid, m_axi_wdata, m_axi_wstrb;
        output m_axi_bready;
        output m_axi_arvalid, m_axi_araddr;
        output m_axi_rready;
        output uart_rx;

        input  m_axi_awready;
        input  m_axi_wready;
        input  m_axi_bvalid, m_axi_bresp;
        input  m_axi_arready;
        input  m_axi_rvalid, m_axi_rdata, m_axi_rresp;
        input  uart_tx;
        input  irq_to_cpu;
    endclocking

    // ── Monitor Clocking Block (passive, input-only) ──────────────────────
    clocking monitor_cb @(posedge clk);
        default input #1step;
        input m_axi_awvalid, m_axi_awaddr, m_axi_awready;
        input m_axi_wvalid,  m_axi_wdata,  m_axi_wready, m_axi_wstrb;
        input m_axi_bvalid,  m_axi_bresp,  m_axi_bready;
        input m_axi_arvalid, m_axi_araddr, m_axi_arready;
        input m_axi_rvalid,  m_axi_rdata,  m_axi_rresp,  m_axi_rready;
        input uart_tx, irq_to_cpu;
    endclocking

    // ── Modport declarations ──────────────────────────────────────────────
    // Modports restrict which signals each component can see.
    // The driver uses MASTER, the monitor uses MONITOR, DUT uses SLAVE.
    modport MASTER  (clocking master_cb,  input clk, rst_n);
    modport MONITOR (clocking monitor_cb, input clk, rst_n);
    modport SLAVE   (
        input  m_axi_awvalid, m_axi_awaddr,
        output m_axi_awready,
        input  m_axi_wvalid,  m_axi_wdata, m_axi_wstrb,
        output m_axi_wready,
        output m_axi_bvalid,  m_axi_bresp,
        input  m_axi_bready,
        input  m_axi_arvalid, m_axi_araddr,
        output m_axi_arready,
        output m_axi_rvalid,  m_axi_rdata, m_axi_rresp,
        input  m_axi_rready,
        output uart_tx,
        input  uart_rx,
        inout  gpio_pins,
        output irq_to_cpu,
        input  clk, rst_n
    );

    // ── Interface-level Assertions ────────────────────────────────────────
    // These fire regardless of which testbench is running.
    // Good practice: protocol rules that must ALWAYS hold go here.

    // AXI rule: AWVALID must not deassert before handshake
    property awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_awvalid && !m_axi_awready) |=> m_axi_awvalid;
    endproperty
    assert property (awvalid_stable)
        else $error("[IF ASSERT] AWVALID dropped before AWREADY — AXI protocol violation");

    // AXI rule: ARVALID must not deassert before handshake
    property arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_arvalid && !m_axi_arready) |=> m_axi_arvalid;
    endproperty
    assert property (arvalid_stable)
        else $error("[IF ASSERT] ARVALID dropped before ARREADY — AXI protocol violation");

    // AXI rule: WVALID must not deassert before handshake
    property wvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_wvalid && !m_axi_wready) |=> m_axi_wvalid;
    endproperty
    assert property (wvalid_stable)
        else $error("[IF ASSERT] WVALID dropped before WREADY — AXI protocol violation");

endinterface
