#!/usr/bin/env python3
"""Smoke test for hosted Zen, speaking RFB (VNC) like a viewer would.

Start Zen first (`zig build run-hosted` or `zig-out/hosted/zen-hosted`), then:

    python3 hosted/smoke_test.py [--port 5900] [--save out.ppm]

Checks that the login screen is drawn, logs in as zen/zen and checks that
the desktop (menu bar, Dock, Finder) replaces it. Uses only the standard
library.
"""
import argparse
import socket
import struct
import sys
import time


def recvn(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed")
        buf += chunk
    return buf


def connect(port, timeout):
    deadline = time.time() + timeout
    while True:
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=10)
        except OSError:
            if time.time() > deadline:
                raise
            time.sleep(0.5)


def handshake(s):
    assert recvn(s, 12).startswith(b"RFB 003."), "not an RFB server"
    s.sendall(b"RFB 003.008\n")
    n = recvn(s, 1)[0]
    types = recvn(s, n)
    assert 1 in types, "security type None not offered"
    s.sendall(b"\x01")
    assert struct.unpack(">I", recvn(s, 4))[0] == 0, "security failed"
    s.sendall(b"\x01")
    w, h = struct.unpack(">HH", recvn(s, 4))
    recvn(s, 16)
    name = recvn(s, struct.unpack(">I", recvn(s, 4))[0])
    # Raw encoding only; native 32-bit pixel format (B, G, R, X).
    s.sendall(struct.pack(">BBHi", 2, 0, 1, 0))
    return w, h, name.decode()


def frame(s, w, h):
    """Request and return a full frame as bytes (BGRX)."""
    s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, w, h))
    fb = bytearray(w * h * 4)
    while True:
        t = recvn(s, 1)[0]
        if t == 0:
            break
        if t == 3:  # server cut text
            recvn(s, 3)
            recvn(s, struct.unpack(">I", recvn(s, 4))[0])
            continue
        raise AssertionError(f"unexpected message {t}")
    recvn(s, 1)
    n = struct.unpack(">H", recvn(s, 2))[0]
    for _ in range(n):
        x, y, rw, rh, enc = struct.unpack(">HHHHi", recvn(s, 12))
        if enc != 0:
            raise AssertionError(f"unexpected encoding {enc}")
        data = recvn(s, rw * rh * 4)
        for row in range(rh):
            o = ((y + row) * w + x) * 4
            fb[o : o + rw * 4] = data[row * rw * 4 : (row + 1) * rw * 4]
    return bytes(fb)


def distinct(fb, w, h, box):
    x0, y0, x1, y1 = box
    seen = set()
    for y in range(y0, y1, 3):
        for x in range(x0, x1, 3):
            o = (y * w + x) * 4
            seen.add(fb[o : o + 3])
    return len(seen)


def diff(a, b):
    changed = sum(1 for i in range(0, len(a), 4 * 97) if a[i : i + 3] != b[i : i + 3])
    return changed / (len(a) // (4 * 97))


def key(s, keysym, down):
    s.sendall(struct.pack(">BBHI", 4, 1 if down else 0, 0, keysym))


SHIFT = 0xFFE1
SHIFTED = set('~!@#$%^&*()_+{}|:"<>?ABCDEFGHIJKLMNOPQRSTUVWXYZ')


def type_text(s, text):
    for ch in text:
        if ch in SHIFTED:
            key(s, SHIFT, True)
        key(s, ord(ch), True)
        key(s, ord(ch), False)
        if ch in SHIFTED:
            key(s, SHIFT, False)
        time.sleep(0.03)


def chord(s, mod, keysym):
    key(s, mod, True)
    key(s, keysym, True)
    key(s, keysym, False)
    key(s, mod, False)


def click(s, x, y):
    s.sendall(struct.pack(">BBHH", 5, 0, x, y))
    s.sendall(struct.pack(">BBHH", 5, 1, x, y))
    time.sleep(0.05)
    s.sendall(struct.pack(">BBHH", 5, 0, x, y))


def save_ppm(path, fb, w, h):
    with open(path, "wb") as f:
        f.write(b"P6 %d %d 255\n" % (w, h))
        out = bytearray(w * h * 3)
        out[0::3] = fb[2::4]
        out[1::3] = fb[1::4]
        out[2::3] = fb[0::4]
        f.write(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5900)
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--save")
    ap.add_argument("--terminal-check", metavar="HOST_PATH",
                    help="also open Terminal via Spotlight, run a command that writes "
                         "/tmp/zen-smoke inside Zen, and wait for HOST_PATH to appear")
    args = ap.parse_args()

    s = connect(args.port, args.timeout)
    w, h, name = handshake(s)
    print(f"connected: {name} {w}x{h}")

    # The login window appears once the window server and loginwindow run.
    deadline = time.time() + args.timeout
    while True:
        login = frame(s, w, h)
        colours = distinct(login, w, h, (0, 0, w, h))
        if colours > 200:
            break
        if time.time() > deadline:
            raise AssertionError(f"login screen not drawn ({colours} colours)")
        time.sleep(0.5)
    print(f"login screen drawn ({colours} colours)")

    click(s, w // 2, int(h * 0.695))  # the password field
    type_text(s, "zen")
    key(s, 0xFF0D, True)
    key(s, 0xFF0D, False)

    deadline = time.time() + args.timeout
    while True:
        time.sleep(1)
        desk = frame(s, w, h)
        changed = diff(login, desk)
        if changed > 0.3:
            break
        if time.time() > deadline:
            raise AssertionError(f"desktop did not appear ({changed:.0%} of the screen changed)")
    print(f"logged in: {changed:.0%} of the screen changed")
    # The menu bar now has text; the Dock has icons.
    menubar = distinct(desk, w, h, (0, 0, w, 30))
    dock = distinct(desk, w, h, (w // 2 - 200, h - 80, w // 2 + 200, h - 10))
    print(f"menu bar colours {menubar}, Dock colours {dock}")
    assert menubar > 20, "menu bar looks empty"
    assert dock > 100, "Dock looks empty"
    if args.terminal_check:
        # Spotlight (Command-Space), open Terminal, run a shell command.
        chord(s, 0xFFEB, 0x20)
        time.sleep(0.8)
        type_text(s, "Terminal")
        time.sleep(0.5)
        key(s, 0xFF0D, True)
        key(s, 0xFF0D, False)
        time.sleep(3)
        type_text(s, 'echo "zen $(uname -s)" {1..3} > /tmp/zen-smoke')
        key(s, 0xFF0D, True)
        key(s, 0xFF0D, False)
        deadline = time.time() + args.timeout
        while True:
            try:
                with open(args.terminal_check) as f:
                    text = f.read().strip()
                if text:
                    break
            except OSError:
                pass
            if time.time() > deadline:
                raise AssertionError("Terminal did not run the command")
            time.sleep(0.5)
        print(f"Terminal ran a command: {text!r}")
        assert text.startswith("zen ") and text.endswith("1 2 3"), "unexpected command output"
        desk = frame(s, w, h)
    if args.save:
        save_ppm(args.save, desk, w, h)
    print("hosted smoke test passed")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError) as e:
        print(f"hosted smoke test FAILED: {e}", file=sys.stderr)
        sys.exit(1)
