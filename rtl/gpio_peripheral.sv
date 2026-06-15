// =============================================================================
// gpio_peripheral.sv
// General Purpose Input/Output — AXI-4 Lite Slave
//
// Register Map:
//   0x00  DATA_OUT  [7:0]  — drive GPIO pins HIGH/LOW
//   0x04  DIR       [7:0]  — 1=output, 0=input (per bit)
//   0x08  DATA_IN   [7:0]  — read current pin state (read-only)
// =============================================================================

module gpio_peripheral #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 4,
    parameter GPIO_WIDTH = 8
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,
    input  logic [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,
    input  logic [DATA_WIDTH-1:0]   s_axi_wdata,
    input  logic [3:0]              s_axi_wstrb,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,
    output logic [1:0]              s_axi_bresp,

    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,
    input  logic [ADDR_WIDTH-1:0]   s_axi_araddr,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready,
    output logic [DATA_WIDTH-1:0]   s_axi_rdata,
    output logic [1:0]              s_axi_rresp,

    inout  logic [GPIO_WIDTH-1:0]   gpio_pins
);

logic [GPIO_WIDTH-1:0] reg_data_out;
logic [GPIO_WIDTH-1:0] reg_dir;        // 1=output, 0=input
logic [GPIO_WIDTH-1:0] gpio_in_sync;   // 2-FF synchronized input

// 2-FF synchronizer for each input pin (prevents metastability)
logic [GPIO_WIDTH-1:0] sync_ff1, sync_ff2;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sync_ff1 <= '0;
        sync_ff2 <= '0;
    end else begin
        sync_ff1 <= gpio_pins;
        sync_ff2 <= sync_ff1;
    end
end
assign gpio_in_sync = sync_ff2;

// Tristate drive: output when dir=1, high-Z when dir=0
genvar i;
generate
    for (i = 0; i < GPIO_WIDTH; i++) begin : gpio_tristate
        assign gpio_pins[i] = reg_dir[i] ? reg_data_out[i] : 1'bz;
    end
endgenerate

// Write path
logic [ADDR_WIDTH-1:0] wr_addr_latch;
logic [DATA_WIDTH-1:0] wr_data_latch;
logic                  aw_captured, w_captured;

assign s_axi_awready = ~aw_captured;
assign s_axi_wready  = ~w_captured;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        aw_captured  <= 1'b0; w_captured <= 1'b0;
        wr_addr_latch <= '0;  wr_data_latch <= '0;
        reg_data_out <= '0;   reg_dir <= '0;
        s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00;
    end else begin
        if (s_axi_awvalid && s_axi_awready) begin wr_addr_latch <= s_axi_awaddr; aw_captured <= 1'b1; end
        if (s_axi_wvalid  && s_axi_wready)  begin wr_data_latch <= s_axi_wdata;  w_captured  <= 1'b1; end
        if (aw_captured && w_captured) begin
            aw_captured <= 1'b0; w_captured <= 1'b0;
            case (wr_addr_latch[3:2])
                2'h0: reg_data_out <= wr_data_latch[GPIO_WIDTH-1:0];
                2'h1: reg_dir      <= wr_data_latch[GPIO_WIDTH-1:0];
                default: ;
            endcase
            s_axi_bvalid <= 1'b1; s_axi_bresp <= 2'b00;
        end
        if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
    end
end

// Read path
logic [ADDR_WIDTH-1:0] rd_addr_latch;
logic                  rd_pending;
assign s_axi_arready = ~rd_pending;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_pending <= 1'b0; rd_addr_latch <= '0;
        s_axi_rvalid <= 1'b0; s_axi_rdata <= '0; s_axi_rresp <= 2'b00;
    end else begin
        if (s_axi_arvalid && s_axi_arready) begin rd_addr_latch <= s_axi_araddr; rd_pending <= 1'b1; end
        if (rd_pending && !s_axi_rvalid) begin
            rd_pending <= 1'b0; s_axi_rvalid <= 1'b1; s_axi_rresp <= 2'b00;
            case (rd_addr_latch[3:2])
                2'h0: s_axi_rdata <= {24'b0, reg_data_out};
                2'h1: s_axi_rdata <= {24'b0, reg_dir};
                2'h2: s_axi_rdata <= {24'b0, gpio_in_sync};
                default: s_axi_rdata <= 32'hDEAD_BEEF;
            endcase
        end
        if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
    end
end

endmodule
