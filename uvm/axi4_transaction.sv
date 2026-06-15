// =============================================================================
// uvm/axi4_transaction.sv
// AXI-4 Lite Transaction — the fundamental data object in our UVM env
//
// In UVM, a "transaction" (also called a "sequence item") represents one
// logical operation on the bus — one read or one write.
// The driver converts this object into actual signal toggles.
// The monitor observes signal toggles and reconstructs this object.
// The scoreboard receives objects from the monitor and checks them.
//
// Think of it like a postal package:
//   - Sequence creates the package (fills in address and contents)
//   - Driver mails it (drives AXI signals)
//   - Monitor receives the package (captures what appeared on the bus)
//   - Scoreboard checks the contents match what was expected
// =============================================================================

class axi4_transaction extends uvm_sequence_item;

    // Register this class with the UVM factory.
    // This macro generates a type_id and enables factory overrides.
    `uvm_object_utils_begin(axi4_transaction)
        `uvm_field_enum  (axi_op_e, op,      UVM_ALL_ON)
        `uvm_field_int   (addr,               UVM_ALL_ON | UVM_HEX)
        `uvm_field_int   (data,               UVM_ALL_ON | UVM_HEX)
        `uvm_field_int   (wstrb,              UVM_ALL_ON)
        `uvm_field_int   (bresp,              UVM_ALL_ON)
        `uvm_field_int   (rresp,              UVM_ALL_ON)
    `uvm_object_utils_end

    // ── Transaction Type ──────────────────────────────────────────────────
    typedef enum logic { AXI_WRITE = 1'b0, AXI_READ = 1'b1 } axi_op_e;

    // ── Randomizable Fields ───────────────────────────────────────────────
    // Marking fields 'rand' allows the UVM constraint solver to generate
    // legal random values. Constraints narrow down the random space.

    rand axi_op_e  op;           // READ or WRITE
    rand logic [31:0] addr;      // target address
    rand logic [31:0] data;      // write data (or readback value)
    rand logic [3:0]  wstrb;     // byte enables (which of 4 bytes to write)

    // Response fields — set by monitor, not randomized
    logic [1:0] bresp;           // write response (OKAY=00, SLVERR=10)
    logic [1:0] rresp;           // read response

    // ── Constraints ───────────────────────────────────────────────────────
    // Constraints define what "legal" random values look like.
    // Without constraints, random addr would hit unmapped regions constantly.

    // Only generate addresses within our SoC's defined slave regions
    constraint c_valid_addr {
        addr inside {
            [32'h0000_0000 : 32'h0000_003F],   // MAC accelerator
            [32'h0000_0100 : 32'h0000_011F],   // UART
            [32'h0000_0200 : 32'h0000_020F]    // GPIO
        };
    }

    // Addresses must be 4-byte aligned (AXI-4 Lite requirement)
    constraint c_addr_align {
        addr[1:0] == 2'b00;
    }

    // Write strobe: at least one byte must be enabled
    constraint c_wstrb_valid {
        op == AXI_WRITE -> wstrb != 4'b0000;
    }

    // Bias towards writes slightly more than reads for better coverage
    constraint c_op_dist {
        op dist { AXI_WRITE := 60, AXI_READ := 40 };
    }

    // ── Constructor ───────────────────────────────────────────────────────
    function new(string name = "axi4_transaction");
        super.new(name);
    endfunction

    // ── do_copy: deep copy for cloning ───────────────────────────────────
    function void do_copy(uvm_object rhs);
        axi4_transaction rhs_;
        super.do_copy(rhs);
        $cast(rhs_, rhs);
        op    = rhs_.op;
        addr  = rhs_.addr;
        data  = rhs_.data;
        wstrb = rhs_.wstrb;
        bresp = rhs_.bresp;
        rresp = rhs_.rresp;
    endfunction

    // ── convert2string: human-readable printing ───────────────────────────
    // Called by `uvm_info when logging transactions
    function string convert2string();
        return $sformatf("[AXI4 %s] addr=0x%08X data=0x%08X wstrb=4'b%04b resp=%02b",
                         op.name(), addr, data, wstrb,
                         (op == AXI_WRITE) ? bresp : rresp);
    endfunction

endclass
