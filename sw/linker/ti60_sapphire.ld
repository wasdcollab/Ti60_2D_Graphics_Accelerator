/*
 * Ti60 Sapphire (Efinix EfxSapphireSoc, RV32I) link map
 * =============================================================================
 * The SoC has 64 KiB of on-chip system RAM at 0xF900_0000 and it is
 * pre-loaded from the bitstream (4 x 16384-entry BRAM init files).  That means
 *
 *   * the reset vector is 0xF900_0000 and .text.start must land there,
 *   * .data already contains its initial values in the image, so the startup
 *     code must NOT copy it - it only has to zero .bss,
 *   * anything placed in this region is loaded, so the region is also the
 *     hard code-size budget.
 *
 * Layout
 *   0xF900_0000  .text.start  (reset vector / _start)
 *   0xF900_0004  .text .rodata .data .bss        <= 0xFC00 bytes
 *   0xF900_FC00  __stack_floor  (1 KiB stack above)
 *   0xF901_0000  _stack_top == initial SP (top of RAM)
 *
 * The software watchdog in the simulator uses the same floor, so a stack
 * overflow is reported before it can corrupt the linked image.
 */

ENTRY(_start)

MEMORY
{
    image (rwx) : ORIGIN = 0xF9000000, LENGTH = 0xFC00
}

SECTIONS
{
    .text : ALIGN(4)
    {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > image

    .rodata : ALIGN(4)
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > image

    .data : ALIGN(4)
    {
        __data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        __data_end = .;
    } > image

    .bss (NOLOAD) : ALIGN(4)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > image

    __image_end = .;

    PROVIDE(__stack_floor = 0xF900FC00);
    PROVIDE(_stack_top    = 0xF9010000);

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
