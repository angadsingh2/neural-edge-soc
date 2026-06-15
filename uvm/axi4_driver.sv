// =============================================================================
// uvm/axi4_driver.sv
// AXI-4 Lite UVM Driver
//
// The driver is the bridge between the abstract world (transactions/objects)
// and the physical world (actual signal wiggles on wires).
//
// Lifecycle:
//   1. get_next_item() — pull the next transaction from the sequencer
//   2. Drive AXI signals cycle-by-cycle to implement the transaction
//   3. item_done()     — tell sequencer we're ready for the next item
//
// The driver is the component that would map to a "transactor" in an
// emulation environment (Zebu/HAPs). Same concept, different platform.
// =============================================================================

class axi4_driver extends uvm_driver #(axi4_transaction);
    `uvm_component_utils(axi4_driver)

    // Virtual interface handle — connects to the actual DUT signals
    // This is set by the environment via uvm_config_db
    virtual neural_edge_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // build_phase: get the virtual interface from the config database
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual neural_edge_if)::get(this, "", "vif", vif))
            `uvm_fatal("CFG", "Driver: virtual interface not found in config_db")
    endfunction

    // run_phase: main execution loop — runs forever during simulation
    task run_phase(uvm_phase phase);
        axi4_transaction txn;

        // Initialize all master outputs to safe idle state
        drive_idle();

        // Wait for reset to deassert
        @(posedge vif.rst_n);
        repeat(2) @(posedge vif.clk);

        forever begin
            // Step 1: Request next transaction from sequencer
            seq_item_port.get_next_item(txn);

            `uvm_info("DRV", $sformatf("Driving: %s", txn.convert2string()), UVM_MEDIUM)

            // Step 2: Drive the transaction onto AXI signals
            if (txn.op == axi4_transaction::AXI_WRITE)
                drive_write(txn);
            else
                drive_read(txn);

            // Step 3: Signal completion to sequencer
            seq_item_port.item_done();
        end
    endtask

    // ── Drive all AXI master outputs to idle (safe) state ─────────────────
    task drive_idle();
        vif.m_axi_awvalid <= 0;
        vif.m_axi_awaddr  <= '0;
        vif.m_axi_wvalid  <= 0;
        vif.m_axi_wdata   <= '0;
        vif.m_axi_wstrb   <= '0;
        vif.m_axi_bready  <= 1;   // master always ready to accept responses
        vif.m_axi_arvalid <= 0;
        vif.m_axi_araddr  <= '0;
        vif.m_axi_rready  <= 1;   // master always ready to accept read data
    endtask

    // ── Drive an AXI-4 Lite Write Transaction ─────────────────────────────
    // AXI allows AW and W channels to be driven simultaneously (or in either
    // order). We drive them together for simplicity — this is legal per spec.
    task drive_write(axi4_transaction txn);
        // Phase 1: Assert AW and W channels simultaneously
        @(posedge vif.clk);
        vif.m_axi_awvalid <= 1;
        vif.m_axi_awaddr  <= txn.addr;
        vif.m_axi_wvalid  <= 1;
        vif.m_axi_wdata   <= txn.data;
        vif.m_axi_wstrb   <= txn.wstrb;

        // Phase 2: Wait for both AW and W handshakes
        // AXI rule: once VALID is asserted, it must stay asserted until
        // READY is seen. This is the VALID-stable rule (tested by our SVA).
        fork
            // Wait for AW handshake
            begin
                wait(vif.m_axi_awready);
                @(posedge vif.clk);
                vif.m_axi_awvalid <= 0;
            end
            // Wait for W handshake
            begin
                wait(vif.m_axi_wready);
                @(posedge vif.clk);
                vif.m_axi_wvalid <= 0;
                vif.m_axi_wstrb  <= '0;
            end
        join

        // Phase 3: Wait for B (response) channel
        // The slave will assert bvalid. We keep bready=1 to accept immediately.
        wait(vif.m_axi_bvalid);
        txn.bresp = vif.m_axi_bresp;
        @(posedge vif.clk);

        if (txn.bresp != 2'b00)
            `uvm_warning("DRV", $sformatf("Write to 0x%08X got non-OKAY response: %02b",
                                           txn.addr, txn.bresp))
    endtask

    // ── Drive an AXI-4 Lite Read Transaction ──────────────────────────────
    task drive_read(axi4_transaction txn);
        // Phase 1: Assert AR channel
        @(posedge vif.clk);
        vif.m_axi_arvalid <= 1;
        vif.m_axi_araddr  <= txn.addr;

        // Phase 2: Wait for AR handshake
        wait(vif.m_axi_arready);
        @(posedge vif.clk);
        vif.m_axi_arvalid <= 0;

        // Phase 3: Wait for R channel (slave returns data)
        wait(vif.m_axi_rvalid);
        txn.data  = vif.m_axi_rdata;
        txn.rresp = vif.m_axi_rresp;
        @(posedge vif.clk);

        `uvm_info("DRV", $sformatf("Read 0x%08X from addr 0x%08X",
                                    txn.data, txn.addr), UVM_HIGH)
    endtask

endclass
