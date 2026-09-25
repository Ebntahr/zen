# Zen OS architecture

Zen OS is a desktop operating system for RISC-V 64 written in Zig. It
follows three ideas:

1. **Microkernel.** The kernel schedules threads, manages memory, delivers
   interrupts and passes messages. Drivers, file systems, the terminal
   layer and the window server are ordinary user-space processes.
2. **Everything is a URL** (after Redox). Every resource is named
   `scheme:path` and is served either by the kernel or by a user-space
   server that registered the scheme.
3. **POSIX on top.** The kernel speaks the Linux riscv64 system-call
   ABI, so static Zig and musl C/C++ programs run unmodified. POSIX
   paths are translated into URLs by the kernel namespace.

```
 ┌──────────────────────────── user space ────────────────────────────┐
 │ Apps (Finder, Terminal, Settings, TextEdit…)  ← sandboxed, signed  │
 │    │ window:            │ file: pty: launch:                       │
 │ windowserver ── display: ── virtio-gpud      launchd  loginwindow  │
 │    └───────── input: ─── virtio-inputd       ptyd     getty/login  │
 │ fsd (ext2) ── disk: ── virtio-blkd           init (pid 1)          │
 └────────────────────────────── syscalls ────────────────────────────┘
 ┌──────────────────────────── Zen kernel ────────────────────────────┐
 │ threads · scheduler · Sv39 memory · IRQ routing · scheme IPC       │
 │ kernel schemes: debug: null: zero: rand: sys: initfs: irq: pipe:   │
 └────────────────────────────────────────────────────────────────────┘
          OpenSBI · QEMU virt (riscv64) · virtio-mmio devices
```

## Repository layout

| Path | Contents |
|------|----------|
| `kernel/` | microkernel (work in progress, see *Status*) |
| `lib/abi/` | ABI shared by kernel and user space: scheme protocol, syscall numbers, sandbox profiles, window/display/input protocols, boot archive |
| `lib/zen/` | user-space runtime: Zen syscalls, scheme-server framework, URLs, users & passwords, app bundles, code signing |
| `lib/virtio/` | virtio-mmio transport and virtqueues for drivers |
| `lib/gfx/`, `lib/font/`, `lib/ui/` | 2D graphics with the Liquid Glass material, TrueType engine, GUI toolkit |
| `lib/vt/` | xterm-compatible terminal emulator core |
| `lib/ext2/` | ext2 file system (read/write, mkfs) |
| `drivers/` | virtio-blk, virtio-gpu, virtio-input |
| `servers/` | init, ptyd, launchd, fsd, windowserver |
| `userland/` | shell (zensh), coreutils (zbox), auth tools, getty, cc |
| `apps/` | desktop applications (`.app` bundles) |
| `sysroot/` | static files copied into the root disk |
| `tools/` | host build tools (boot archive, code signing, image builder) |

## Schemes and the namespace

| URL | Served by | Purpose |
|-----|-----------|---------|
| `file:/…` | fsd | root file system (ext2 on `disk:`) |
| `disk:` | virtio-blkd | raw block device |
| `display:0`, `display:0/cursor` | virtio-gpud | framebuffer and hardware cursor |
| `input:` | virtio-inputd | keyboard/mouse/tablet events |
| `window:new?…`, `window:clipboard`, `window:control` | windowserver | windows, clipboard, session control |
| `pty:ptmx`, `pty:N` | ptyd | pseudo terminals with termios line discipline |
| `launch:ctl`, `launch:apps`, `launch:running` | launchd | launching apps, installed/running apps |
| `sys:proc/…`, `sys:devices`, `sys:log`, `sys:uname`, `sys:meminfo` | kernel | process table, devices, kernel log |
| `debug:` | kernel | serial console |
| `null:`, `zero:`, `rand:` | kernel | the usual special files |
| `initfs:/…` | kernel | read-only boot archive |
| `irq:N` | kernel | interrupt delivery to drivers |

POSIX paths are mapped by the kernel: `/dev/null` → `null:`, `/dev/urandom`
→ `rand:`, `/dev/pts/N` → `pty:N`, `/dev/tty` → the controlling terminal,
`/proc/…` → `sys:proc/…`, everything else under `/` → `file:/…`.
`/scheme/<name>/<path>` is accepted as an alternative spelling of
`<name>:<path>`.

### Scheme protocol

A server calls `zen_scheme_register(name)` and gets a file descriptor. It
reads fixed-size `Request` headers (followed by payload bytes such as a
path or write data) and writes `Response` headers (followed by data such
as read results). Requests can be answered later and out of order, which is
how blocking reads and `poll()` work: `poll` sends `fevent` requests that
the server answers when the handle becomes ready. The kernel stamps each
request with the caller's pid, uid and gid, so servers enforce permissions.
See `lib/abi/scheme.zig`; `lib/zen/server.zig` is the server framework.

## Boot sequence

1. OpenSBI starts the kernel in S-mode with the device tree.
2. The kernel sets up memory, interrupts and the boot archive (`initfs:`),
   then runs `initfs:/sbin/init` as pid 1.
3. init reads `sys:devices` and starts the virtio drivers, then `fsd` on
   `disk:`, which serves the ext2 root as `file:`.
4. init starts the services in `/etc/zen/services.conf`: ptyd, launchd,
   windowserver, loginwindow and a getty on the serial console.
5. loginwindow shows the login screen; after authentication it tells
   launchd and the window server to begin the user's session.

## Security model

* **Users and groups** in `/etc/passwd`, `/etc/group` and `/etc/shadow`.
  Passwords are Argon2id hashes. Members of `admin` can use `sudo`.
* **Permissions** are enforced by each scheme server using the caller's
  credentials that the kernel attaches to every request (ext2 mode bits,
  root-only `display:`/`input:`/`window:control`).
* **App Sandbox.** Apps whose bundle has the
  `com.zen.security.app-sandbox` entitlement run in a container:
  `~/Library/Containers/<bundle-id>/Data` becomes their home and the only
  writable place, plus folders granted by entitlements (Documents,
  Downloads, Pictures…). launchd builds a sandbox profile
  (`lib/abi/sandbox.zig`) and the kernel checks every URL the process and
  its children open. Profiles only get stricter.
* **Code signing / Gatekeeper.** Bundles carry `Contents/CodeSignature`:
  SHA-256 hashes of every file signed with Ed25519. launchd refuses
  modified bundles and bundles from unknown signers unless the user
  approved them.

## Application bundles

```
TextEdit.app/Contents/Info.conf          id, name, version, executable, icon
TextEdit.app/Contents/Entitlements.conf  one entitlement per line
TextEdit.app/Contents/Bin/TextEdit
TextEdit.app/Contents/Resources/
TextEdit.app/Contents/CodeSignature
```

## Desktop

The window server composites client buffers (premultiplied ARGB) with
damage tracking. It draws title bars with traffic-light buttons, soft window
shadows, the global menu bar, the Dock, the app switcher and notification
banners. The Liquid Glass material samples a blurred copy of the content
behind a surface, bends it near the edges like a lens, adds a specular rim
and tints it (`lib/gfx`). Apps link the `lib/ui` toolkit.

## C and C++

Programs are built for `riscv64-linux-musl`:

* on a development host: `zig cc -target riscv64-linux-musl -static …`
  (see `examples/`), then copy the binary into the image;
* inside Zen: the image can include the riscv64 Zig toolchain under
  `/usr/lib/zig`; `cc`, `c++`, `gcc`, `g++`, `ar` and `ld` are wrappers
  around it (`userland/cc`).

## Status

Working and tested on the host: the ABI, libzen (including password hashing
and code signing), the pty line discipline, the libraries in `lib/`, the
shell and coreutils, and all user-space programs cross-compile for riscv64.
The kernel is incomplete: memory management, trap handling, the scheduler
and system calls still have to be written before the image can boot.
