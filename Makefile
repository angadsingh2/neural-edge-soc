# =============================================================================
# Makefile — Neural Edge SoC Simulation & Firmware Build
#
# Usage:
#   make sim          — run default test (mac_dot_product_test) with Icarus
#   make sim TEST=rand_stress_test   — run a specific test
#   make compile      — compile only, don't run
#   make waves        — open GTKWave with last simulation's waveforms
#   make fw           — compile bare-metal firmware (needs RISC-V toolchain)
#   make clean        — remove all generated files
#   make all          — compile + run all tests
# =============================================================================

# ── Directories ──────────────────────────────────────────────────────────────
RTL_DIR   := rtl
TB_DIR    := tb
UVM_DIR   := uvm
FW_DIR    := firmware
WAVE_DIR  := waves
SIM_DIR   := sim_out

# ── Tool selection (change to vcs/questa for production) ─────────────────────
# Icarus Verilog is free and open-source — perfect for GitHub demos
SIMULATOR := iverilog
SIMRUN    := vvp

# ── Default test ─────────────────────────────────────────────────────────────
TEST ?= mac_dot_product_test

# ── UVM library path (set UVM_HOME in your environment) ──────────────────────
# For Icarus with open-source UVM:  export UVM_HOME=/path/to/uvm-1.2
UVM_HOME  ?= $(HOME)/uvm-1.2
UVM_INC   := -I$(UVM_HOME)/src $(UVM_HOME)/src/uvm_pkg.sv

# ── Source file lists ─────────────────────────────────────────────────────────
RTL_SRCS  := $(RTL_DIR)/mac_accelerator.sv   \
             $(RTL_DIR)/uart_peripheral.sv    \
             $(RTL_DIR)/gpio_peripheral.sv    \
             $(RTL_DIR)/neural_edge_soc.sv

UVM_SRCS  := $(UVM_DIR)/axi4_transaction.sv  \
             $(UVM_DIR)/axi4_driver.sv        \
             $(UVM_DIR)/axi4_monitor.sv       \
             $(UVM_DIR)/scoreboard.sv         \
             $(UVM_DIR)/coverage_collector.sv \
             $(UVM_DIR)/axi4_agent.sv         \
             $(UVM_DIR)/neural_edge_env.sv    \
             $(UVM_DIR)/sequences/base_sequence.sv       \
             $(UVM_DIR)/sequences/mac_single_op_seq.sv   \
             $(UVM_DIR)/sequences/remaining_sequences.sv \
             $(UVM_DIR)/neural_edge_pkg.sv

TB_SRCS   := $(TB_DIR)/neural_edge_if.sv     \
             $(TB_DIR)/tests/neural_edge_tests.sv \
             $(TB_DIR)/tb_top.sv

ALL_SRCS  := $(UVM_INC) $(RTL_SRCS) $(UVM_SRCS) $(TB_SRCS)

# ── Compiler flags ────────────────────────────────────────────────────────────
IFLAGS    := -g2012                      \
             -I$(UVM_DIR)                \
             -I$(UVM_DIR)/sequences      \
             -I$(TB_DIR)                 \
             -I$(TB_DIR)/tests           \
             -DUVM_NO_DEPRECATED         \
             -o $(SIM_DIR)/sim.vvp

SIMFLAGS  := +UVM_TESTNAME=$(TEST)       \
             +UVM_VERBOSITY=UVM_MEDIUM   \
             -lxt2

# ── RISC-V Toolchain (for firmware) ──────────────────────────────────────────
RISCV_GCC := riscv32-unknown-elf-gcc
RISCV_OBJCOPY := riscv32-unknown-elf-objcopy
RISCV_FLAGS := -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
               -T $(FW_DIR)/link.ld -O2

# ─────────────────────────────────────────────────────────────────────────────

.PHONY: all compile sim waves fw clean help dirs

all: dirs compile sim

# Create output directories
dirs:
	@mkdir -p $(SIM_DIR) $(WAVE_DIR)

# Compile the simulation
compile: dirs
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Compiling Neural Edge SoC Testbench..."
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	$(SIMULATOR) $(IFLAGS) $(ALL_SRCS)
	@echo "  Compilation DONE → $(SIM_DIR)/sim.vvp"

# Run simulation
sim: compile
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Running test: $(TEST)"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	$(SIMRUN) $(SIM_DIR)/sim.vvp $(SIMFLAGS) | tee $(SIM_DIR)/$(TEST).log
	@echo ""
	@echo "  Log saved → $(SIM_DIR)/$(TEST).log"
	@grep -E "PASS|FAIL|ERROR|UVM_ERROR|UVM_FATAL" $(SIM_DIR)/$(TEST).log | tail -20 || true

# Run ALL tests sequentially
sim_all: compile
	@for test in mac_sanity_test mac_dot_product_test uart_bringup_test gpio_test soc_boot_test rand_stress_test; do \
	    echo ""; \
	    echo "━━ Running: $$test ━━"; \
	    $(SIMRUN) $(SIM_DIR)/sim.vvp +UVM_TESTNAME=$$test +UVM_VERBOSITY=UVM_MEDIUM 2>&1 | tee $(SIM_DIR)/$$test.log; \
	    if grep -q "UVM_FATAL\|UVM_ERROR" $(SIM_DIR)/$$test.log; then \
	        echo "  ✗ FAIL: $$test"; \
	    else \
	        echo "  ✓ PASS: $$test"; \
	    fi; \
	done

# Open GTKWave
waves:
	@if [ -f $(WAVE_DIR)/neural_edge_tb.vcd ]; then \
	    gtkwave $(WAVE_DIR)/neural_edge_tb.vcd & \
	else \
	    echo "No waveform found. Run 'make sim' first."; \
	fi

# Compile bare-metal firmware
fw:
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Compiling Bare-Metal Firmware..."
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	$(RISCV_GCC) $(RISCV_FLAGS) \
	    $(FW_DIR)/start.S $(FW_DIR)/main.c \
	    -o $(FW_DIR)/firmware.elf
	$(RISCV_OBJCOPY) -O binary $(FW_DIR)/firmware.elf $(FW_DIR)/firmware.bin
	$(RISCV_OBJCOPY) -O verilog $(FW_DIR)/firmware.elf $(FW_DIR)/boot_rom.mem
	@echo "  Firmware built:"
	@echo "    ELF  → $(FW_DIR)/firmware.elf"
	@echo "    BIN  → $(FW_DIR)/firmware.bin"
	@echo "    MEM  → $(FW_DIR)/boot_rom.mem  (load into simulator)"

# Clean everything
clean:
	@rm -rf $(SIM_DIR) $(WAVE_DIR)/*.vcd $(FW_DIR)/firmware.elf \
	        $(FW_DIR)/firmware.bin $(FW_DIR)/boot_rom.mem
	@echo "  Cleaned."

help:
	@echo ""
	@echo "  Neural Edge SoC — Make Targets"
	@echo "  ───────────────────────────────────────────"
	@echo "  make sim                     Run default test (mac_dot_product_test)"
	@echo "  make sim TEST=<name>         Run a specific test"
	@echo "  make sim_all                 Run all 6 tests"
	@echo "  make waves                   Open GTKWave"
	@echo "  make fw                      Build RISC-V firmware"
	@echo "  make clean                   Remove generated files"
	@echo ""
	@echo "  Available tests:"
	@echo "    mac_sanity_test"
	@echo "    mac_dot_product_test"
	@echo "    uart_bringup_test"
	@echo "    gpio_test"
	@echo "    soc_boot_test"
	@echo "    rand_stress_test"
	@echo ""
