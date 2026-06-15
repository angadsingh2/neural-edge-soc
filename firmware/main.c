/* =============================================================================
 * firmware/main.c
 * AZ1-Inspired Neural Edge SoC — Bare-Metal Boot Firmware
 *
 * This is the C code that runs ON the SoC with NO operating system.
 * It demonstrates the full SoC bring-up sequence:
 *   1. Initialize UART (so we can print debug messages)
 *   2. Print a boot banner over UART
 *   3. Configure and exercise the MAC accelerator via MMIO
 *   4. Toggle GPIO to signal test status (like a real bring-up engineer would)
 *   5. Loop running a neural-network-style dot product using the MAC
 *
 * In simulation, the UVM testbench loads this binary, starts the clock,
 * and monitors the AXI bus — exactly like an emulation platform (Zebu/HAPs).
 * ============================================================================= */

#include <stdint.h>
#include <stddef.h>

/* ── SoC Memory Map ────────────────────────────────────────────────────────── */
#define MAC_BASE    0x00000000UL
#define UART_BASE   0x00000100UL
#define GPIO_BASE   0x00000200UL

/* ── MAC Accelerator Register Offsets ─────────────────────────────────────── */
#define MAC_OPERAND_A   (*(volatile uint32_t *)(MAC_BASE + 0x00))
#define MAC_OPERAND_B   (*(volatile uint32_t *)(MAC_BASE + 0x04))
#define MAC_CTRL        (*(volatile uint32_t *)(MAC_BASE + 0x08))
#define MAC_RESULT      (*(volatile uint32_t *)(MAC_BASE + 0x0C))
#define MAC_STATUS      (*(volatile uint32_t *)(MAC_BASE + 0x10))
#define MAC_ACC_CLEAR   (*(volatile uint32_t *)(MAC_BASE + 0x14))

/* ── UART Register Offsets ─────────────────────────────────────────────────── */
#define UART_TX_DATA    (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UART_STATUS     (*(volatile uint32_t *)(UART_BASE + 0x04))
#define UART_BAUD_DIV   (*(volatile uint32_t *)(UART_BASE + 0x08))
#define UART_RX_DATA    (*(volatile uint32_t *)(UART_BASE + 0x0C))

/* ── GPIO Register Offsets ─────────────────────────────────────────────────── */
#define GPIO_DATA_OUT   (*(volatile uint32_t *)(GPIO_BASE + 0x00))
#define GPIO_DIR        (*(volatile uint32_t *)(GPIO_BASE + 0x04))
#define GPIO_DATA_IN    (*(volatile uint32_t *)(GPIO_BASE + 0x08))

/* ── Status register bit fields ────────────────────────────────────────────── */
#define MAC_STATUS_DONE     (1u << 0)
#define UART_STATUS_TX_BUSY (1u << 0)
#define UART_STATUS_RX_VALID (1u << 1)

/* ── GPIO pin assignments (like a real board bring-up) ─────────────────────── */
#define GPIO_PIN_BOOT_OK    (1u << 0)   /* LED: boot completed */
#define GPIO_PIN_MAC_ACTIVE (1u << 1)   /* LED: MAC computing  */
#define GPIO_PIN_ERROR      (1u << 7)   /* LED: error flag     */

/* ============================================================================
 * UART Driver
 * ============================================================================ */

/* uart_init: configure baud rate
 * For 50MHz clk and 115200 baud: divider = 50_000_000/115200 - 1 = 433
 * The hardware uses: baud_rate = clk_freq / (divider + 1) */
void uart_init(uint32_t baud_div) {
    UART_BAUD_DIV = baud_div;
}

/* uart_putc: transmit one character
 * Polls TX_BUSY bit — spins until the previous byte finishes transmitting.
 * This blocking approach is standard for bare-metal bring-up. */
void uart_putc(char c) {
    while (UART_STATUS & UART_STATUS_TX_BUSY)
        ;   /* spin-wait: TX is busy, poll until free */
    UART_TX_DATA = (uint32_t)c;
}

/* uart_puts: transmit a null-terminated string */
void uart_puts(const char *s) {
    while (*s) {
        uart_putc(*s++);
    }
}

/* uart_puthex32: print a 32-bit value as 8 hex digits
 * Bare-metal doesn't have printf, so we implement our own hex printer.
 * This is the first thing you write on every new chip bring-up. */
void uart_puthex32(uint32_t val) {
    const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4) {
        uart_putc(hex[(val >> i) & 0xF]);
    }
}

/* ============================================================================
 * MAC Accelerator Driver
 * ============================================================================ */

/* mac_clear: reset the accumulator to zero */
void mac_clear(void) {
    MAC_ACC_CLEAR = 1;
    /* No need to poll — the hardware auto-clears the bit next cycle.
     * We add a tiny delay (nop) for conservative bring-up. */
    __asm__ volatile("nop");
    __asm__ volatile("nop");
}

/* mac_compute: perform one MAC operation: accumulator += a * b
 * Returns the new accumulated result.
 *
 * Sequence:
 *   1. Write operands A and B to their MMIO registers
 *   2. Write 1 to CTRL to trigger computation
 *   3. Poll STATUS until DONE bit is set
 *   4. Read RESULT
 *
 * This is exactly the "configure SoC subsystems via bare-metal drivers"
 * described in the Amazon JD. */
uint32_t mac_compute(uint32_t a, uint32_t b) {
    MAC_OPERAND_A = a;
    MAC_OPERAND_B = b;
    MAC_CTRL      = 1;   /* start */

    /* Poll for completion — in a real system you'd use an interrupt here */
    while (!(MAC_STATUS & MAC_STATUS_DONE))
        ;

    return MAC_RESULT;
}

/* mac_dot_product: compute dot product of two vectors using the MAC
 * dot_product([a0,a1,...an], [b0,b1,...bn]) = sum(ai * bi)
 * This is the core operation of a neural network layer. */
uint32_t mac_dot_product(const uint32_t *vec_a, const uint32_t *vec_b,
                          size_t length) {
    mac_clear();
    for (size_t i = 0; i < length; i++) {
        mac_compute(vec_a[i], vec_b[i]);
        /* Assert GPIO MAC_ACTIVE while computing */
        GPIO_DATA_OUT |= GPIO_PIN_MAC_ACTIVE;
    }
    GPIO_DATA_OUT &= ~GPIO_PIN_MAC_ACTIVE;
    return MAC_RESULT;
}

/* ============================================================================
 * GPIO Driver
 * ============================================================================ */

void gpio_init(void) {
    GPIO_DIR      = 0xFF;   /* all pins as outputs for now */
    GPIO_DATA_OUT = 0x00;   /* all LOW at boot */
}

void gpio_set(uint8_t pins) {
    GPIO_DATA_OUT |= pins;
}

void gpio_clr(uint8_t pins) {
    GPIO_DATA_OUT &= ~pins;
}

/* ============================================================================
 * Test Vectors
 * These are the "neural network weights" and "input activations" we'll use
 * to validate the MAC accelerator. Expected results are pre-computed so
 * the firmware can self-check — this is the bare-metal equivalent of a
 * scoreboard in UVM.
 * ============================================================================ */

/* Layer 0: simple 4-element dot product
 * [1,2,3,4] · [5,6,7,8] = 5+12+21+32 = 70 */
static const uint32_t weights_l0[4] = {1, 2, 3, 4};
static const uint32_t inputs_l0[4]  = {5, 6, 7, 8};
#define EXPECTED_L0  70U

/* Layer 1: larger activation test
 * [10,20,30] · [3,2,1] = 30+40+30 = 100 */
static const uint32_t weights_l1[3] = {10, 20, 30};
static const uint32_t inputs_l1[3]  = { 3,  2,  1};
#define EXPECTED_L1  100U

/* Layer 2: stress test with larger values
 * [100,200,50,25] · [4,3,8,2] = 400+600+400+50 = 1450 */
static const uint32_t weights_l2[4] = {100, 200, 50, 25};
static const uint32_t inputs_l2[4]  = {  4,   3,  8,  2};
#define EXPECTED_L2  1450U

/* ============================================================================
 * BOOT SEQUENCE
 * main() is the entry point. On a real RISC-V chip, the boot ROM would
 * set up the stack pointer and jump here. In simulation, the UVM env
 * uses a virtual sequencer to mimic this boot flow.
 * ============================================================================ */

int main(void) {

    /* ── Step 1: GPIO init — first thing on any bring-up ─────────────────── */
    gpio_init();

    /* ── Step 2: UART init ──────────────────────────────────────────────────
     * Baud divider for 115200 baud at 50MHz: 50_000_000/115200 - 1 = 433  */
    uart_init(433);

    /* ── Step 3: Boot banner ────────────────────────────────────────────────
     * On real silicon, seeing this on a serial terminal means the chip
     * is alive and the UART peripheral is functional. Big moment. */
    uart_puts("\r\n");
    uart_puts("========================================\r\n");
    uart_puts("  AZ1 Neural Edge SoC — Boot Firmware  \r\n");
    uart_puts("  Build: " __DATE__ " " __TIME__ "     \r\n");
    uart_puts("========================================\r\n");

    /* ── Step 4: Self-test sequence ─────────────────────────────────────────
     * Run each layer test and check result vs. expected value. */

    uart_puts("\r\n[TEST] MAC Accelerator Self-Test\r\n");

    /* Test Layer 0 */
    uart_puts("  Layer 0: [1,2,3,4]·[5,6,7,8] = ");
    uint32_t result_l0 = mac_dot_product(weights_l0, inputs_l0, 4);
    uart_puthex32(result_l0);
    if (result_l0 == EXPECTED_L0) {
        uart_puts(" PASS\r\n");
    } else {
        uart_puts(" FAIL! Expected ");
        uart_puthex32(EXPECTED_L0);
        uart_puts("\r\n");
        gpio_set(GPIO_PIN_ERROR);
        return -1;
    }

    /* Test Layer 1 */
    uart_puts("  Layer 1: [10,20,30]·[3,2,1] = ");
    uint32_t result_l1 = mac_dot_product(weights_l1, inputs_l1, 3);
    uart_puthex32(result_l1);
    if (result_l1 == EXPECTED_L1) {
        uart_puts(" PASS\r\n");
    } else {
        uart_puts(" FAIL! Expected ");
        uart_puthex32(EXPECTED_L1);
        uart_puts("\r\n");
        gpio_set(GPIO_PIN_ERROR);
        return -1;
    }

    /* Test Layer 2 */
    uart_puts("  Layer 2: [100,200,50,25]·[4,3,8,2] = ");
    uint32_t result_l2 = mac_dot_product(weights_l2, inputs_l2, 4);
    uart_puthex32(result_l2);
    if (result_l2 == EXPECTED_L2) {
        uart_puts(" PASS\r\n");
    } else {
        uart_puts(" FAIL! Expected ");
        uart_puthex32(EXPECTED_L2);
        uart_puts("\r\n");
        gpio_set(GPIO_PIN_ERROR);
        return -1;
    }

    /* ── Step 5: Signal boot complete ────────────────────────────────────── */
    uart_puts("\r\n[BOOT] All self-tests PASSED\r\n");
    uart_puts("[BOOT] Neural Edge SoC ready\r\n");
    gpio_set(GPIO_PIN_BOOT_OK);

    /* ── Step 6: Idle loop (simulate waiting for interrupt/workload) ─────── */
    uart_puts("[BOOT] Entering idle loop. Waiting for workload...\r\n");
    while (1) {
        /* In a real system: wfi (wait-for-interrupt) instruction */
        __asm__ volatile("nop");
    }

    return 0;
}
