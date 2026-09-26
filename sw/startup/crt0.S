/*
 * sw/startup/crt0.S
 * -----------------------------------------------------------------------------
 * Reset entry for the Efinix Sapphire RV32I soft core on the Ti60.
 *
 * The core starts fetching at 0xF900_0000, the base of the 16 KiB
 * on-chip system RAM.  That RAM is pre-loaded by the FPGA configuration
 * bitstream (four BRAM init files), so this startup code does NOT relocate
 * anything: .data already holds its initial value at its link address and
 * only .bss has to be cleared.
 *
 * Toolchain: riscv-none-elf-gcc -march=rv32i -mabi=ilp32 (no M, no A, no C).
 */

    .section .text.start, "ax", @progbits
    .globl  _start
    .type   _start, @function
    .align  2
_start:
    /* stack: top of the on-chip RAM, see linker/ti60_sapphire.ld */
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)

    /* zero .bss */
    lui     a0, %hi(__bss_start)
    addi    a0, a0, %lo(__bss_start)
    lui     a1, %hi(__bss_end)
    addi    a1, a1, %lo(__bss_end)
    j       2f
1:
    sw      zero, 0(a0)
    addi    a0, a0, 4
2:
    bltu    a0, a1, 1b

    /* main() never returns; if it ever does, park the core */
    call    main
3:
    j       3b

    .size   _start, . - _start
    .end
