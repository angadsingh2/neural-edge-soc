// =============================================================================
// uvm/sequences/base_sequence.sv
// Base Sequence — convenience wrapper all other sequences extend
// =============================================================================

class base_sequence extends uvm_sequence #(axi4_transaction);
    `uvm_object_utils(base_sequence)

    function new(string name = "base_sequence");
        super.new(name);
    endfunction

    // Helper: write a value to an AXI address
    task axi_write(input logic [31:0] addr, input logic [31:0] data,
                   input logic [3:0] wstrb = 4'hF);
        axi4_transaction txn = axi4_transaction::type_id::create("wr_txn");
        start_item(txn);
        txn.op    = axi4_transaction::AXI_WRITE;
        txn.addr  = addr;
        txn.data  = data;
        txn.wstrb = wstrb;
        finish_item(txn);
    endtask

    // Helper: read from an AXI address, return the data
    task axi_read(input logic [31:0] addr, output logic [31:0] data);
        axi4_transaction txn = axi4_transaction::type_id::create("rd_txn");
        start_item(txn);
        txn.op   = axi4_transaction::AXI_READ;
        txn.addr = addr;
        finish_item(txn);
        data = txn.data;
    endtask

    // Helper: poll a register until a bit is set (with timeout)
    task poll_until_set(input logic [31:0] addr, input logic [31:0] mask,
                        input int timeout_cycles = 1000);
        logic [31:0] rdata;
        int count = 0;
        do begin
            axi_read(addr, rdata);
            count++;
            if (count > timeout_cycles) begin
                `uvm_error("SEQ", $sformatf("Timeout waiting for mask 0x%08X at 0x%08X",
                                             mask, addr))
                return;
            end
        end while ((rdata & mask) == '0);
    endtask

endclass
