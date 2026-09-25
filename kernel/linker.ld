/*
 * Zen microkernel linker script (RISC-V 64, Sv39 higher half).
 *
 * The kernel is linked at 0xFFFFFFFF80200000 but loaded by OpenSBI/QEMU at
 * the physical address 0x80200000. The boot stub runs position independent
 * code until paging is enabled and then jumps into the higher half.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

KERNEL_VMA  = 0xFFFFFFFF80200000;
KERNEL_PHYS = 0x80200000;
KOFF        = KERNEL_VMA - KERNEL_PHYS;

PHDRS
{
    text   PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data   PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = KERNEL_VMA;
    __kernel_start = .;

    .text : AT(ADDR(.text) - KOFF) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    } :text

    . = ALIGN(4096);
    .rodata : AT(ADDR(.rodata) - KOFF) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } :rodata

    . = ALIGN(4096);
    .data : AT(ADDR(.data) - KOFF) {
        *(.data .data.*)
        *(.sdata .sdata.*)
        *(.got .got.*)
    } :data

    . = ALIGN(4096);
    .bss (NOLOAD) : AT(ADDR(.bss) - KOFF) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } :data

    . = ALIGN(4096);
    __kernel_end = .;

    /DISCARD/ : {
        *(.eh_frame) *(.eh_frame_hdr) *(.comment) *(.note .note.*)
    }
}
