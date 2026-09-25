# Hosted Zen: run the desktop today, in a browser

The Zen kernel is not finished, but everything above it is. **Hosted Zen**
runs that real user space on a Linux kernel and shows the screen in a web
browser:

- the window server, launchd, loginwindow and the apps (Finder, Terminal,
  Settings, TextEdit, Calculator, Activity Monitor);
- the `zensh` shell and the `zbox` coreutils;
- Gatekeeper code-signature checks.

These are the same programs as on Zen, not a separate simulation.

## النسخة المستضافة: جرّب سطح المكتب الآن من المتصفح

النواة لم تكتمل بعد، لكن كل ما فوقها جاهز. النسخة المستضافة تشغّل برامج Zen
الحقيقية فوق نواة Linux، وتعرض الشاشة في المتصفح:

- خادم النوافذ و launchd وشاشة الدخول والتطبيقات؛
- الصدفة `zensh` وأدوات `zbox`.

```sh
zig build run-hosted          # على Linux
# ثم افتح http://127.0.0.1:6080 — المستخدم zen وكلمة المرور zen
```

أو عبر Docker (يعمل على Linux و macOS و Windows):

```sh
zig build hosted
docker build -t zen-os zig-out/hosted
docker run --rm --hostname zen-os -p 127.0.0.1:6080:6080 -p 127.0.0.1:5900:5900 zen-os
```

الاختصارات: زر "Ctrl ⇄ ⌘" في الشريط العلوي يجعل Ctrl يعمل كمفتاح ⌘ (مثل
Ctrl+C للنسخ)، ومفتاح Windows يصبح Ctrl. التبديل إلى لوحة المفاتيح العربية يتم
من داخل Zen نفسه، لأن المتصفح يرسل مواقع المفاتيح الفعلية.

---

## Quick start

**Linux** (no root needed on most distributions):

```sh
zig build run-hosted
# open http://127.0.0.1:6080 and log in as zen / zen
```

`zig build hosted` builds everything into `zig-out/hosted/`, and
`zig-out/hosted/zen-hosted` runs it. The launcher takes these options:

| Option | Default | Meaning |
|---|---|---|
| `--size WxH` | 1280x800 | screen size |
| `--http PORT` | 6080 | web client |
| `--vnc PORT` | 5900 | RFB for VNC viewers (0 = off) |
| `--bind ADDR` | 127.0.0.1 | listen address |

Ctrl-C shuts Zen down cleanly.

**Docker** (Linux, macOS, Windows):

```sh
zig build hosted                 # on Apple Silicon: zig build hosted -Dhosted-arch=aarch64
docker build -t zen-os zig-out/hosted
docker run --rm --hostname zen-os -p 127.0.0.1:6080:6080 -p 127.0.0.1:5900:5900 zen-os
```

The image is `FROM scratch`: Zen's programs are static executables and need
nothing else.

**VNC viewers**: connect any RFB viewer to `127.0.0.1:5900`.

## Using it

- **Keyboard.** The web client sends *physical* keys, so Zen's own layouts
  apply. Switch between English and Arabic inside Zen, not in the browser.
- **Ctrl ⇄ ⌘.** On by default on Windows and Linux. With it, Ctrl acts as ⌘
  Command (Ctrl+C copies, Ctrl+Q quits), and the Windows/Super key acts as
  Ctrl (e.g. to stop a program in Terminal). Toggle it in the top bar.
- **Clipboard.** Pasting into Zen with ⌘V (Ctrl+V) uses the text on your
  computer's clipboard. Text copied inside Zen is offered to the browser's
  clipboard.
- **Arabic keyboard.** Press Alt+Shift, or use Control Center, to switch
  layouts. The menu bar shows EN or ع.
- **C and C++.** `zen-hosted` makes the Zig toolchain that built Zen
  available as `/usr/lib/zig`, so `cc hello.c -o hello && ./hello` and
  `c++ -std=c++20 app.cpp -o app` work in Terminal. The examples are in
  `/usr/share/zen/examples`. The first C++ build compiles libc++ once
  (a few minutes); later builds are fast. For Docker, build with
  `-Dhosted-toolchain=$(dirname $(which zig))` to copy the toolchain
  into the image.
- **Remote viewing.** When the page is opened from another machine,
  the web client asks for compressed updates. vncd's lossless deflate
  encoding sends about 6× less than raw pixels. On the same machine,
  raw pixels are used because they are faster. To reach a remote Zen
  safely, use an SSH tunnel (`ssh -L 6080:127.0.0.1:6080 host`), which
  also counts as "remote". Or start it with `--bind 0.0.0.0` on a
  trusted network.
- **Fit** scales the screen to the window. **⛶** switches to full screen.
- **Log out, restart, shut down.** These work as on Zen. Shut Down stops the
  hosted system.

## How it works

On Zen, the kernel forwards every `open`/`read`/`write`/`mmap` on a URL to
the server that registered the scheme. Hosted, `lib/zen/hosted.zig` does
that job over Unix sockets:

```
 app ──zen.io──▶ $ZEN_HOSTED/window  ──▶ windowserver (Server.register("window"))
                  one SOCK_SEQPACKET connection per handle,
                  one request message per call, fmap → memfd (SCM_RIGHTS)

 windowserver ──▶ display:0, input:  ──▶ vncd ──RFB──▶ VNC viewer
                                              └─WebSocket──▶ browser (web/index.html)
```

- **`zen.io`** (`lib/zen/io.zig`) is how user space opens URLs. On Zen it
  makes plain system calls. Hosted, it uses the socket of the scheme's
  server, and `file:`, `null:` and `rand:` map to the host.
- **`zen.shm`** gives memory that servers share through `fmap` (window
  buffers, the framebuffer). Hosted, that memory is a memfd.
- **`zen.sys`** handles spawn, the kernel log and power off. Hosted it
  uses `fork`/`execve`, stderr and signals to init.
- **vncd** (`hosted/vncd`) stands in for the GPU and input drivers.
- **init** reads `/etc/zen/services.hosted.conf`. It starts vncd, launchd,
  the window server and loginwindow, and applies the ownership manifest
  when it runs as root.
- **zen-hosted** (`tools/zen-hosted.zig`) sets up the environment:
  1. It enters a private mount and UTS namespace. Ordinary users also get a
     user namespace in which they are root.
  2. It makes the host's `/dev` and `/proc` visible inside the system root,
     then changes root into it.
  3. It becomes init.

## Limitations

- **The sandbox is not enforced hosted.** Enforcement is the kernel's job.
  Bundles are still verified by Gatekeeper, and sandboxed apps still get
  their containers.
- **Users.** Without root (a user namespace), every process runs as the
  same user, so switching users has no effect. With `sudo` or in Docker,
  apps run as their real users (`zen` is uid 501).
- **No authentication on the viewer ports.** For that reason they listen
  on 127.0.0.1 by default. Only expose them on a network you trust.
- **Blocked user namespaces.** Some distributions (e.g. Ubuntu 24.04)
  restrict them. Use `sudo zig-out/hosted/zen-hosted` or Docker there.

## Testing

`hosted/smoke_test.py` connects like a VNC viewer and works through these steps:

1. It checks that the login screen is drawn.
2. It logs in and checks the desktop.
3. With `--terminal-check`, it opens Terminal through Spotlight, types a
   `zensh` command, and waits for the command's output file.

CI runs it on every push:

```sh
zig build hosted && (sudo zig-out/hosted/zen-hosted &) && python3 hosted/smoke_test.py --terminal-check zig-out/hosted/root/tmp/zen-smoke
```
