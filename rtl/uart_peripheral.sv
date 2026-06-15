// =============================================================================
// uart_peripheral.sv
// UART (Universal Asynchronous Receiver-Transmitter) — AXI-4 Lite Slave
//
// What UART is: The simplest serial communication protocol.
//   Two wires: TX (transmit) and RX (receive).
//   No clock wire — both sides agree on a baud rate in advance.
//   Each byte is framed: [START bit][8 data bits][STOP bit]
//
// Why we need it in this SoC:
//   - Bare-metal firmware uses UART like printf() — sending debug strings out
//   - During post-silicon bring-up, UART is often the FIRST thing you test
//     because it lets you see what the chip is doing without a debugger
//   - The Amazon JD explicitly mentions peripheral subsystems — this is one
//
// Register Map:
//   0x00  TX_DATA  [7:0]   — write a byte here to transmit it
//   0x04  STATUS   [1:0]   — bit 0: TX_BUSY, bit 1: RX_VALID
//   0x08  BAUD_DIV [15:0]  — clock divider for baud rate generation
//                             baud_rate = clk_freq / (BAUD_DIV + 1)
//                             e.g., 50MHz / 434 = ~115200 baud
//   0x0C  RX_DATA  [7:0]   — read a received byte here
// =============================================================================

module uart_peripheral #(
    parameter DATA_WIDTH  = 32,
    parameter ADDR_WIDTH  = 5,
    parameter CLK_FREQ_HZ = 50_000_000,  // 50 MHz default
    parameter DEFAULT_BAUD = 115200
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // AXI-4 Lite Slave Interface (same pattern as mac_accelerator)
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,
    input  logic [DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [3:0]            s_axi_wstrb,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,
    output logic [1:0]            s_axi_bresp,
    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,
    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready,
    output logic [DATA_WIDTH-1:0] s_axi_rdata,
    output logic [1:0]            s_axi_rresp,

    // Physical UART pins
    output logic                  uart_tx,  // to the outside world (e.g., a USB-UART chip)
    input  logic                  uart_rx,  // from the outside world

    // Status to interrupt controller
    output logic                  irq_rx_valid  // fires when a new byte arrives
);

// =============================================================================
// PARAMETERS & REGISTER FILE
// =============================================================================
// Default baud divider: how many clock cycles per UART bit
localparam DEFAULT_DIV = CLK_FREQ_HZ / DEFAULT_BAUD - 1;

logic [7:0]  reg_tx_data;    // byte to transmit
logic [15:0] reg_baud_div;   // baud rate divisor
logic [7:0]  reg_rx_data;    // last received byte
logic        reg_rx_valid;   // has a new byte arrived?

// =============================================================================
// BAUD RATE GENERATOR
// This counter generates a "tick" once per UART bit period.
// e.g., at 50MHz with baud_div=434: tick fires every 434 cycles → 115200 baud
// =============================================================================
logic [15:0] baud_counter;
logic        baud_tick;      // one-cycle pulse at baud rate

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        baud_counter <= '0;
        baud_tick    <= 1'b0;
    end else begin
        baud_tick <= 1'b0;  // default: no tick
        if (baud_counter >= reg_baud_div) begin
            baud_counter <= '0;
            baud_tick    <= 1'b1;  // one-cycle pulse
        end else begin
            baud_counter <= baud_counter + 1;
        end
    end
end

// =============================================================================
// TX STATE MACHINE
// Framing: IDLE → START → 8 data bits (LSB first) → STOP → IDLE
//
// The UART line is HIGH when idle ("mark" state).
// START bit pulls it LOW. STOP bit returns it HIGH.
// Receiver detects falling edge of START to synchronize.
// =============================================================================
typedef enum logic [1:0] {
    TX_IDLE  = 2'b00,
    TX_START = 2'b01,
    TX_DATA  = 2'b10,
    TX_STOP  = 2'b11
} tx_state_t;

tx_state_t   tx_state;
logic [7:0]  tx_shift_reg;   // data being shifted out
logic [2:0]  tx_bit_cnt;     // counts 0..7 for the 8 data bits
logic        tx_start_req;   // software wrote to TX_DATA register

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_state    <= TX_IDLE;
        uart_tx     <= 1'b1;   // idle HIGH
        tx_shift_reg <= '0;
        tx_bit_cnt  <= '0;
        tx_start_req <= 1'b0;
    end else begin
        if (tx_start_req) tx_start_req <= 1'b0;  // clear request

        if (baud_tick) begin
            case (tx_state)
                TX_IDLE: begin
                    uart_tx <= 1'b1;  // line idles HIGH
                    if (tx_start_req) begin
                        tx_shift_reg <= reg_tx_data;  // load data
                        tx_bit_cnt   <= '0;
                        tx_state     <= TX_START;
                    end
                end

                TX_START: begin
                    uart_tx  <= 1'b0;   // START bit = LOW
                    tx_state <= TX_DATA;
                end

                TX_DATA: begin
                    // Shift out LSB first — this is the UART convention
                    uart_tx      <= tx_shift_reg[0];
                    tx_shift_reg <= {1'b0, tx_shift_reg[7:1]};  // right-shift
                    if (tx_bit_cnt == 3'd7) begin
                        tx_state <= TX_STOP;
                    end else begin
                        tx_bit_cnt <= tx_bit_cnt + 1;
                    end
                end

                TX_STOP: begin
                    uart_tx  <= 1'b1;   // STOP bit = HIGH
                    tx_state <= TX_IDLE;
                end
            endcase
        end
    end
end

// TX is busy when not in IDLE state
logic tx_busy;
assign tx_busy = (tx_state != TX_IDLE);

// =============================================================================
// RX STATE MACHINE (simplified — samples at baud_tick for clarity)
// A production receiver would oversample at 16x baud for better noise immunity.
// That's a great enhancement to add in week 4!
// =============================================================================
typedef enum logic [1:0] {
    RX_IDLE  = 2'b00,
    RX_START = 2'b01,
    RX_DATA  = 2'b10,
    RX_STOP  = 2'b11
} rx_state_t;

rx_state_t   rx_state;
logic [7:0]  rx_shift_reg;
logic [2:0]  rx_bit_cnt;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_state    <= RX_IDLE;
        rx_shift_reg <= '0;
        rx_bit_cnt  <= '0;
        reg_rx_data <= '0;
        reg_rx_valid <= 1'b0;
        irq_rx_valid <= 1'b0;
    end else begin
        irq_rx_valid <= 1'b0;

        if (baud_tick) begin
            case (rx_state)
                RX_IDLE: begin
                    if (!uart_rx) begin  // detect START bit (falling edge → LOW)
                        rx_bit_cnt <= '0;
                        rx_state   <= RX_DATA;
                    end
                end

                RX_DATA: begin
                    // Sample incoming bit into MSB, shift right
                    rx_shift_reg <= {uart_rx, rx_shift_reg[7:1]};
                    if (rx_bit_cnt == 3'd7) begin
                        rx_state <= RX_STOP;
                    end else begin
                        rx_bit_cnt <= rx_bit_cnt + 1;
                    end
                end

                RX_STOP: begin
                    if (uart_rx) begin  // valid STOP bit = HIGH
                        reg_rx_data  <= rx_shift_reg;
                        reg_rx_valid <= 1'b1;
                        irq_rx_valid <= 1'b1;  // interrupt: new byte available
                    end
                    rx_state <= RX_IDLE;
                end

                default: rx_state <= RX_IDLE;
            endcase
        end

        // Software clears rx_valid by reading RX_DATA register
        if (s_axi_rvalid && s_axi_rready && rd_addr_latch[4:2] == 3'h3)
            reg_rx_valid <= 1'b0;
    end
end

// =============================================================================
// AXI-4 LITE WRITE PATH (same pattern as mac_accelerator)
// =============================================================================
logic [ADDR_WIDTH-1:0] wr_addr_latch;
logic [DATA_WIDTH-1:0] wr_data_latch;
logic                  aw_captured, w_captured;

assign s_axi_awready = ~aw_captured;
assign s_axi_wready  = ~w_captured;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        aw_captured  <= '0;
        w_captured   <= '0;
        wr_addr_latch <= '0;
        wr_data_latch <= '0;
        reg_baud_div <= DEFAULT_DIV[15:0];
        reg_tx_data  <= '0;
        s_axi_bvalid <= 1'b0;
        s_axi_bresp  <= 2'b00;
        tx_start_req <= 1'b0;
    end else begin
        if (s_axi_awvalid && s_axi_awready) begin
            wr_addr_latch <= s_axi_awaddr;
            aw_captured   <= 1'b1;
        end
        if (s_axi_wvalid && s_axi_wready) begin
            wr_data_latch <= s_axi_wdata;
            w_captured    <= 1'b1;
        end
        if (aw_captured && w_captured) begin
            aw_captured <= 1'b0;
            w_captured  <= 1'b0;
            case (wr_addr_latch[4:2])
                3'h0: begin
                    reg_tx_data  <= wr_data_latch[7:0];
                    tx_start_req <= 1'b1;  // trigger transmission
                end
                3'h2: reg_baud_div <= wr_data_latch[15:0];
                default: ;
            endcase
            s_axi_bvalid <= 1'b1;
            s_axi_bresp  <= 2'b00;
        end
        if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
    end
end

// =============================================================================
// AXI-4 LITE READ PATH
// =============================================================================
logic [ADDR_WIDTH-1:0] rd_addr_latch;
logic                  rd_pending;

assign s_axi_arready = ~rd_pending;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_pending    <= 1'b0;
        rd_addr_latch <= '0;
        s_axi_rvalid  <= 1'b0;
        s_axi_rdata   <= '0;
        s_axi_rresp   <= 2'b00;
    end else begin
        if (s_axi_arvalid && s_axi_arready) begin
            rd_addr_latch <= s_axi_araddr;
            rd_pending    <= 1'b1;
        end
        if (rd_pending && !s_axi_rvalid) begin
            rd_pending   <= 1'b0;
            s_axi_rvalid <= 1'b1;
            s_axi_rresp  <= 2'b00;
            case (rd_addr_latch[4:2])
                3'h0: s_axi_rdata <= {24'b0, reg_tx_data};
                3'h1: s_axi_rdata <= {30'b0, reg_rx_valid, tx_busy};  // STATUS
                3'h2: s_axi_rdata <= {16'b0, reg_baud_div};
                3'h3: s_axi_rdata <= {24'b0, reg_rx_data};
                default: s_axi_rdata <= 32'hDEAD_BEEF;
            endcase
        end
        if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
    end
end

// =============================================================================
// SVA: TX line must not glitch to LOW during IDLE state
// =============================================================================
property tx_idle_high;
    @(posedge clk) disable iff (!rst_n)
    (tx_state == TX_IDLE) |-> uart_tx;
endproperty
assert property (tx_idle_high)
    else $error("ASSERTION FAIL: uart_tx went LOW during TX_IDLE");

endmodule
