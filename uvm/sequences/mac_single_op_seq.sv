// =============================================================================
// sequences/mac_single_op_seq.sv — one MAC compute operation
// =============================================================================
class mac_single_op_seq extends base_sequence;
    `uvm_object_utils(mac_single_op_seq)

    // Randomizable operands — caller can constrain or set these
    rand logic [31:0] operand_a;
    rand logic [31:0] operand_b;
    logic [31:0]      result;

    function new(string name = "mac_single_op_seq");
        super.new(name);
    endfunction

    task body();
        `uvm_info("SEQ", $sformatf("MAC: %0d * %0d", operand_a, operand_b), UVM_MEDIUM)

        // Write operands
        axi_write(32'h0000_0000, operand_a);   // OPERAND_A
        axi_write(32'h0000_0004, operand_b);   // OPERAND_B

        // Trigger computation
        axi_write(32'h0000_0008, 32'h1);       // CTRL = 1 (start)

        // Poll STATUS until DONE
        poll_until_set(32'h0000_0010, 32'h1);  // STATUS bit 0

        // Read result
        axi_read(32'h0000_000C, result);
        `uvm_info("SEQ", $sformatf("MAC result = %0d (0x%08X)", result, result), UVM_MEDIUM)
    endtask

endclass

// =============================================================================
// sequences/mac_dot_product_seq.sv — full dot product (N MAC operations)
// Mirrors what the bare-metal firmware does: compute A·B across a vector
// =============================================================================
class mac_dot_product_seq extends base_sequence;
    `uvm_object_utils(mac_dot_product_seq)

    // Test vectors — same values as the C firmware
    logic [31:0] vec_a[] = '{1, 2, 3, 4};
    logic [31:0] vec_b[] = '{5, 6, 7, 8};
    int          n_elements = 4;
    logic [31:0] result;

    function new(string name = "mac_dot_product_seq");
        super.new(name);
    endfunction

    task body();
        // Clear accumulator first
        axi_write(32'h0000_0014, 32'h1);       // ACC_CLEAR = 1
        #10;

        for (int i = 0; i < n_elements; i++) begin
            mac_single_op_seq mac_seq = mac_single_op_seq::type_id::create("mac_seq");
            mac_seq.operand_a = vec_a[i];
            mac_seq.operand_b = vec_b[i];
            mac_seq.start(m_sequencer);
        end

        // Read final accumulated result
        axi_read(32'h0000_000C, result);
        `uvm_info("SEQ", $sformatf("Dot product result = %0d (expected 70)", result), UVM_NONE)

        if (result !== 32'd70)
            `uvm_error("SEQ", "Dot product FAILED: expected 70")
        else
            `uvm_info("SEQ", "Dot product PASSED", UVM_NONE)
    endtask

endclass
