// =============================================================================
// uvm/axi4_agent.sv
// UVM Agent — bundles Driver + Monitor + Sequencer into one reusable unit
//
// An agent is the standard UVM packaging for one interface's worth of VIP
// (Verification IP). It can run in two modes:
//   ACTIVE:  has a driver + sequencer (generates stimulus)
//   PASSIVE: monitor only (just observes, used for output checking)
//
// We use ACTIVE mode since we're driving the master AXI port.
// =============================================================================

class axi4_agent extends uvm_agent;
    `uvm_component_utils(axi4_agent)

    // Child components — created in build_phase
    axi4_driver                      driver;
    axi4_monitor                     monitor;
    uvm_sequencer #(axi4_transaction) sequencer;

    // Analysis port passthrough — lets the env connect to monitor's output
    uvm_analysis_port #(axi4_transaction) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap        = new("ap", this);
        monitor   = axi4_monitor::type_id::create("monitor", this);
        if (get_is_active() == UVM_ACTIVE) begin
            driver    = axi4_driver::type_id::create("driver", this);
            sequencer = uvm_sequencer #(axi4_transaction)::type_id::create("sequencer", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        // Connect driver to sequencer (TLM port)
        if (get_is_active() == UVM_ACTIVE)
            driver.seq_item_port.connect(sequencer.seq_item_export);
        // Expose monitor's analysis port through the agent
        monitor.ap.connect(ap);
    endfunction

endclass
