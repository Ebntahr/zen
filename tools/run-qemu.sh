#!/bin/sh
# Boot Zen OS in QEMU (riscv64 virt). Requires a built kernel image at
# zig-out/zen-kernel.bin (see docs/KERNEL_INTERFACE.md) and `zig build image`.
#
#   tools/run-qemu.sh            graphical window (GTK/SDL, whatever QEMU has)
#   tools/run-qemu.sh -nographic serial console only
set -e
cd "$(dirname "$0")/.."
kernel=zig-out/zen-kernel.bin
if [ ! -f "$kernel" ]; then
    echo "run-qemu: $kernel not found — the kernel is not built yet (see docs/KERNEL_INTERFACE.md)." >&2
    exit 1
fi
display="-display default"
[ "$1" = "-nographic" ] && display="-nographic"
exec qemu-system-riscv64 -machine virt -cpu rv64 -m 2G -smp 1 -bios default \
    -kernel "$kernel" -initrd zig-out/initfs.img \
    -global virtio-mmio.force-legacy=false \
    -drive file=zig-out/zen-disk.img,if=none,format=raw,id=hd \
    -device virtio-blk-device,drive=hd \
    -device virtio-gpu-device,xres=1280,yres=800 \
    -device virtio-keyboard-device -device virtio-tablet-device \
    -serial mon:stdio $display
