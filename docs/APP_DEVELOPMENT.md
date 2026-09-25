# Writing apps for Zen OS

Zen apps are static Zig programs for `riscv64-linux-none`. Desktop apps use
**GlassKit** (`lib/ui`), an immediate-mode toolkit with the macOS 26 look.
Command-line programs can use plain Zig `std` or C/C++ (see the end of this
guide).

## 1. A minimal app

See `examples/zig-app/`:

```zig
pub const App = struct {
    count: u32 = 0,

    pub const window = ui.client.Options{ .title = "Hello Zen", .width = 420, .height = 260 };

    pub fn init(allocator: std.mem.Allocator, u: *ui.Ui) !App { ... }

    pub fn frame(self: *App, u: *ui.Ui) void {
        u.clear(u.theme.window_bg);
        u.text(ui.Rect.init(24, 20, 372, 32), "Hello from Zen OS", .{ .size = 22, .weight = .bold });
        if (u.button("click", ui.Rect.init(24, 160, 120, 32), "Click me", .{ .style = .primary }))
            self.count += 1;
    }
};
```

```zig
// main.zig
pub fn main() !void { try @import("ui").run(@import("app.zig").App); }
```

`ui.run` does the following:

1. Opens the window (`window:new?...`).
2. Loads the system fonts.
3. Installs your menu, if the app has a `menu` function.
4. Calls `frame` once per batch of input events.

Optional hooks:

- `menu`, `onMenu`: the menu bar;
- `shouldClose`, `shouldQuit`: return false to ask about unsaved changes;
- `openDocuments(self, u, paths)`: documents opened with the app while it
  runs (Finder, `open file` in Terminal);
- `timeoutMs`: periodic refresh; set `u.want_frame` for one extra frame;
- `deinit`;
- `preview`: state used for screenshots.

Build and preview:

```sh
tools/zigmod build-exe examples/zig-app/main.zig -target riscv64-linux-none -O ReleaseSmall -femit-bin=HelloZen
tools/zigmod run examples/zig-app/preview.zig -O ReleaseFast -- /tmp/hello.png   # headless PNG
```

## 2. Toolkit overview (`lib/ui/ui.zig`)

| Group | Functions |
|-------|-----------|
| Drawing | `clear`, `fillRect`, `fillRound`, `strokeRound`, `fillCircle`, `line`, `shadow`, `pushClip`/`popClip`, `text`, `textAt`, `paragraph`, `measure` |
| Controls | `button` (normal/primary/plain/destructive/toolbar), `toggle`, `checkbox`, `slider`, `segmented`, `popup` (pop-up menu), `textField` (selection, clipboard, secure, capsule/plain), `sidebarItem`, `listRow`, `group`, `separator`, `progress`, `avatar` |
| Tables | `tableHeader` (sortable column headers with `SortState`), `tableCells` (a row's cells in the same `Column` layout; draw the row background with `listRow`), `tableLayout` |
| Scrolling | `beginScroll`/`endScroll` with `ScrollState` |
| Input | `interact(id, rect)`, `hovering`, `keyPressed`, `shortcut`, and the `keys`/`text_in` arrays |
| Theme | `u.theme` (light/dark tokens and accent) is updated automatically when the system appearance changes |
| Graphics | `u.canvas` is a `gfx.Canvas`, so every `lib/gfx` primitive (paths, gradients, glass) and every `lib/icons` icon is available |

Text in any script renders through Inter. Arabic uses Noto Sans Arabic and is
shaped and reordered automatically.

## 3. Bundles

```
HelloZen.app/Contents/Info.conf           id, name, version, executable, icon, category
HelloZen.app/Contents/Entitlements.conf   one entitlement per line
HelloZen.app/Contents/Bin/HelloZen
```

Install bundles in `/Applications`. launchd finds them there, and they
appear in Spotlight (Cmd-Space) and Finder.

### Entitlements (`lib/zen/bundle.zig`)

| Entitlement | Grants |
|-------------|--------|
| `com.zen.security.app-sandbox` | run in a container: `~/Library/Containers/<id>/Data` becomes `$HOME` |
| `com.zen.security.files.documents.read-write` (`.read-only`) | `~/Documents` |
| `com.zen.security.files.downloads.read-write` | `~/Downloads` |
| `com.zen.security.files.pictures.read-write`, `.music.`, `.movies.` | those folders |
| `com.zen.security.network.client` | `tcp:`, `udp:`, `dns:` schemes |
| `com.zen.security.cs.allow-spawn` | launching helper processes |

### Code signing

Gatekeeper (in launchd) only launches bundles signed by a trusted key, or
unsigned bundles the user explicitly approved in `/etc/zen/gatekeeper.allow`.

```sh
zig build tools
zig-out/tools/codesign keygen my.key my.pub
zig-out/tools/codesign sign my.key HelloZen.app
zig-out/tools/codesign verify my.pub HelloZen.app
```

Built-in apps are signed during `zig build image` with the platform key in
`keys/platform.key`. The public half is installed as
`/System/Library/Security/platform.pub`.

## 4. Everything is a URL

Open URLs with `zen.io` (`open`, `read`, `write`, `mmap`, `poll`, `readUrl`,
`transact`). On Zen these are plain system calls. In hosted mode (see
[HOSTED.md](HOSTED.md)) they reach the scheme's server over its socket.
On Zen itself, any `std.fs` or POSIX call also accepts URLs:

```zig
const f = try std.fs.cwd().openFile("sys:uname", .{});   // kernel info
var d = try std.fs.cwd().openDir("sys:proc", .{ .iterate = true }); // processes
const w = try std.posix.open("window:new?w=300&h=200&title=Raw", .{ .ACCMODE = .RDWR }, 0);
```

Write your own services with `lib/zen/server.zig` (`Server.register("myscheme")`).
The protocol is described in `lib/abi/scheme.zig`.

## 5. C and C++

```sh
# on a development machine
zig cc  -target riscv64-linux-musl -static -O2 hello.c   -o hello
zig c++ -target riscv64-linux-musl -static -O2 app.cpp   -o app
# inside Zen OS (image built with -Dtoolchain=...)
cc hello.c -o hello && ./hello
c++ -std=c++20 app.cpp -o app && ./app
```

Zen speaks the Linux riscv64 system-call ABI, so ordinary POSIX C code
works as-is: stdio, pthreads, sockets once networking exists, and
`opendir("sys:proc")`.
