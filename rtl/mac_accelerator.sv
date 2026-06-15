// =============================================================================
// mac_accelerator.sv
// AZ1-Inspired Neural Edge SoC — MAC Accelerator (AXI-4 Lite Slave)
//
// What this module does:
//   Implements a Multiply-Accumulate engine accessible via AXI-4 Lite MMIO.
//   Software writes operands A and B, triggers a compute, reads back the result.
//
// Register Map (byte-addressed, 32-bit wide):
//   0x00  OPERAND_A   [31:0]  — input operand A (write-only from SW perspective)
//   0x04  OPERAND_B   [31:0]  — input operand B (write-only from SW perspective)
//   0x08  CTRL        [0]     — write 1 to start computation; auto-clears when done
//   0x0C  RESULT      [31:0]  — accumulated result (read-only from SW perspective)
//   0x10  STATUS      [0]     — 1 = done/idle, 0 = busy computing
//   0x14  ACC_CLEAR   [0]     — write 1 to reset the accumulator to 0
// =============================================================================

module mac_accelerator #(
    parameter DATA_WIDTH = 32,   // width of AXI data bus
    parameter ADDR_WIDTH = 6     // enough bits to address our register map
) (
    // ── Clock and Reset ──────────────────────────────────────────────────────
    // clk:  all state changes happen on the rising edge of this signal
    // rst_n: active-LOW reset. When rst_n=0, all registers return to reset values.
    //        Using active-low reset is the industry convention for ASICs.
    input  logic                    clk,
    input  logic                    rst_n,

    // ── AXI-4 Lite Write Address Channel ─────────────────────────────────────
    // The master sends the address it wants to write to.
    // Handshake: transfer occurs when BOTH awvalid AND awready are high.
    input  logic                    s_axi_awvalid,  // master: "I have a write address"
    output logic                    s_axi_awready,  // slave:  "I can accept it"
    input  logic [ADDR_WIDTH-1:0]   s_axi_awaddr,   // the actual address

    // ── AXI-4 Lite Write Data Channel ────────────────────────────────────────
    // The master sends the data to be written.
    input  logic                    s_axi_wvalid,   // master: "I have write data"
    output logic                    s_axi_wready,   // slave:  "I can accept it"
    input  logic [DATA_WIDTH-1:0]   s_axi_wdata,    // the 32-bit data word
    input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,    // byte-enable strobes (which bytes are valid)

    // ── AXI-4 Lite Write Response Channel ────────────────────────────────────
    // After accepting a write, the slave sends back an OK/ERROR response.
    output logic                    s_axi_bvalid,   // slave:  "I have a response"
    input  logic                    s_axi_bready,   // master: "I can accept it"
    output logic [1:0]              s_axi_bresp,    // 2'b00 = OKAY, 2'b10 = SLVERR

    // ── AXI-4 Lite Read Address Channel ──────────────────────────────────────
    input  logic                    s_axi_arvalid,  // master: "I have a read address"
    output logic                    s_axi_arready,  // slave:  "I can accept it"
    input  logic [ADDR_WIDTH-1:0]   s_axi_araddr,

    // ── AXI-4 Lite Read Data Channel ─────────────────────────────────────────
    output logic                    s_axi_rvalid,   // slave:  "I have read data"
    input  logic                    s_axi_rready,   // master: "I can accept it"
    output logic [DATA_WIDTH-1:0]   s_axi_rdata,
    output logic [1:0]              s_axi_rresp,

    // ── Interrupt ─────────────────────────────────────────────────────────────
    // Pulses HIGH for one clock cycle when a computation completes.
    // The interrupt controller will latch this and tell the CPU.
    output logic                    irq_done
);

// =============================================================================
// REGISTER FILE
// These are the actual flip-flops that hold the register values.
// Each is DATA_WIDTH (32) bits wide.
// =============================================================================
logic [DATA_WIDTH-1:0] reg_operand_a;   // holds operand A
logic [DATA_WIDTH-1:0] reg_operand_b;   // holds operand B
logic [DATA_WIDTH-1:0] reg_result;      // accumulates the MAC result
logic                  reg_ctrl_start;  // one-shot start trigger
logic                  reg_acc_clear;   // one-shot accumulator clear

// =============================================================================
// INTERNAL SIGNALS
// =============================================================================

// Write path: we need to capture both the address and data before acting.
// AXI-4 Lite allows AW and W channels to arrive in any order (or simultaneously).
// We latch whichever arrives first and wait for the other.
logic [ADDR_WIDTH-1:0] wr_addr_latch;   // captured write address
logic [DATA_WIDTH-1:0] wr_data_latch;   // captured write data
logic [DATA_WIDTH/8-1:0] wr_strb_latch;
logic                  aw_captured;     // flag: we have a write address
logic                  w_captured;      // flag: we have write data

// MAC computation state machine
// Two states: IDLE (waiting for start) and BUSY (computing)
typedef enum logic [1:0] {
    MAC_IDLE = 2'b00,   // waiting for ctrl_start
    MAC_BUSY = 2'b01,   // one-cycle multiply-accumulate in progress
    MAC_DONE = 2'b10    // result ready, pulse irq_done
} mac_state_t;

mac_state_t mac_state;

// The actual multiply result — 64 bits because 32×32 = 64-bit product.
// In a real design you'd pipeline this over multiple cycles. Here we keep
// it combinational for simplicity and to show the concept clearly.
logic [63:0] mac_product;
assign mac_product = reg_operand_a * reg_operand_b;  // combinational multiply

// Status bit: 1 when idle/done, 0 when busy
logic status_done;
assign status_done = (mac_state == MAC_IDLE || mac_state == MAC_DONE);

// =============================================================================
// AXI-4 LITE WRITE PATH
//
// Strategy: decouple AW and W channels using "captured" flags.
// Either channel can arrive first. We wait until both are captured,
// then perform the actual register write and send the B response.
// =============================================================================

// AW channel: accept address immediately when we don't already have one
assign s_axi_awready = ~aw_captured;

// W channel: accept data immediately when we don't already have one
assign s_axi_wready  = ~w_captured;

// Address and data capture registers
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        aw_captured   <= 1'b0;
        w_captured    <= 1'b0;
        wr_addr_latch <= '0;
        wr_data_latch <= '0;
        wr_strb_latch <= '0;
    end else begin
        // Capture write address when handshake completes on AW channel
        // Condition: awvalid=1 AND awready=1 (both sides agree to transfer)
        if (s_axi_awvalid && s_axi_awready) begin
            wr_addr_latch <= s_axi_awaddr;
            aw_captured   <= 1'b1;
        end

        // Capture write data when handshake completes on W channel
        if (s_axi_wvalid && s_axi_wready) begin
            wr_data_latch <= s_axi_wdata;
            wr_strb_latch <= s_axi_wstrb;
            w_captured    <= 1'b1;
        end

        // Once BOTH address and data are captured, perform the write.
        // Then clear the captured flags so we can accept the next transaction.
        // This 'if' block fires for exactly one clock cycle.
        if (aw_captured && w_captured) begin
            aw_captured <= 1'b0;
            w_captured  <= 1'b0;

            // Decode the address and write to the appropriate register.
            // The address is right-shifted by 2 because our registers are
            // 32-bit (4-byte) aligned. Address 0x04 >> 2 = offset 1, etc.
            case (wr_addr_latch[5:2])   // bits [5:2] = word address offset
                4'h0: reg_operand_a   <= wr_data_latch;  // 0x00: OPERAND_A
                4'h1: reg_operand_b   <= wr_data_latch;  // 0x04: OPERAND_B
                4'h2: reg_ctrl_start  <= wr_data_latch[0]; // 0x08: CTRL (only bit 0)
                4'h5: reg_acc_clear   <= wr_data_latch[0]; // 0x14: ACC_CLEAR
                // Writing to RESULT (0x0C) or STATUS (0x10) is ignored (read-only)
                default: ; // no-op for undefined addresses
            endcase
        end
    end
end

// Write response (B channel): fire one cycle after both AW+W are captured
// In a production design this would be a proper state machine with error detection.
// We send OKAY (2'b00) for valid addresses, SLVERR (2'b10) for invalid ones.
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s_axi_bvalid <= 1'b0;
        s_axi_bresp  <= 2'b00;
    end else begin
        if (aw_captured && w_captured && !s_axi_bvalid) begin
            s_axi_bvalid <= 1'b1;
            // Check if address is in our valid register map (0x00 to 0x14)
            s_axi_bresp  <= (wr_addr_latch <= 6'h14) ? 2'b00 : 2'b10;
        end else if (s_axi_bvalid && s_axi_bready) begin
            // Response accepted by master, de-assert
            s_axi_bvalid <= 1'b0;
        end
    end
end

// =============================================================================
// AXI-4 LITE READ PATH
//
// Simpler than write: AXI-4 Lite has only one read channel (AR).
// We accept the address, look up the register, and return data on R channel.
// =============================================================================

logic [ADDR_WIDTH-1:0] rd_addr_latch;
logic                  rd_pending;

assign s_axi_arready = ~rd_pending;  // always ready when not already processing a read

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_pending   <= 1'b0;
        rd_addr_latch <= '0;
        s_axi_rvalid <= 1'b0;
        s_axi_rdata  <= '0;
        s_axi_rresp  <= 2'b00;
    end else begin
        if (s_axi_arvalid && s_axi_arready) begin
            rd_addr_latch <= s_axi_araddr;
            rd_pending    <= 1'b1;
        end

        if (rd_pending && !s_axi_rvalid) begin
            rd_pending   <= 1'b0;
            s_axi_rvalid <= 1'b1;
            s_axi_rresp  <= 2'b00;  // OKAY

            // Mux the correct register onto the read data bus
            case (rd_addr_latch[5:2])
                4'h0: s_axi_rdata <= reg_operand_a;
                4'h1: s_axi_rdata <= reg_operand_b;
                4'h2: s_axi_rdata <= {31'b0, reg_ctrl_start};
                4'h3: s_axi_rdata <= reg_result;              // 0x0C: RESULT
                4'h4: s_axi_rdata <= {31'b0, status_done};   // 0x10: STATUS
                4'h5: s_axi_rdata <= {31'b0, reg_acc_clear};
                default: begin
                    s_axi_rdata <= 32'hDEAD_BEEF;  // sentinel for invalid address
                    s_axi_rresp <= 2'b10;           // SLVERR
                end
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
end

// =============================================================================
// MAC STATE MACHINE
//
// This is the heart of the accelerator. Three states:
//   IDLE: waiting for software to write 1 to CTRL register
//   BUSY: performing the multiply-accumulate (one cycle in our simple design)
//   DONE: result is valid, interrupt fires, waits for next command
// =============================================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mac_state    <= MAC_IDLE;
        reg_result   <= '0;
        reg_ctrl_start <= 1'b0;
        reg_acc_clear  <= 1'b0;
        irq_done     <= 1'b0;
        reg_operand_a <= '0;
        reg_operand_b <= '0;
    end else begin
        irq_done <= 1'b0;  // default: interrupt is a single-cycle pulse

        // Handle accumulator clear request
        // This runs every cycle, independent of the state machine
        if (reg_acc_clear) begin
            reg_result   <= '0;
            reg_acc_clear <= 1'b0;  // auto-clear the trigger bit
        end

        case (mac_state)
            MAC_IDLE: begin
                if (reg_ctrl_start) begin
                    reg_ctrl_start <= 1'b0;  // auto-clear the start bit
                    mac_state      <= MAC_BUSY;
                end
            end

            MAC_BUSY: begin
                // Perform the accumulate: result += A × B
                // mac_product is computed combinationally above.
                // We take only the lower 32 bits. A real design would
                // handle overflow and saturation here.
                reg_result <= reg_result + mac_product[31:0];
                mac_state  <= MAC_DONE;
            end

            MAC_DONE: begin
                irq_done  <= 1'b1;  // one-cycle interrupt pulse
                mac_state <= MAC_IDLE;
            end

            default: mac_state <= MAC_IDLE;
        endcase
    end
end

// =============================================================================
// ASSERTIONS (SVA)
// These are properties that MUST always hold. The simulator checks them
// every cycle and flags a violation if they're ever false.
// In a real UVM environment, these catch bugs that testbenches miss.
// =============================================================================

// Property 1: irq_done must only be a single-cycle pulse
// "if irq_done is high, it must be low on the next cycle"
property irq_single_pulse;
    @(posedge clk) irq_done |=> !irq_done;
endproperty
assert property (irq_single_pulse)
    else $error("ASSERTION FAIL: irq_done held high for more than one cycle");

// Property 2: RESULT register only changes when in BUSY→DONE transition
// (This would be a more complex assume/assert pair in a full formal flow)

// Property 3: AXI VALID must not de-assert once raised (until handshake)
property axi_awvalid_stable;
    @(posedge clk) disable iff (!rst_n)
    (s_axi_awvalid && !s_axi_awready) |=> s_axi_awvalid;
endproperty
assert property (axi_awvalid_stable)
    else $error("ASSERTION FAIL: s_axi_awvalid de-asserted before handshake");

// Coverage: ensure all registers get written (for verification completeness)
covergroup mac_reg_access_cg @(posedge clk);
    cp_wr_addr: coverpoint wr_addr_latch[5:2] iff (aw_captured && w_captured) {
        bins operand_a  = {4'h0};
        bins operand_b  = {4'h1};
        bins ctrl       = {4'h2};
        bins acc_clear  = {4'h5};
        bins illegal    = default;
    }
    cp_rd_addr: coverpoint rd_addr_latch[5:2] iff (rd_pending) {
        bins result     = {4'h3};
        bins status     = {4'h4};
    }
endgroup
mac_reg_access_cg mac_cov = new();

endmodule
