/* =============================================================================
 * firmware/link.ld — Linker Script for Neural Edge SoC Bare-Metal Firmware
 *
 * The linker script tells the toolchain WHERE in memory to place each section
 * of the compiled binary. This is essential for bare-metal — there's no OS
 * to handle memory layout.
 *
 * Memory Map:
 *   0x8000_0000  ROM/Flash — code (.text) and read-only data (.rodata) live here
 *   0x2000_0000  SRAM      — stack and writable data (.data, .bss) live here
 *
 * In simulation, the UVM testbench's memory model maps these same addresses.
 * ============================================================================= */

ENTRY(_start)

MEMORY {
    ROM  (rx)  : ORIGIN = 0x80000000, LENGTH = 64K   /* instruction memory */
    SRAM (rwx) : ORIGIN = 0x20000000, LENGTH = 32K   /* data memory        */
}

SECTIONS {
    /* .text: compiled machine code */
    .text : {
        *(.text.start)   /* _start must be first */
        *(.text*)
        *(.rodata*)
    } > ROM

    /* .data: initialized global/static variables
     * LMA (Load Memory Address) = ROM (stored in flash)
     * VMA (Virtual Memory Address) = SRAM (where CPU reads it at runtime)
     * The startup code (_start) copies .data from ROM to SRAM at boot. */
    .data : {
        _data_start = .;
        *(.data*)
        _data_end = .;
    } > SRAM AT > ROM

    /* .bss: zero-initialized globals. Startup code zero-fills this region. */
    .bss : {
        _bss_start = .;
        *(.bss*)
        *(COMMON)
        _bss_end = .;
    } > SRAM

    /* Stack grows downward from top of SRAM */
    _stack_top = ORIGIN(SRAM) + LENGTH(SRAM);
}
