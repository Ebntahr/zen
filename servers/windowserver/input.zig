//! Keyboard and pointer handling for the window server.

const std = @import("std");
const abi = @import("abi");
const wm = @import("wm.zig");
const st = @import("state.zig");
const chrome = @import("chrome.zig");
const protocol = @import("protocol.zig");

const inp = abi.input;
const proto = abi.window;
const Key = inp.Key;

pub const Actions = struct {
    /// Called to move the hardware cursor / change its shape.
    set_cursor: *const fn (x: i32, y: i32, shape: proto.Cursor) void,
    /// Launch or activate an app through launchd.
    launch: *const fn (state: *st.State, id: []const u8) void,
    /// Send a text message to loginwindow ("lock", "logout", …).
    session: *const fn (state: *st.State, msg: []const u8) void,
};

pub const Input = struct {
    state: *st.State,
    proto: *protocol.Protocol,
    actions: Actions,
    abs_x: i32 = -1,
    abs_y: i32 = -1,
    moved: bool = false,
    /// Resize event owed to the dragged window (sent once per frame).
    pending_resize: u32 = 0,
    shape: proto.Cursor = .arrow,

    fn s(self: *Input) *st.State {
        return self.state;
    }

    pub fn feed(self: *Input, events: []const inp.InputEvent) void {
        for (events) |e| {
            switch (e.kind) {
                inp.EV_KEY => {
                    if (e.code >= inp.BTN_LEFT and e.code <= inp.BTN_MIDDLE or e.code == inp.BTN_TOUCH) {
                        self.flushMotion();
                        const b: i32 = switch (e.code) {
                            inp.BTN_RIGHT => 2,
                            inp.BTN_MIDDLE => 3,
                            else => 1,
                        };
                        if (e.value != 0) self.buttonDown(b) else self.buttonUp(b);
                    } else if (e.code < 256) {
                        self.key(e.code, e.value);
                    }
                },
                inp.EV_ABS => {
                    if (e.code == inp.ABS_X) self.abs_x = e.value;
                    if (e.code == inp.ABS_Y) self.abs_y = e.value;
                    const st_ = self.s();
                    if (self.abs_x >= 0) st_.mouse.x = @intCast(@divTrunc(@as(i64, self.abs_x) * st_.width, inp.ABS_MAX + 1));
                    if (self.abs_y >= 0) st_.mouse.y = @intCast(@divTrunc(@as(i64, self.abs_y) * st_.height, inp.ABS_MAX + 1));
                    self.moved = true;
                },
                inp.EV_REL => switch (e.code) {
                    inp.REL_X => {
                        self.s().mouse.x = std.math.clamp(self.s().mouse.x + e.value, 0, self.s().width - 1);
                        self.moved = true;
                    },
                    inp.REL_Y => {
                        self.s().mouse.y = std.math.clamp(self.s().mouse.y + e.value, 0, self.s().height - 1);
                        self.moved = true;
                    },
                    inp.REL_WHEEL => self.scroll(0, -e.value * 40),
                    inp.REL_HWHEEL => self.scroll(e.value * 40, 0),
                    else => {},
                },
                inp.EV_SYN => self.flushMotion(),
                else => {},
            }
        }
        self.flushMotion();
    }

    fn event(win: *wm.Window, kind: proto.EventKind, mods: u32, a: i32, b: i32, c: i32, d: i32) void {
        win.pushEvent(.{ .kind = kind, .mods = mods, .a = a, .b = b, .c = c, .d = d });
    }

    fn updateCursor(self: *Input, shape: proto.Cursor) void {
        self.shape = shape;
        self.actions.set_cursor(self.s().mouse.x, self.s().mouse.y, shape);
    }

    fn flushMotion(self: *Input) void {
        if (!self.moved) return;
        self.moved = false;
        const state = self.s();
        const mx = state.mouse.x;
        const my = state.mouse.y;
        var shape: proto.Cursor = .arrow;

        if (state.manager.drag.kind != .none) {
            if (state.manager.updateDrag(mx, my)) |r| {
                state.invalidate(r.old_bounds);
                state.invalidate(r.win.paintBounds());
                if (r.resized) self.pending_resize = r.win.id;
                shape = if (state.manager.drag.kind == .resize) resizeCursor(state.manager.drag.edge) else .arrow;
            }
            self.updateCursor(shape);
            return;
        }
        if (state.menu.index >= 0) {
            chrome.menuHover(state, mx, my);
            self.updateCursor(.arrow);
            return;
        }
        if (state.session == .active) chrome.dockHover(state, mx, my);

        // Pointer grab: while a button is held, the pressed window gets motion.
        const target: ?*wm.Window = if (state.mouse.grab_window != 0)
            state.manager.get(state.mouse.grab_window)
        else if (chrome.overChrome(state, mx, my))
            null
        else
            state.manager.windowAt(mx, my);

        if (target) |win| {
            if (state.mouse.hover_window != win.id) {
                if (state.manager.get(state.mouse.hover_window)) |old| event(old, .mouse_leave, 0, 0, 0, 0, 0);
                event(win, .mouse_enter, 0, mx - win.content.x, my - win.content.y, 0, 0);
                state.mouse.hover_window = win.id;
            }
            switch (win.hitTest(mx, my)) {
                .content => |c| {
                    event(win, .mouse_move, state.keys.mods(), c.x, c.y, @intCast(state.mouse.buttons), 0);
                    shape = win.cursor;
                },
                .resize => |edge| shape = resizeCursor(edge),
                else => if (state.mouse.grab_window != 0) {
                    event(win, .mouse_move, state.keys.mods(), mx - win.content.x, my - win.content.y, @intCast(state.mouse.buttons), 0);
                },
            }
        } else if (state.mouse.hover_window != 0) {
            if (state.manager.get(state.mouse.hover_window)) |old| event(old, .mouse_leave, 0, 0, 0, 0, 0);
            state.mouse.hover_window = 0;
        }
        self.updateCursor(shape);
    }

    fn resizeCursor(e: wm.Edge) proto.Cursor {
        if ((e.left and e.top) or (e.right and e.bottom)) return .resize_nwse;
        if ((e.right and e.top) or (e.left and e.bottom)) return .resize_nesw;
        if (e.left or e.right) return .resize_ew;
        return .resize_ns;
    }

    pub fn focusWindow(self: *Input, win: *wm.Window) void {
        const state = self.s();
        if (win.layer == .popup or win.layer == .desktop) return;
        state.manager.raise(win.id);
        const prev = state.manager.focus(win.id);
        if (prev != win.id) {
            if (state.manager.get(prev)) |p| {
                event(p, .focus, 0, 0, 0, 0, 0);
                state.invalidate(p.paintBounds());
            }
            event(win, .focus, 0, 1, 0, 0, 0);
            state.invalidate(.{ .w = state.width, .h = wm.MENUBAR });
        }
        state.invalidate(win.paintBounds());
    }

    fn closePopups(self: *Input, except: u32) void {
        const state = self.s();
        for (state.manager.windows.items) |w| {
            if (w.layer == .popup and w.id != except and w.visible) {
                event(w, .close_request, 0, 0, 0, 0, 0);
            }
        }
    }

    fn buttonDown(self: *Input, button: i32) void {
        const state = self.s();
        const mx = state.mouse.x;
        const my = state.mouse.y;
        state.mouse.buttons |= @as(u32, 1) << @intCast(button - 1);

        // Click counting for double/triple clicks.
        if (state.now_ms - state.mouse.last_click_ms < 400) state.mouse.click_count += 1 else state.mouse.click_count = 1;
        state.mouse.last_click_ms = state.now_ms;

        if (state.menu.index >= 0) {
            if (!chrome.menuPanelContains(state, mx, my) and !chrome.menubarContains(state, mx, my)) {
                chrome.closeMenu(state);
                return;
            }
            if (chrome.menubarContains(state, mx, my)) {
                chrome.menubarClick(state, mx, my);
            }
            return;
        }
        if (state.switcher.active) return;

        if (state.session == .active) {
            if (chrome.menubarContains(state, mx, my)) {
                self.closePopups(0);
                chrome.menubarClick(state, mx, my);
                return;
            }
            if (chrome.dockClick(state, mx, my)) |id| {
                self.closePopups(0);
                self.activateOrLaunch(id);
                return;
            }
        }

        const win = state.manager.windowAt(mx, my) orelse {
            self.closePopups(0);
            return;
        };
        self.closePopups(win.id);
        if (win.layer != .popup) self.focusWindow(win);
        switch (win.hitTest(mx, my)) {
            .close => event(win, .close_request, 0, 0, 0, 0, 0),
            .minimize => {
                win.minimized = true;
                state.invalidate(win.paintBounds());
                state.manager.focusTopmost();
            },
            .zoom => self.zoom(win),
            .titlebar => {
                if (state.mouse.click_count == 2) {
                    self.zoom(win);
                } else {
                    state.manager.beginDrag(win, .move, .{}, mx, my);
                }
            },
            .resize => |edge| state.manager.beginDrag(win, .resize, edge, mx, my),
            .content => |c| {
                // Full-size-content windows: a press in the title area drags.
                if (!win.hasTitlebar() and win.hasControls() and c.y < win.title_height and button == 1 and state.keys.mods() & proto.Mods.cmd == 0) {
                    event(win, .mouse_down, state.keys.mods(), c.x, c.y, button, state.mouse.click_count);
                    state.mouse.grab_window = win.id;
                    return;
                }
                state.mouse.grab_window = win.id;
                event(win, .mouse_down, state.keys.mods(), c.x, c.y, button, state.mouse.click_count);
            },
            .none => {},
        }
    }

    fn buttonUp(self: *Input, button: i32) void {
        const state = self.s();
        state.mouse.buttons &= ~(@as(u32, 1) << @intCast(button - 1));
        if (state.manager.drag.kind != .none) {
            state.manager.endDrag();
            self.flushResize();
            return;
        }
        if (state.menu.index >= 0) {
            if (chrome.menuPanelContains(state, state.mouse.x, state.mouse.y)) {
                if (chrome.menuActivate(state)) |action| self.menuAction(action);
            }
            return;
        }
        if (state.manager.get(state.mouse.grab_window)) |win| {
            event(win, .mouse_up, state.keys.mods(), state.mouse.x - win.content.x, state.mouse.y - win.content.y, button, state.mouse.click_count);
        }
        if (state.mouse.buttons == 0) state.mouse.grab_window = 0;
    }

    fn scroll(self: *Input, dx: i32, dy: i32) void {
        const state = self.s();
        const win = state.manager.windowAt(state.mouse.x, state.mouse.y) orelse return;
        event(win, .scroll, state.keys.mods(), state.mouse.x - win.content.x, state.mouse.y - win.content.y, dx, dy);
    }

    fn zoom(self: *Input, win: *wm.Window) void {
        const state = self.s();
        state.invalidate(win.paintBounds());
        state.manager.toggleZoom(win);
        protocol.Protocol.resizeBuffer(win);
        event(win, .resize, 0, win.content.w, win.content.h, 0, 0);
        state.invalidate(win.paintBounds());
    }

    /// Deliver the deferred resize after interactive resizing.
    pub fn flushResize(self: *Input) void {
        if (self.pending_resize == 0) return;
        if (self.s().manager.get(self.pending_resize)) |win| {
            protocol.Protocol.resizeBuffer(win);
            event(win, .resize, 0, win.content.w, win.content.h, 0, 0);
            self.s().invalidate(win.paintBounds());
        }
        self.pending_resize = 0;
    }

    pub fn activateOrLaunch(self: *Input, id: []const u8) void {
        const state = self.s();
        // Activate the topmost window of a running app, restoring minimized ones.
        var best: ?*wm.Window = null;
        for (state.manager.order.items) |wid| {
            const w = state.manager.get(wid).?;
            if (std.mem.eql(u8, w.appId(), id) and w.layer == .normal) {
                if (w.minimized or !w.visible) {
                    w.minimized = false;
                    w.visible = true;
                }
                best = w;
            }
        }
        if (best) |w| {
            self.focusWindow(w);
            return;
        }
        self.actions.launch(state, id);
    }

    fn menuAction(self: *Input, action: chrome.MenuAction) void {
        const state = self.s();
        switch (action) {
            .app_item => |id| {
                if (state.manager.get(state.manager.focused)) |w| event(w, .menu, 0, @intCast(id), 0, 0, 0);
            },
            .about => self.actions.launch(state, "com.zen.Settings"),
            .settings => self.actions.launch(state, "com.zen.Settings"),
            .lock => self.actions.session(state, "lock"),
            .logout => self.actions.session(state, "logout"),
            .restart => self.actions.session(state, "restart"),
            .shutdown => self.actions.session(state, "shutdown"),
            .force_quit => self.quitFocused(),
            .toggle_appearance => {
                state.appearance.dark = !state.appearance.dark;
                chrome.broadcastAppearance(state);
            },
        }
    }

    fn quitFocused(self: *Input) void {
        const state = self.s();
        const focused = state.manager.get(state.manager.focused) orelse return;
        const pid = focused.owner_pid;
        for (state.manager.windows.items) |w| {
            if (w.owner_pid == pid) event(w, .quit_request, 0, 0, 0, 0, 0);
        }
    }

    fn hideApp(self: *Input) void {
        const state = self.s();
        const focused = state.manager.get(state.manager.focused) orelse return;
        const pid = focused.owner_pid;
        for (state.manager.windows.items) |w| {
            if (w.owner_pid == pid and w.layer == .normal) {
                w.visible = false;
                state.invalidate(w.paintBounds());
            }
        }
        state.manager.focusTopmost();
    }

    /// Match a key against the focused app's menu shortcuts.
    fn menuShortcut(self: *Input, ch: u8, mods: u32) bool {
        const state = self.s();
        const win = state.manager.get(state.manager.focused) orelse return false;
        var r = proto.MenuReader{ .buf = win.menu.items };
        const want = mods & (proto.Mods.cmd | proto.Mods.shift | proto.Mods.alt | proto.Mods.ctrl);
        while (r.next()) |e| {
            if (e.kind != .item or e.key == 0 or e.flags & proto.MenuItemFlags.disabled != 0) continue;
            var m: u32 = e.mods;
            if (m == 0) m = proto.Mods.cmd;
            if (std.ascii.isUpper(e.key)) m |= proto.Mods.shift;
            if (std.ascii.toLower(e.key) == std.ascii.toLower(ch) and m == want) {
                event(win, .menu, 0, @intCast(e.id), 0, 0, 0);
                chrome.flashMenuTitle(state, e.id);
                return true;
            }
        }
        return false;
    }

    fn key(self: *Input, code: u16, value: i32) void {
        const state = self.s();
        const pressed = value != 0;
        switch (code) {
            Key.leftshift, Key.rightshift => state.keys.shift = pressed,
            Key.leftctrl, Key.rightctrl => state.keys.ctrl = pressed,
            Key.leftalt, Key.rightalt => state.keys.alt = pressed,
            Key.leftmeta, Key.rightmeta => {
                state.keys.meta = pressed;
                if (!pressed and state.switcher.active) {
                    if (chrome.switcherCommit(state)) |id| self.activateOrLaunch(id);
                }
            },
            Key.capslock => if (value == 1) {
                state.keys.caps = !state.keys.caps;
            },
            else => {},
        }
        const mods = state.keys.mods();
        const is_mod = switch (code) {
            Key.leftshift, Key.rightshift, Key.leftctrl, Key.rightctrl, Key.leftalt, Key.rightalt, Key.leftmeta, Key.rightmeta, Key.capslock => true,
            else => false,
        };

        if (pressed and !is_mod) {
            // Keyboard layout toggle: Alt+Shift or Ctrl+Space.
            if ((state.keys.alt and state.keys.shift and !state.keys.meta) or (state.keys.ctrl and code == Key.space and !state.keys.meta)) {
                if (value == 1) {
                    state.keys.arabic = !state.keys.arabic;
                    state.invalidate(.{ .w = state.width, .h = wm.MENUBAR });
                }
                return;
            }
            if (state.menu.index >= 0 and code == Key.esc) {
                chrome.closeMenu(state);
                return;
            }
            if (state.session == .active and state.keys.meta) {
                if (code == Key.tab) {
                    chrome.switcherStep(state, state.keys.shift);
                    return;
                }
                if (state.switcher.active and code == Key.esc) {
                    chrome.switcherCancel(state);
                    return;
                }
                if (code == Key.q and state.keys.ctrl) {
                    if (value == 1) self.actions.session(state, "lock");
                    return;
                }
                if (code == Key.space) {
                    if (value == 1) self.actions.launch(state, "spotlight");
                    return;
                }
                const ch = inp.keyToChar(code, false, false, false);
                if (ch != 0 and ch < 128) {
                    if (self.menuShortcut(@intCast(ch), mods)) return;
                    switch (code) {
                        Key.q => {
                            if (value == 1) self.quitFocused();
                            return;
                        },
                        Key.h => {
                            if (value == 1) self.hideApp();
                            return;
                        },
                        Key.m => {
                            if (value == 1) {
                                if (state.manager.get(state.manager.focused)) |w| {
                                    w.minimized = true;
                                    state.invalidate(w.paintBounds());
                                    state.manager.focusTopmost();
                                }
                            }
                            return;
                        },
                        else => {},
                    }
                }
            }
        }

        const win = state.manager.get(state.manager.focused) orelse return;
        var e = proto.Event{ .kind = if (pressed) .key_down else .key_up, .mods = mods, .a = code, .b = if (value == 2) 1 else 0 };
        if (pressed and !state.keys.ctrl and !state.keys.meta) {
            const cp = inp.keyToChar(code, state.keys.shift, state.keys.caps, state.keys.arabic);
            if (cp != 0) {
                _ = std.unicode.utf8Encode(cp, &e.text) catch 0;
            }
        }
        win.pushEvent(e);
    }
};
