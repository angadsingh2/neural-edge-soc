/* =============================================================================
 * firmware/start.S — RISC-V Bare-Metal Startup Code
 *
 * This is the VERY FIRST code that runs when the chip comes out of reset.
 * Before main() can run, we need to:
 *   1. Set the stack pointer (C needs a stack to call functions)
 *   2. Zero the .bss section (C standard requires zero-initialized globals)
 *   3. Copy .data from ROM to SRAM (initialized globals)
 *   4. Jump to main()
 *
 * On real silicon, this runs before any other code. During emulation,
 * the UVM testbench releases reset and this code is the first thing
 * the instruction fetch unit reads from memory.
 * ============================================================================= */

.section .text.start
.global _start

_start:
    /* ── 1. Set stack pointer to top of SRAM ───────────────────────────── */
    la   sp, _stack_top          /* load address of stack top into sp */

    /* ── 2. Zero the .bss section ──────────────────────────────────────── */
    la   t0, _bss_start
    la   t1, _bss_end
bss_loop:
    bge  t0, t1, bss_done        /* if t0 >= t1, we're done */
    sw   zero, 0(t0)             /* store 0 at address t0 */
    addi t0, t0, 4               /* advance by 4 bytes (one word) */
    j    bss_loop
bss_done:

    /* ── 3. Copy .data from ROM (LMA) to SRAM (VMA) ───────────────────── */
    /* (Simplified: in this simulation model .data is already in SRAM) */

    /* ── 4. Call main() ─────────────────────────────────────────────────── */
    call main

    /* ── 5. Infinite loop if main() returns (should never happen) ───────── */
    /* In a real SoC this would trigger a watchdog reset */
halt:
    j halt
