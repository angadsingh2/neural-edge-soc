// =============================================================================
// neural_edge_soc.sv — Top-Level SoC Integration
//
// This is the "glue" module. It instantiates all subsystems and connects them
// to a shared AXI-4 Lite bus with a simple address-decode scheme.
//
// Address Map (from CPU/Master perspective):
//   0x0000_0000 – 0x0000_003F  →  MAC Accelerator
//   0x0000_0100 – 0x0000_011F  →  UART Peripheral
//   0x0000_0200 – 0x0000_020F  →  GPIO
//   0x0000_0300 – 0x0000_030F  →  Interrupt Controller
//
// This is exactly how real SoCs work. The CPU sees one flat address space.
// The interconnect (our simple mux) decodes the upper bits of the address
// to select which slave gets the transaction.
// =============================================================================

module neural_edge_soc #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 32    // full 32-bit address space
) (
    input  logic clk,
    input  logic rst_n,

    // ── Master AXI-4 Lite Port (CPU / testbench drives this) ─────────────────
    input  logic                    m_axi_awvalid,
    output logic                    m_axi_awready,
    input  logic [ADDR_WIDTH-1:0]   m_axi_awaddr,
    input  logic                    m_axi_wvalid,
    output logic                    m_axi_wready,
    input  logic [DATA_WIDTH-1:0]   m_axi_wdata,
    input  logic [3:0]              m_axi_wstrb,
    output logic                    m_axi_bvalid,
    input  logic                    m_axi_bready,
    output logic [1:0]              m_axi_bresp,
    input  logic                    m_axi_arvalid,
    output logic                    m_axi_arready,
    input  logic [ADDR_WIDTH-1:0]   m_axi_araddr,
    output logic                    m_axi_rvalid,
    input  logic                    m_axi_rready,
    output logic [DATA_WIDTH-1:0]   m_axi_rdata,
    output logic [1:0]              m_axi_rresp,

    // ── Physical I/O ──────────────────────────────────────────────────────────
    output logic        uart_tx,
    input  logic        uart_rx,
    inout  logic [7:0]  gpio_pins,  // bidirectional GPIO

    // ── Interrupts out to CPU ─────────────────────────────────────────────────
    output logic        irq_to_cpu
);

// =============================================================================
// SLAVE AXI SIGNAL BUSES
// We have 4 slaves. Create one set of AXI signals per slave.
// The naming convention is: s{N}_axi_* where N is slave index.
// =============================================================================

// Slave 0: MAC Accelerator
logic        s0_awvalid, s0_awready, s0_wvalid, s0_wready;
logic        s0_bvalid,  s0_bready,  s0_arvalid, s0_arready;
logic        s0_rvalid,  s0_rready;
logic [1:0]  s0_bresp,   s0_rresp;
logic [5:0]  s0_awaddr,  s0_araddr;
logic [31:0] s0_wdata,   s0_rdata;
logic [3:0]  s0_wstrb;
logic        s0_irq;

// Slave 1: UART
logic        s1_awvalid, s1_awready, s1_wvalid, s1_wready;
logic        s1_bvalid,  s1_bready,  s1_arvalid, s1_arready;
logic        s1_rvalid,  s1_rready;
logic [1:0]  s1_bresp,   s1_rresp;
logic [4:0]  s1_awaddr,  s1_araddr;
logic [31:0] s1_wdata,   s1_rdata;
logic [3:0]  s1_wstrb;
logic        s1_irq;

// Slave 2: GPIO
logic        s2_awvalid, s2_awready, s2_wvalid, s2_wready;
logic        s2_bvalid,  s2_bready,  s2_arvalid, s2_arready;
logic        s2_rvalid,  s2_rready;
logic [1:0]  s2_bresp,   s2_rresp;
logic [3:0]  s2_awaddr,  s2_araddr;
logic [31:0] s2_wdata,   s2_rdata;
logic [3:0]  s2_wstrb;

// =============================================================================
// ADDRESS DECODER
// Decode the top bits of the master address to select the target slave.
// This is a combinational block — no registers, pure logic.
//
// Think of it like a post office: the full address is "0x0000_0104".
// The decoder looks at the upper bits (0x0000_01xx) and routes to UART.
// =============================================================================
typedef enum logic [1:0] {
    SEL_MAC  = 2'b00,
    SEL_UART = 2'b01,
    SEL_GPIO = 2'b10,
    SEL_NONE = 2'b11
} slave_sel_t;

slave_sel_t wr_sel, rd_sel;

// Write address decode
always_comb begin
    case (m_axi_awaddr[11:8])  // bits [11:8] = slave select
        4'h0:    wr_sel = SEL_MAC;
        4'h1:    wr_sel = SEL_UART;
        4'h2:    wr_sel = SEL_GPIO;
        default: wr_sel = SEL_NONE;
    endcase
end

// Read address decode
always_comb begin
    case (m_axi_araddr[11:8])
        4'h0:    rd_sel = SEL_MAC;
        4'h1:    rd_sel = SEL_UART;
        4'h2:    rd_sel = SEL_GPIO;
        default: rd_sel = SEL_NONE;
    endcase
end

// =============================================================================
// WRITE CHANNEL MUX
// Route AW and W channels to the selected slave.
// All non-selected slaves get valid=0 so they ignore the transaction.
// The master's awready/wready/bvalid come from the selected slave.
// =============================================================================
always_comb begin
    // Default: tie off all slave valids to 0
    s0_awvalid = 1'b0; s0_wvalid = 1'b0; s0_bready = 1'b0;
    s1_awvalid = 1'b0; s1_wvalid = 1'b0; s1_bready = 1'b0;
    s2_awvalid = 1'b0; s2_wvalid = 1'b0; s2_bready = 1'b0;

    // Default master responses (will be overridden by selected slave)
    m_axi_awready = 1'b0;
    m_axi_wready  = 1'b0;
    m_axi_bvalid  = 1'b0;
    m_axi_bresp   = 2'b10;  // SLVERR if no slave selected

    case (wr_sel)
        SEL_MAC: begin
            s0_awvalid    = m_axi_awvalid;
            s0_awaddr     = m_axi_awaddr[5:0];
            s0_wvalid     = m_axi_wvalid;
            s0_wdata      = m_axi_wdata;
            s0_wstrb      = m_axi_wstrb;
            s0_bready     = m_axi_bready;
            m_axi_awready = s0_awready;
            m_axi_wready  = s0_wready;
            m_axi_bvalid  = s0_bvalid;
            m_axi_bresp   = s0_bresp;
        end
        SEL_UART: begin
            s1_awvalid    = m_axi_awvalid;
            s1_awaddr     = m_axi_awaddr[4:0];
            s1_wvalid     = m_axi_wvalid;
            s1_wdata      = m_axi_wdata;
            s1_wstrb      = m_axi_wstrb;
            s1_bready     = m_axi_bready;
            m_axi_awready = s1_awready;
            m_axi_wready  = s1_wready;
            m_axi_bvalid  = s1_bvalid;
            m_axi_bresp   = s1_bresp;
        end
        SEL_GPIO: begin
            s2_awvalid    = m_axi_awvalid;
            s2_awaddr     = m_axi_awaddr[3:0];
            s2_wvalid     = m_axi_wvalid;
            s2_wdata      = m_axi_wdata;
            s2_wstrb      = m_axi_wstrb;
            s2_bready     = m_axi_bready;
            m_axi_awready = s2_awready;
            m_axi_wready  = s2_wready;
            m_axi_bvalid  = s2_bvalid;
            m_axi_bresp   = s2_bresp;
        end
        default: ; // m_axi_bresp already set to SLVERR above
    endcase
end

// =============================================================================
// READ CHANNEL MUX (same idea)
// =============================================================================
always_comb begin
    s0_arvalid = 1'b0; s0_rready = 1'b0;
    s1_arvalid = 1'b0; s1_rready = 1'b0;
    s2_arvalid = 1'b0; s2_rready = 1'b0;

    m_axi_arready = 1'b0;
    m_axi_rvalid  = 1'b0;
    m_axi_rdata   = 32'hDEAD_BEEF;
    m_axi_rresp   = 2'b10;

    case (rd_sel)
        SEL_MAC: begin
            s0_arvalid    = m_axi_arvalid;
            s0_araddr     = m_axi_araddr[5:0];
            s0_rready     = m_axi_rready;
            m_axi_arready = s0_arready;
            m_axi_rvalid  = s0_rvalid;
            m_axi_rdata   = s0_rdata;
            m_axi_rresp   = s0_rresp;
        end
        SEL_UART: begin
            s1_arvalid    = m_axi_arvalid;
            s1_araddr     = m_axi_araddr[4:0];
            s1_rready     = m_axi_rready;
            m_axi_arready = s1_arready;
            m_axi_rvalid  = s1_rvalid;
            m_axi_rdata   = s1_rdata;
            m_axi_rresp   = s1_rresp;
        end
        SEL_GPIO: begin
            s2_arvalid    = m_axi_arvalid;
            s2_araddr     = m_axi_araddr[3:0];
            s2_rready     = m_axi_rready;
            m_axi_arready = s2_arready;
            m_axi_rvalid  = s2_rvalid;
            m_axi_rdata   = s2_rdata;
            m_axi_rresp   = s2_rresp;
        end
        default: ;
    endcase
end

// =============================================================================
// INTERRUPT AGGREGATION
// Each peripheral has its own interrupt line. The interrupt controller
// (simplified here as an OR gate — real designs use an NVIC or PLIC)
// presents a single IRQ wire to the CPU.
// =============================================================================
assign irq_to_cpu = s0_irq | s1_irq;

// =============================================================================
// SUBSYSTEM INSTANTIATIONS
// =============================================================================

mac_accelerator u_mac (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axi_awvalid (s0_awvalid),
    .s_axi_awready (s0_awready),
    .s_axi_awaddr  (s0_awaddr),
    .s_axi_wvalid  (s0_wvalid),
    .s_axi_wready  (s0_wready),
    .s_axi_wdata   (s0_wdata),
    .s_axi_wstrb   (s0_wstrb),
    .s_axi_bvalid  (s0_bvalid),
    .s_axi_bready  (s0_bready),
    .s_axi_bresp   (s0_bresp),
    .s_axi_arvalid (s0_arvalid),
    .s_axi_arready (s0_arready),
    .s_axi_araddr  (s0_araddr),
    .s_axi_rvalid  (s0_rvalid),
    .s_axi_rready  (s0_rready),
    .s_axi_rdata   (s0_rdata),
    .s_axi_rresp   (s0_rresp),
    .irq_done      (s0_irq)
);

uart_peripheral u_uart (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axi_awvalid (s1_awvalid),
    .s_axi_awready (s1_awready),
    .s_axi_awaddr  (s1_awaddr),
    .s_axi_wvalid  (s1_wvalid),
    .s_axi_wready  (s1_wready),
    .s_axi_wdata   (s1_wdata),
    .s_axi_wstrb   (s1_wstrb),
    .s_axi_bvalid  (s1_bvalid),
    .s_axi_bready  (s1_bready),
    .s_axi_bresp   (s1_bresp),
    .s_axi_arvalid (s1_arvalid),
    .s_axi_arready (s1_arready),
    .s_axi_araddr  (s1_araddr),
    .s_axi_rvalid  (s1_rvalid),
    .s_axi_rready  (s1_rready),
    .s_axi_rdata   (s1_rdata),
    .s_axi_rresp   (s1_rresp),
    .uart_tx       (uart_tx),
    .uart_rx       (uart_rx),
    .irq_rx_valid  (s1_irq)
);

// GPIO placeholder (simple in/out register — implement as exercise!)
gpio_peripheral u_gpio (
    .clk           (clk),
    .rst_n         (rst_n),
    .s_axi_awvalid (s2_awvalid),
    .s_axi_awready (s2_awready),
    .s_axi_awaddr  (s2_awaddr),
    .s_axi_wvalid  (s2_wvalid),
    .s_axi_wready  (s2_wready),
    .s_axi_wdata   (s2_wdata),
    .s_axi_wstrb   (s2_wstrb),
    .s_axi_bvalid  (s2_bvalid),
    .s_axi_bready  (s2_bready),
    .s_axi_bresp   (s2_bresp),
    .s_axi_arvalid (s2_arvalid),
    .s_axi_arready (s2_arready),
    .s_axi_araddr  (s2_araddr),
    .s_axi_rvalid  (s2_rvalid),
    .s_axi_rready  (s2_rready),
    .s_axi_rdata   (s2_rdata),
    .s_axi_rresp   (s2_rresp),
    .gpio_pins     (gpio_pins)
);

endmodule
