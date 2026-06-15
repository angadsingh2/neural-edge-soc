// =============================================================================
// uvm/neural_edge_env.sv
// Top-Level UVM Environment
//
// The environment is the container for ALL verification components.
// Think of it as the "verification SoC" that mirrors the design SoC.
//
// Hierarchy:
//   neural_edge_env
//     ├── axi4_agent  (stimulus generation + observation)
//     ├── scoreboard  (checks correctness)
//     └── coverage_collector (measures completeness)
//
// The env's connect_phase wires all the TLM ports together —
// agent's analysis port → scoreboard's analysis export
//                       → coverage's analysis export
// =============================================================================

class neural_edge_env extends uvm_env;
    `uvm_component_utils(neural_edge_env)

    axi4_agent          agent;
    scoreboard          scb;
    coverage_collector  cov;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent = axi4_agent::type_id::create("agent", this);
        scb   = scoreboard::type_id::create("scb", this);
        cov   = coverage_collector::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        // One monitor feeds both the scoreboard and coverage collector
        // This is the UVM broadcast pattern
        agent.ap.connect(scb.analysis_export);
        agent.ap.connect(cov.analysis_export);
    endfunction

endclass
