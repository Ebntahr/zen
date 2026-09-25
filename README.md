# Zen OS

**نظام تشغيل سطح مكتب مكتوب بالكامل بلغة Zig لمعمارية RISC-V 64**
**A desktop operating system written entirely in Zig for RISC-V 64**

> ⚠️ **Status:** the kernel is incomplete. User space (drivers, servers,
> desktop libraries, shell, tools) is written and tested on the host, and it
> cross-compiles for riscv64. However, the kernel's memory management, trap
> handling, scheduler and system calls are **not written yet**, so the image
> does **not boot** today. See [Status](#status--الحالة).

---

## العربية

Zen OS نظام تشغيل حديث مبني على نواة مصغّرة (microkernel). يتبنّى فلسفة
**"كل شيء رابط"** كما في Redox. واجهته قريبة من macOS بتأثير **Liquid Glass**.

- **نواة مصغّرة بلغة Zig**: التعريفات ونظام الملفات وخادم النوافذ برامج
  عادية تعمل في مساحة المستخدم.
- **كل شيء رابط (URL)**: مثل `file:/Users/zen` و`sys:proc/1/status`
  و`display:0` و`pty:3` و`window:new?...`. مسارات POSIX تُترجم تلقائياً
  (`/dev/null` → `null:`).
- **متوافق مع POSIX**: النواة تتكلم واجهة استدعاءات Linux لمعمارية riscv64،
  فتعمل برامج C/C++ المبنية على musl وبرامج Zig كما هي.
- **أدوات GNU الأساسية**: `zbox` فيه ls وcat وgrep وsed وfind وsort وdiff
  وless وغيرها. ومعها صدفة `zensh` المتوافقة مع POSIX.
- **دعم C وC++**: البناء على جهازك عبر `zig cc -target riscv64-linux-musl`،
  أو داخل النظام بأوامر `cc` و`c++` و`gcc` و`g++`.
- **أمان**: مستخدمون ومجموعات، وكلمات مرور بـ Argon2id، و`sudo` لمجموعة
  admin، وصلاحيات POSIX.
- **عزل التطبيقات كما في macOS**: كل تطبيق فيه `app-sandbox` يعمل داخل
  حاوية `~/Library/Containers/<id>`، والنواة تتحقق من كل رابط يفتحه.
- **توقيع التطبيقات (Gatekeeper)**: كل تطبيق موقّع بـ Ed25519، ويُرفض
  التطبيق المعدَّل أو المجهول المصدر.
- **سطح مكتب حديث**: شريط قوائم وDock زجاجيان، ونوافذ بأزرار الإشارات
  الثلاثة، ووضع فاتح وداكن، وخطوط Inter وJetBrains Mono بمحرّك TrueType
  مكتوب بـ Zig، ودعم لوحة المفاتيح العربية.

**الحساب الافتراضي:** المستخدم `zen` وكلمة المرور `zen` (عضو في مجموعة admin).

---

## English

### Highlights

- **Microkernel in Zig.** The drivers (virtio-blk, virtio-gpu, virtio-input),
  the ext2 file server, the pty server and the window server all run in user
  space.
- **Everything is a URL** (after Redox). Examples: `file:/…`, `sys:proc`,
  `display:0`, `input:`, `pty:N`, `window:new?w=…`, `launch:ctl`.
  User-space servers register schemes and answer request packets. POSIX
  paths map onto URLs (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
- **POSIX through the Linux ABI.** Zen implements the Linux riscv64 system
  calls, so static Zig programs and musl C/C++ binaries run unmodified.
- **GNU-style tools.**
  - `zbox`: a multi-call binary with ~100 coreutils/grep/sed/find/diff/less-style commands.
  - `zensh`: a POSIX shell with job control, line editing and completion.
  - `zauth`: `login`, `su`, `sudo`, `passwd`, `useradd`, `userdel`.
- **C and C++.**
  - Build on a development host with `zig cc/c++ -target riscv64-linux-musl`.
  - Inside Zen, `cc`, `c++`, `gcc`, `g++`, `ar` and `ld` wrap the bundled
    riscv64 Zig toolchain.
- **Security.**
  - Users and groups, with Argon2id password hashes.
  - POSIX permissions, enforced by each scheme server.
  - **App Sandbox containers**, enforced by the kernel for every URL a
    process opens.
  - **Code signing and Gatekeeper**: Ed25519 signatures over SHA-256
    hashes of every file in a bundle.
- **Desktop, inspired by macOS 26.**
  - A compositing window server with shadows, rounded windows and traffic lights.
  - A glass menu bar and Dock, an app switcher and notifications.
  - Light and dark modes with accent colors.
  - A pure-Zig TrueType engine rendering Inter and JetBrains Mono.
  - Procedural wallpapers.
  - US and Arabic keyboard layouts.

### Building

Requirements: Zig **0.15.2**. QEMU (`qemu-system-riscv64`) is needed to run
the system once the kernel is complete.

```sh
zig build            # all user-space programs → zig-out/sysroot (riscv64)
zig build test       # host unit tests for the libraries and servers
```

Individual pieces:

```sh
zig run lib/gfx/demo.zig -- /tmp/demo.png          # render the Liquid Glass demo scene
zig cc -target riscv64-linux-musl -static examples/c/hello.c -o hello
zig c++ -target riscv64-linux-musl -static examples/cpp/hello.cpp -o hello-cpp
```

### Repository layout

| Path | What |
|------|------|
| `kernel/` | microkernel (incomplete) |
| `lib/abi` | kernel ↔ user ABI: scheme protocol, syscalls, sandbox, window/display/input protocols |
| `lib/zen` | user runtime: syscalls, scheme servers, users/passwords, bundles, code signing |
| `lib/gfx`, `lib/font`, `lib/ui` | graphics + Liquid Glass, TrueType, GUI toolkit |
| `lib/vt`, `lib/ext2`, `lib/virtio` | terminal emulator core, ext2, virtio transport |
| `drivers/`, `servers/` | user-space drivers and system servers |
| `userland/` | shell, coreutils, account tools, getty, C/C++ driver |
| `apps/` | desktop app bundles |
| `sysroot/` | files installed into the root disk |
| `tools/` | host tools: boot archive, image preparation, code signing |
| `legacy/` | the original i386 Zen kernel |

### Status / الحالة

| Component | State |
|-----------|-------|
| ABI, libzen, sandbox profiles, code signing, password hashing | ✅ written and tested |
| virtio drivers, fsd (ext2), ptyd, launchd, init, getty, zauth, cc | ✅ written; build for riscv64 |
| Fonts, terminal core, ext2 library, window-manager core | ✅ written and tested |
| Graphics and Liquid Glass, shell, coreutils | 🔄 in progress |
| Window-server rendering, GUI toolkit, apps | 🔄 in progress |
| **Kernel**: boot entry, paging/VM, traps, scheduler, syscalls, kernel schemes | ❌ **not written**, so the system cannot boot yet |

Done in the kernel so far: the linker script, CSR/SBI helpers, UART console,
device-tree parser, physical memory manager, heap, timer/RTC, PLIC and
CSPRNG.

### License

BSD-3-Clause (see `LICENSE`). Fonts: SIL Open Font License 1.1
(`assets/fonts/LICENSE.md`).
