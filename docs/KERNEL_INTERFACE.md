# Kernel interface expected by Zen user space

The user space in this repository runs on top of the Zen microkernel. This
document specifies what the kernel must provide. It is the contract for
finishing `kernel/`. All types referenced here live in `lib/abi/`.

## 1. Boot

* Machine: QEMU `virt`, riscv64, OpenSBI (`-bios default`), S-mode kernel.
* The kernel receives the device tree in `a1`. `kernel/fdt.zig` already
  extracts memory, the initrd range (`/chosen/linux,initrd-*`), PLIC, UART,
  Goldfish RTC, `rng-seed` and all `virtio,mmio` nodes.
* The initrd is `zig-out/initfs.img` (format: `lib/abi/initfs.zig`). The
  kernel serves it read-only as `initfs:` and starts `initfs:/sbin/init` as
  pid 1 with uid 0.
* Reference command line (virtio-mmio in modern mode):

```sh
qemu-system-riscv64 -machine virt -cpu rv64 -m 2G -smp 1 -bios default \
  -kernel zig-out/zen-kernel.bin -initrd zig-out/initfs.img \
  -global virtio-mmio.force-legacy=false \
  -drive file=zig-out/zen-disk.img,if=none,format=raw,id=hd \
  -device virtio-blk-device,drive=hd \
  -device virtio-gpu-device,xres=1280,yres=800 \
  -device virtio-keyboard-device -device virtio-tablet-device \
  -serial mon:stdio
```

## 2. Processes and the Linux ABI

User programs are static riscv64 ELF executables built with Zig
(`riscv64-linux-none`) or musl (`riscv64-linux-musl`).

* **Syscall convention.** `ecall` with the number in `a7`, arguments in
  `a0`–`a5` and the result in `a0`. Errors return `-errno` (Linux values).
* **exec.**
  * ET_EXEC and static-PIE ET_DYN.
  * Standard initial stack: argc, argv, envp and auxv, with AT_PHDR,
    AT_PHENT, AT_PHNUM, AT_PAGESZ, AT_ENTRY, AT_RANDOM, AT_UID/EUID/GID/EGID,
    AT_SECURE, AT_HWCAP, AT_EXECFN, AT_NULL.
  * `#!` scripts.
  * setuid/setgid bits from the file's `fstat` (used by `/usr/bin/zauth`).
    They are ignored for sandboxed callers.
* **Signals.** musl on riscv64 has no `SA_RESTORER`, so the kernel must
  provide the `rt_sigreturn` trampoline, as Linux does with its vDSO.
  Other requirements:
  * SIGINT/SIGQUIT/SIGTSTP to process groups, because ptyd calls `kill(-pgid, …)`.
  * SIGWINCH, SIGCHLD and SIGPIPE.
  * Blocking calls return EINTR when a signal arrives.
* **Threads.** `clone` with CLONE_VM | CLONE_THREAD | CLONE_SETTLS |
  CLONE_PARENT_SETTID | CLONE_CHILD_CLEARTID, `futex` (WAIT/WAKE/
  WAIT_BITSET), `set_tid_address`, `set_robust_list`. These are used by C++
  `std::thread` and by the Zig toolchain.
* **fork/vfork.** `clone(SIGCHLD)` and `clone(CLONE_VM|CLONE_VFORK)`, used by
  zensh and musl `posix_spawn`.

System calls used by the user space and its libraries (asm-generic numbers):

| Area | Calls |
|------|-------|
| files | openat(56) close(57) read(63) write(64) readv(65) writev(66) pread64(67) pwrite64(68) lseek(62) getdents64(61) fstat(80) newfstatat(79) statx(291) readlinkat(78) faccessat(48) faccessat2(439) ftruncate(46) fsync(82) fdatasync(83) utimensat(88) fchmod(52) fchmodat(53) fchown(55) fchownat(54) mkdirat(34) unlinkat(35) symlinkat(36) linkat(37) renameat(38) renameat2(276) statfs(43) fstatfs(44) getcwd(17) chdir(49) fchdir(50) dup(23) dup3(24) fcntl(25) ioctl(29) pipe2(59) ppoll(73) pselect6(72) sendfile(71) |
| memory | brk(214) mmap(222) munmap(215) mremap(216) mprotect(226) madvise(233) |
| processes | clone(220) execve(221) exit(93) exit_group(94) wait4(260) getpid(172) getppid(173) gettid(178) setpgid(154) getpgid(155) setsid(157) getsid(156) prctl(167) sched_yield(124) |
| credentials | getuid(174) geteuid(175) getgid(176) getegid(177) setuid(146) setgid(144) setresuid(147) setresgid(149) getgroups(158) setgroups(159) umask(166) |
| signals | rt_sigaction(134) rt_sigprocmask(135) rt_sigreturn(139) kill(129) tkill(130) tgkill(131) sigaltstack(132) |
| time | clock_gettime(113) clock_getres(114) clock_nanosleep(115) nanosleep(101) gettimeofday(169) times(153) |
| misc | uname(160: sysname "Zen") getrandom(278) futex(98) set_tid_address(96) set_robust_list(99) getrlimit/prlimit64(163/261) getrusage(165) sysinfo(179) reboot(142) |

## 3. Zen system calls (`lib/abi/syscall.zig`)

| Nr | Call | Notes |
|----|------|-------|
| 500 | `scheme_register(name, len, flags)` → fd | root and not sandboxed; one server per name |
| 501 | `physmap(pa, len, flags)` → va | device memory; root and not sandboxed |
| 502 | `physalloc(len, *u64 pa)` → va | zeroed, physically contiguous (DMA) |
| 503 | `virt2phys(va)` → pa | |
| 504 | `spawn(*SpawnArgs)` → pid | fd remapping, cwd, uid/gid/groups (root only), sandbox profile, setsid/setpgid |
| 505 | `sandbox_apply(profile, len)` | irreversible |
| 506 | `sandbox_grant(pid, path, len, mode)` | powerbox (trusted callers) |
| 507 | `klog(msg, len)` | appends to `sys:log` and the serial console |
| 508 | `proc_info(pid, *ProcInfo)` | Activity Monitor |
| 509 | `proc_list(*u32, max)` → count | |
| 510 | `power(cmd)` | 0 = power off, 1 = reboot (SBI SRST) |
| 511 | `set_name(name, len)` | process name for ps |

## 4. Namespace: paths → URLs

* A string of the form `name:rest` is a URL when `name` contains only
  letters, digits, `-`, `_` and `.`.
* `/scheme/<name>/<rest>` is equivalent to `<name>:<rest>`.
* Relative paths resolve against the cwd or the `*at` dirfd. Both are
  stored as URLs.
* Paths are normalized (`.` and `..` resolved) before routing.
* Mount table, longest prefix wins:

| POSIX path | URL |
|------------|-----|
| `/dev/null`, `/dev/zero` | `null:`, `zero:` |
| `/dev/random`, `/dev/urandom` | `rand:` |
| `/dev/tty` | the process's controlling terminal (`pty:N`) |
| `/dev/ptmx`, `/dev/pts/N` | `pty:ptmx`, `pty:N` |
| `/dev/console` | `debug:` |
| `/proc/...` (incl. `self`) | `sys:proc/...` |
| everything else under `/` | `file:/...` |

`getcwd` returns the POSIX form for `file:` paths and the URL otherwise.

## 5. Kernel schemes

| Scheme | Semantics |
|--------|-----------|
| `debug:` | serial console; read = raw bytes (UART RX interrupt), write = UART TX |
| `null:` `zero:` `rand:` | as `/dev/null`, `/dev/zero`, `/dev/urandom`; writes to `rand:` add entropy |
| `initfs:` | read-only boot archive, supports directory listing |
| `irq:N` | drivers only; `read` blocks until IRQ N fired and returns a u64 count; `write` (u64) completes the interrupt at the PLIC; pollable |
| `pipe:` | pipes created by `pipe2` |
| `sys:` | described below |

The `sys:` scheme serves these files:

* **`sys:devices`**: one device per line,
  `<compatible> <base-hex> <size-hex> <irq> [virtio=<device-id>]`.
  The kernel reads the virtio DeviceID register at MMIO offset 0x008.
* **`sys:proc/<pid>/`**, where `self` is also accepted:
  * `status`: Linux-like `Name:`, `State:`, `Pid:`, `PPid:`, `Uid:`, `Gid:`,
    `VmRSS:` and `Threads:` lines.
  * `cmdline`, `stat` and `exe`. `exe` is a symlink and is used by the Zig
    toolchain to find its lib directory.
  * `fd/N` (symlinks).
* **Linux-style system files**: `sys:proc/meminfo`, `sys:proc/uptime`,
  `sys:proc/loadavg`, `sys:proc/stat`, `sys:proc/cpuinfo`.
* **`sys:uname`, `sys:hostname`, `sys:schemes`**, and **`sys:log`** (kernel
  log ring buffer; `kernel/console.zig`).

## 6. Routing requests to user schemes (`lib/abi/scheme.zig`)

The kernel turns file operations on a user scheme into `Request` packets.
The server reads them from its scheme fd and writes `Response` packets back.

* **Credentials.** Every request carries the caller's pid, euid and egid.
  `caller_flags` bit 0 is set for sandboxed callers.
* **Blocking.** The caller blocks until the matching response arrives.
  Responses can arrive out of order. Payload is limited to 64 KiB per
  request, so large writes return short counts and libc retries.
* **Interruption.** If a signal interrupts a blocked `read`, `write` or
  `fevent`, the kernel sends `cancel` (arg0 = request id) and returns EINTR.
* **close.** Sent as fire-and-forget when the last reference to an open
  file description goes away. fork and dup share descriptions.
* **Paths.** `open`/`stat`/`mkdir`/… carry the path inside the scheme as
  payload. `rename`/`symlink`/`link` carry `a\0b`. `utimens` carries two
  `Timespec` values followed by the path.
* **ioctl.** The kernel knows the argument sizes of TCGETS/TCSETS* (36
  bytes), TIOCGWINSZ/TIOCSWINSZ (8), TIOCGPGRP/TIOCSPGRP/TIOCGSID/
  TIOCGPTN/TIOCSPTLCK/FIONREAD (4), BLKGETSIZE64 (8) and value-type
  requests (TIOCSCTTY, TCFLSH, TCSBRK). It copies the input as payload and
  copies back up to `arg1` bytes of output. TIOCSCTTY also records the
  controlling terminal for `/dev/tty`.
* **mmap.** `mmap(MAP_SHARED)` sends `fmap`. The result is a page-aligned
  address in the server's address space, and the kernel maps the same
  physical pages into the client. This path is used for the framebuffer,
  the hardware cursor and window buffers. `MAP_PRIVATE` file mappings are
  filled with `read` requests.
* **poll/ppoll.** On scheme handles, poll sends `fevent` (arg0 = events).
  Servers answer when the handle becomes ready. Unanswered fevents are
  cancelled when poll returns.
* **Symlinks.** fsd resolves them inside its own tree.

## 7. Sandbox enforcement

For sandboxed processes (`lib/abi/sandbox.zig`, profiles built by launchd
from entitlements):

* Every URL opened, stat'ed, executed, created, renamed or deleted is
  checked with `Profile.check(scheme, normalized_path, access)`. Denials
  return EACCES and are logged to `sys:log`. Access bits: open for read →
  READ, write/create/unlink/rename → WRITE, exec → EXEC.
* `spawn`/`execve` by a sandboxed process requires FLAG_ALLOW_SPAWN.
  Children inherit the profile. A profile passed to `spawn` must satisfy
  `parent.contains(child)`.
* Zen syscalls 500–503 and 505–506 fail with EPERM. So do setuid/setgid
  changes, `kill` of processes outside the sandboxed process group, and
  `ptrace`-like operations.
* `sys:proc/self/*` is readable. Other processes' entries are not.

## 8. Services that depend on these semantics

| Program | Relies on |
|---------|-----------|
| init | `sys:devices`, `spawn`, `initfs:`, waitpid |
| drivers | `physmap`, `physalloc`, `irq:N`, poll |
| fsd | `disk:` via pread/pwrite, credential stamping |
| ptyd | `kill(-pgid)`, poll timeouts |
| windowserver | `fmap` sharing of display, cursor and window buffers |
| launchd | `spawn` with uid/gid/groups/sandbox, `SPAWN_SETSID`, waitpid WNOHANG |
| zensh and zbox | fork/execve/wait4, pipes, termios ioctls, getdents64, statx/newfstatat |
