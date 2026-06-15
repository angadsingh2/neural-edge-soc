// =============================================================================
// uvm/axi4_monitor.sv
// AXI-4 Lite UVM Monitor
//
// The monitor is PASSIVE — it only observes, never drives signals.
// It watches the AXI bus and reconstructs transactions from what it sees.
//
// Why monitors matter:
//   - Drivers know what they SENT. Monitors know what the DUT ACTUALLY DID.
//   - The scoreboard compares both sides to find bugs.
//   - In emulation (Zebu/HAPs), monitors are the primary debug tool.
//
// The monitor broadcasts observed transactions via an analysis port.
// Any subscriber (scoreboard, coverage collector, logger) receives them.
// This is the UVM "publish-subscribe" pattern.
// =============================================================================

class axi4_monitor extends uvm_monitor;
    `uvm_component_utils(axi4_monitor)

    // Analysis port: broadcast observed transactions to all subscribers
    // Any component that calls ap.write(txn) sends to ALL connected subscribers
    uvm_analysis_port #(axi4_transaction) ap;

    virtual neural_edge_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db #(virtual neural_edge_if)::get(this, "", "vif", vif))
            `uvm_fatal("CFG", "Monitor: virtual interface not found")
    endfunction

    // run_phase: spawn parallel processes to monitor all AXI channels
    task run_phase(uvm_phase phase);
        // Run write and read monitors in parallel, forever
        fork
            monitor_writes();
            monitor_reads();
            monitor_interrupts();
        join_none  // non-blocking fork: all three run simultaneously
    endtask

    // ── Monitor Write Channel (AW + W + B) ────────────────────────────────
    task monitor_writes();
        axi4_transaction txn;
        forever begin
            // Wait for a write address handshake
            @(posedge vif.clk);
            if (vif.m_axi_awvalid && vif.m_axi_awready) begin
                txn = axi4_transaction::type_id::create("mon_wr_txn");
                txn.op   = axi4_transaction::AXI_WRITE;
                txn.addr = vif.m_axi_awaddr;

                // Now wait for write data handshake
                // (may already be valid if AW and W were simultaneous)
                while (!(vif.m_axi_wvalid && vif.m_axi_wready))
                    @(posedge vif.clk);
                txn.data  = vif.m_axi_wdata;
                txn.wstrb = vif.m_axi_wstrb;

                // Wait for write response
                while (!(vif.m_axi_bvalid && vif.m_axi_bready))
                    @(posedge vif.clk);
                txn.bresp = vif.m_axi_bresp;

                `uvm_info("MON", $sformatf("Observed: %s", txn.convert2string()), UVM_HIGH)
                ap.write(txn);  // broadcast to scoreboard and coverage
            end
        end
    endtask

    // ── Monitor Read Channel (AR + R) ─────────────────────────────────────
    task monitor_reads();
        axi4_transaction txn;
        forever begin
            @(posedge vif.clk);
            if (vif.m_axi_arvalid && vif.m_axi_arready) begin
                txn = axi4_transaction::type_id::create("mon_rd_txn");
                txn.op   = axi4_transaction::AXI_READ;
                txn.addr = vif.m_axi_araddr;

                // Wait for read data
                while (!(vif.m_axi_rvalid && vif.m_axi_rready))
                    @(posedge vif.clk);
                txn.data  = vif.m_axi_rdata;
                txn.rresp = vif.m_axi_rresp;

                `uvm_info("MON", $sformatf("Observed: %s", txn.convert2string()), UVM_HIGH)
                ap.write(txn);
            end
        end
    endtask

    // ── Monitor Interrupts ────────────────────────────────────────────────
    task monitor_interrupts();
        forever begin
            @(posedge vif.clk);
            if (vif.irq_to_cpu) begin
                `uvm_info("MON", "IRQ asserted to CPU", UVM_MEDIUM)
            end
        end
    endtask

endclass
