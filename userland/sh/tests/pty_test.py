#!/usr/bin/env python3
"""Interactive tests for zensh: drives the shell through a pseudo-terminal,
emulating a small VT100 screen so that line editing, redraw and wrapping can
be checked.

usage: pty_test.py /path/to/zensh [-v] [-k name]
"""
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time
import traceback

VERBOSE = False


# ---------------------------------------------------------------------------
# a tiny terminal emulator
# ---------------------------------------------------------------------------

def char_width(ch):
    cp = ord(ch)
    if cp < 32:
        return 0
    if (0x1100 <= cp <= 0x115F or 0x2E80 <= cp <= 0xA4CF or 0xAC00 <= cp <= 0xD7A3
            or 0xF900 <= cp <= 0xFAFF or 0xFF00 <= cp <= 0xFF60 or 0x1F300 <= cp <= 0x1F64F
            or 0x1F900 <= cp <= 0x1F9FF):
        return 2
    return 1


class Screen:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[' '] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.pending_wrap = False
        self.buf = ''
        self.scrolled = []  # lines scrolled off the top

    def _scroll(self):
        self.scrolled.append(''.join(self.grid[0]).rstrip())
        self.grid.pop(0)
        self.grid.append([' '] * self.cols)

    def _newline(self):
        if self.r == self.rows - 1:
            self._scroll()
        else:
            self.r += 1

    def _put(self, ch):
        w = char_width(ch)
        if w == 0:
            return
        if self.pending_wrap or self.c + w > self.cols:
            self._newline()
            self.c = 0
            self.pending_wrap = False
        self.grid[self.r][self.c] = ch
        if w == 2 and self.c + 1 < self.cols:
            self.grid[self.r][self.c + 1] = ''
        if self.c + w >= self.cols:
            self.c = self.cols - 1
            self.pending_wrap = True
        else:
            self.c += w

    def feed(self, data):
        self.buf += data
        s = self.buf
        i = 0
        n = len(s)
        while i < n:
            ch = s[i]
            if ch == '\x1b':
                if i + 1 >= n:
                    break
                nx = s[i + 1]
                if nx == '[':
                    j = i + 2
                    while j < n and not ('\x40' <= s[j] <= '\x7e'):
                        j += 1
                    if j >= n:
                        break
                    self._csi(s[i + 2:j], s[j])
                    i = j + 1
                    continue
                if nx == ']':
                    j = s.find('\x07', i)
                    if j < 0:
                        break
                    i = j + 1
                    continue
                i += 2
                continue
            if ch == '\r':
                self.c = 0
                self.pending_wrap = False
            elif ch == '\n':
                self._newline()
                self.pending_wrap = False
            elif ch == '\b':
                if self.c > 0:
                    self.c -= 1
                self.pending_wrap = False
            elif ch == '\x07':
                pass
            elif ch == '\t':
                self.c = min(self.cols - 1, (self.c // 8 + 1) * 8)
            elif ord(ch) >= 32:
                self._put(ch)
            i += 1
        self.buf = s[i:]

    def _csi(self, params, final):
        priv = params.startswith('?')
        if priv:
            return
        parts = [p for p in params.split(';')]
        nums = [int(p) if p.isdigit() else 0 for p in parts] if params else []
        a = nums[0] if nums else 0
        if final == 'A':
            self.r = max(0, self.r - max(1, a))
        elif final == 'B':
            self.r = min(self.rows - 1, self.r + max(1, a))
        elif final == 'C':
            self.c = min(self.cols - 1, self.c + max(1, a))
        elif final == 'D':
            self.c = max(0, self.c - max(1, a))
        elif final in 'Hf':
            row = (nums[0] if len(nums) > 0 and nums[0] else 1) - 1
            col = (nums[1] if len(nums) > 1 and nums[1] else 1) - 1
            self.r, self.c = min(row, self.rows - 1), min(col, self.cols - 1)
        elif final == 'J':
            if a == 0:
                self.grid[self.r][self.c:] = [' '] * (self.cols - self.c)
                for rr in range(self.r + 1, self.rows):
                    self.grid[rr] = [' '] * self.cols
            elif a == 2:
                self.grid = [[' '] * self.cols for _ in range(self.rows)]
        elif final == 'K':
            if a == 0:
                self.grid[self.r][self.c:] = [' '] * (self.cols - self.c)
            elif a == 2:
                self.grid[self.r] = [' '] * self.cols
        # 'm' (colours) and everything else: ignored
        self.pending_wrap = False if final in 'ABCDHfJK' else self.pending_wrap

    def lines(self):
        return [''.join(row).rstrip() for row in self.grid]

    def text(self):
        return '\n'.join(self.scrolled + self.lines()).rstrip()

    def cursor_line(self):
        return ''.join(self.grid[self.r]).rstrip()


# ---------------------------------------------------------------------------
# driving the shell
# ---------------------------------------------------------------------------

class Term:
    def __init__(self, zensh, home, cwd, rows=24, cols=80, env=None, args=None):
        e = {
            'HOME': home,
            'PATH': '/usr/local/bin:/usr/bin:/bin',
            'TERM': 'xterm',
            'LC_ALL': 'C.UTF-8',
            'USER': 'zen',
            'PS1': '$ ',
        }
        if env:
            e.update(env)
        e = {k: v for k, v in e.items() if v is not None}
        argv = [zensh, '-i'] + (args or [])
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(cwd)
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
                os.execve(zensh, argv, e)
            finally:
                os._exit(127)
        self.pid, self.fd = pid, fd
        self.screen = Screen(rows, cols)
        self.raw = b''
        self.exited = None

    def pump(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return False
        try:
            data = os.read(self.fd, 65536)
        except OSError:
            data = b''
        if not data:
            self._reap()
            return False
        self.raw += data
        self.screen.feed(data.decode('utf-8', 'replace'))
        return True

    def _reap(self):
        if self.exited is None:
            try:
                p, st = os.waitpid(self.pid, 0)
                self.exited = os.waitstatus_to_exitcode(st)
            except ChildProcessError:
                self.exited = -1

    def settle(self, quiet=0.15, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            if not self.pump(quiet):
                return

    def send(self, s, settle=True):
        if isinstance(s, str):
            s = s.encode()
        os.write(self.fd, s)
        if settle:
            self.settle()

    def wait_for(self, pattern, timeout=5, raw=False):
        end = time.time() + timeout
        rx = re.compile(pattern, re.M)
        while True:
            hay = self.raw.decode('utf-8', 'replace') if raw else self.screen.text()
            if rx.search(hay):
                return True
            if time.time() > end or self.exited is not None:
                raise AssertionError('timeout waiting for %r\n--- screen ---\n%s' % (pattern, self.screen.text()))
            self.pump(0.05)

    def wait_exit(self, timeout=5):
        end = time.time() + timeout
        while self.exited is None and time.time() < end:
            if not self.pump(0.05):
                try:
                    p, st = os.waitpid(self.pid, os.WNOHANG)
                    if p:
                        self.exited = os.waitstatus_to_exitcode(st)
                except ChildProcessError:
                    self.exited = -1
        if self.exited is None:
            raise AssertionError('shell did not exit')
        return self.exited

    def close(self):
        if self.exited is None:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self._reap()
        try:
            os.close(self.fd)
        except OSError:
            pass

    def run(self, cmd):
        """Type a command, press Enter, wait for the next prompt."""
        marker = len(self.screen.text())
        self.send(cmd + '\r')
        return marker


UP, DOWN, RIGHT, LEFT = '\x1b[A', '\x1b[B', '\x1b[C', '\x1b[D'
HOME, END, DEL = '\x1b[H', '\x1b[F', '\x1b[3~'
C = lambda ch: chr(ord(ch.upper()) - 64)  # ctrl key
ALT = lambda ch: '\x1b' + ch


class Env:
    def __init__(self, zensh):
        self.zensh = zensh
        self.dir = tempfile.mkdtemp(prefix='zensh-pty.')
        self.home = os.path.join(self.dir, 'home')
        self.cwd = os.path.join(self.dir, 'work')
        os.makedirs(self.home)
        os.makedirs(self.cwd)
        self.terms = []

    def term(self, **kw):
        t = Term(self.zensh, self.home, self.cwd, **kw)
        self.terms.append(t)
        t.settle(0.3)
        return t

    def cleanup(self):
        for t in self.terms:
            t.close()
        shutil.rmtree(self.dir, ignore_errors=True)


def last_output_line(t):
    lines = [l for l in t.screen.text().split('\n')]
    # the line before the current prompt
    return lines


def assert_in(needle, hay, what='screen'):
    if needle not in hay:
        raise AssertionError('%r not found in %s:\n%s' % (needle, what, hay))


# ---------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------

def test_basic(env):
    t = env.term()
    t.wait_for(r'^\$$')
    t.run('echo hello world')
    t.wait_for(r'^hello world$')
    t.run('echo $((6*7))')
    t.wait_for(r'^42$')
    t.send(C('d'))
    assert t.wait_exit() == 0


def test_editing_keys(env):
    t = env.term()
    # Left + insert
    t.send('echo helo')
    t.send(LEFT)
    t.send('l\r')
    t.wait_for(r'^hello$')
    # Ctrl-A / Ctrl-E
    t.send('cho start')
    t.send(C('a') + 'e' + C('e') + '-end\r')
    t.wait_for(r'^start-end$')
    # Ctrl-K kills to end, Ctrl-Y yanks
    t.send('echo keep drop' + ALT('b') + C('k') + '\r')
    t.wait_for(r'^keep $', timeout=3) if False else t.wait_for(r'^keep$')
    # Ctrl-U kills to beginning
    t.send('garbage words' + C('u') + 'echo after-ctrl-u\r')
    t.wait_for(r'^after-ctrl-u$')
    # Ctrl-W kills previous word, Ctrl-Y yanks it back
    t.send('echo one two' + C('w') + C('w') + C('y') + ' 2\r')
    t.wait_for(r'^one two 2$')
    # Home/End/Delete
    t.send('xecho del' + HOME + DEL + END + 'eted\r')
    t.wait_for(r'^deleted$')
    # Alt-F / Alt-B word motion and Ctrl-T transpose
    t.send('echo ab' + C('t') + '\r')
    t.wait_for(r'^ba$')
    t.send('echo aaa bbb' + ALT('b') + ALT('b') + ALT('f') + 'X\r')
    t.wait_for(r'^aaaX bbb$')
    # Backspace
    t.send('echo typox\x7f\x7fo\r')
    t.wait_for(r'^typo$')
    # Unicode editing
    t.send('echo héllo❯' + LEFT + LEFT + '\x7f' + 'L\r')
    t.wait_for(r'^hélLo❯$')


def test_ctrl_c_and_status(env):
    t = env.term()
    t.send('echo should-not-run')
    t.send(C('c'))
    t.wait_for(r'should-not-run\^C')
    t.run('echo status=$?')
    t.wait_for(r'^status=130$')
    assert 'should-not-run\n' not in t.screen.text().replace('\r', '')


def test_history(env):
    t = env.term()
    t.run('echo first')
    t.run('echo second')
    t.run('true')
    t.send(UP + UP + '\r')
    t.wait_for(r'^second\n.*\n?second$|^second$')
    text = t.screen.text()
    assert text.count('second') >= 3, text
    # prefix search: "echo f" + Up -> "echo first"
    t.send('echo f' + UP + '\r')
    lines = t.screen.text().split('\n')
    assert lines.count('first') >= 2, t.screen.text()
    # Down returns to the edited line
    t.send('echo typed' + UP + DOWN + '\r')
    t.wait_for(r'^typed$')
    t.send(C('d'))
    t.wait_exit()
    # persistent history
    hist = open(os.path.join(env.home, '.zensh_history')).read()
    assert 'echo first\n' in hist and 'echo second\n' in hist, hist
    t2 = env.term()
    t2.send(UP)
    assert_in('echo typed', t2.screen.cursor_line())
    t2.send(C('u') + 'history\r')
    t2.wait_for(r'echo second')


def test_reverse_search(env):
    t = env.term()
    t.run('echo alpha')
    t.run('echo beta')
    t.run('echo gamma')
    t.send(C('r'))
    t.wait_for(r"reverse-i-search")
    t.send('alp')
    assert_in("`alp': echo alpha", t.screen.cursor_line())
    t.send('\r')
    t.wait_for(r'^alpha\n.*alpha$|^alpha$')
    lines = t.screen.text().split('\n')
    assert lines.count('alpha') == 2, t.screen.text()
    # Ctrl-R twice goes further back; Ctrl-G cancels
    t.send('echo keep' + C('r') + 'echo' + C('r') + C('g'))
    assert_in('echo keep', t.screen.cursor_line())
    t.send(C('u') + C('r') + 'gam' + C('e') + ' extra\r')
    t.wait_for(r'^gamma extra$')


def test_completion(env):
    os.makedirs(os.path.join(env.cwd, 'alpha_dir'))
    open(os.path.join(env.cwd, 'alpha_file.txt'), 'w').close()
    open(os.path.join(env.cwd, 'beta file.txt'), 'w').close()
    t = env.term()
    # unique command completion
    t.send('ech\t')
    t.send('|')
    assert_in('$ echo |', t.screen.cursor_line())
    t.send(C('u'))
    # common prefix then listing
    t.send('ls alp\t')
    assert_in('ls alpha_', t.screen.cursor_line())
    t.send('\t')
    t.wait_for(r'alpha_dir/\s+alpha_file\.txt')
    t.send('d\t')
    assert_in('ls alpha_dir/', t.screen.cursor_line())
    t.send(C('u'))
    # cd only completes directories
    t.send('cd alp\t|')
    assert_in('cd alpha_dir/|', t.screen.cursor_line())
    t.send(C('u'))
    # escaping of spaces
    t.send('cat bet\t|')
    assert_in('cat beta\\ file.txt |', t.screen.cursor_line())
    t.send(C('u'))
    # variables
    t.send('echo $HOM\t')
    assert_in('echo $HOME', t.screen.cursor_line())
    t.send('\r')
    t.wait_for(re.escape(env.home))
    # builtins and functions
    t.run('myfunction_zz() { echo fn; }')
    t.send('myfunc\t\r')
    t.wait_for(r'^fn$')


def test_multiline(env):
    t = env.term()
    t.send('if true; then\r')
    t.wait_for(r'^>$')
    t.send('echo inside\r')
    t.send('fi\r')
    t.wait_for(r'^inside$')
    t.send('echo "open\r')
    t.wait_for(r'^>$')
    t.send('quote"\r')
    t.wait_for(r'^quote$')
    t.send('cat <<EOF\r')
    t.send('heredoc line\r')
    t.send('EOF\r')
    t.wait_for(r'^heredoc line$')
    t.send('echo a \\\r')
    t.send('b\r')
    t.wait_for(r'^a b$')
    t.send('for i in 1 2; do\r')
    t.send(C('c'))
    t.run('echo after-cancel')
    t.wait_for(r'^after-cancel$')
    # a recalled multi-line entry is shown on several rows and re-executed
    t.run('if true; then\recho recalled\rfi')
    t.wait_for(r'^recalled$')
    t.send(UP)
    assert t.screen.cursor_line() == 'fi', t.screen.text()
    t.send('\r')
    lines = t.screen.text().split('\n')
    assert lines.count('recalled') == 2, t.screen.text()


def test_multiline_prompt(env):
    t = env.term(cols=40, env={'PS1': 'first line\\n\\u\\$ '})
    t.wait_for(r'^first line\nzen[$#]$')
    t.send('echo ' + 'w' * 50)
    t.send(C('a') + C('e') + '\r')
    out = t.screen.text()
    assert out.count('first line') == 2, out
    assert ('w' * 50) in out.replace('\n', ''), out


def test_read_builtin_tty(env):
    t = env.term()
    t.send('read -p "name? " n; echo "hi $n"\r')
    t.wait_for(r'^name\?$')
    t.send('zen\r')
    t.wait_for(r'^hi zen$')
    t.send('read -s pw; echo "len ${#pw}"\r')
    t.send('secret\r')
    t.wait_for(r'^len 6$')
    assert 'secret' not in t.screen.text()
    t.send('read -n 2 two; echo; echo "got $two"\r')
    t.send('ab')
    t.wait_for(r'^got ab$')


def test_exec_restores_terminal(env):
    t = env.term()
    t.run('stty -a | grep -o -- "-\\?icanon" | head -1')
    t.wait_for(r'^icanon$')
    t.send('exec sh -c "stty -a | grep -o -- -\\?icanon | head -1; exit 3"\r')
    t.wait_for(r'^icanon$')
    assert t.wait_exit() == 3


def test_wrapping(env):
    t = env.term(cols=30)
    long = 'echo ' + ''.join(chr(ord('a') + i % 26) for i in range(70))
    t.send(long)
    scr = t.screen.lines()
    # prompt + 75 chars over a 30 column screen: 3 rows
    joined = ''.join(l for l in scr if l)
    assert_in(long, joined, 'wrapped screen')
    # move to the start and insert: redraw must keep a single copy
    t.send(C('a') + RIGHT * 5 + 'X')
    t.send(C('e') + 'Z')
    txt = ''.join(t.screen.lines())
    assert txt.count('echo X') == 1, t.screen.text()
    t.send('\r')
    t.wait_for(r'Xabcdefghijklmnopqrstuvwxyzabc')
    out = t.screen.text().replace('\n', '')
    assert_in('XabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrZ', out)
    # exact-width line: prompt (2) + 28 chars fills the row
    t.send('echo ' + 'x' * 23)
    t.send(C('a') + C('e') + '\r')
    t.wait_for(r'^\$ echo x{23}\nx{23}$')
    # editing in the middle of a long line
    t.send('echo ' + 'y' * 40 + ' zz' + C('a') + ALT('f') + ALT('f') + C('k') + ' done\r')
    time.sleep(0.2)
    t.settle()
    out = t.screen.text().replace('\n', '')
    assert_in('y' * 40 + ' done$', out)


def test_jobs(env):
    t = env.term()
    t.send('sleep 30\r', settle=False)
    time.sleep(0.4)
    t.send(C('z'))
    t.wait_for(r'Stopped\s+sleep 30')
    t.run('jobs')
    t.wait_for(r'\[1\]\+\s+Stopped\s+sleep 30')
    t.send('bg\r')
    t.wait_for(r'\[1\]\+ sleep 30 &')
    t.run('jobs')
    t.wait_for(r'\[1\]\+\s+Running\s+sleep 30 &')
    t.send('fg\r', settle=False)
    t.wait_for(r'^sleep 30$')
    time.sleep(0.3)
    t.send(C('c'))
    t.run('echo fg-status=$?')
    t.wait_for(r'^fg-status=130$')
    t.run('sleep 0.2 &')
    t.wait_for(r'^\[1\] \d+$')
    time.sleep(0.5)
    t.run('')
    t.wait_for(r'\[1\]\+\s+Done\s+sleep 0\.2')
    t.run('sleep 30 &')
    t.run('kill %1')
    time.sleep(0.3)
    t.run('')
    t.wait_for(r'Terminated\s+sleep 30')
    # the foreground job gets the terminal; Ctrl-C kills only the job
    t.send('sleep 30; echo next\r', settle=False)
    time.sleep(0.4)
    t.send(C('c'))
    t.run('echo shell-alive')
    t.wait_for(r'^shell-alive$')
    assert '\nnext\n' not in t.screen.text() + '\n'
    # interactive shell ignores SIGINT / SIGTERM from outside
    os.kill(t.pid, signal.SIGINT)
    os.kill(t.pid, signal.SIGTERM)
    t.run('echo still-here')
    t.wait_for(r'^still-here$')
    # loops in the shell are interrupted by Ctrl-C
    t.send('while true; do :; done\r', settle=False)
    time.sleep(0.3)
    t.send(C('c'))
    t.run('echo loop-broken $?')
    t.wait_for(r'^loop-broken 130$')


def test_rc_and_prompt(env):
    with open(os.path.join(env.home, '.zenshrc'), 'w') as f:
        f.write("alias hi='echo from-rc'\nRCVAR=set\n")
    t = env.term(env={'PS1': None})
    # default prompt: user@host cwd ❯ with ~ for $HOME
    t.run('cd ~')
    t.wait_for(r'@\S+ ~ ❯$')
    t.run('hi')
    t.wait_for(r'^from-rc$')
    t.run('mkdir -p Documents && cd Documents')
    t.wait_for(r'~/Documents ❯$')
    raw = t.raw.decode('utf-8', 'replace')
    assert '\x1b[1;32m❯' in raw, 'prompt arrow should be green after success'
    t.run('false')
    raw = t.raw.decode('utf-8', 'replace')
    assert '\x1b[1;31m❯' in raw, 'prompt arrow should be red after failure'
    t.run('PS1="[\\u \\W]\\$ "')
    t.wait_for(r'^\[zen Documents\][$#]$')


def test_login_profile(env):
    with open(os.path.join(env.home, '.profile'), 'w') as f:
        f.write("echo profile-loaded\nexport FROM_PROFILE=yes\n")
    t = env.term(args=['-l'])
    t.wait_for(r'^profile-loaded$')
    t.run('echo $FROM_PROFILE')
    t.wait_for(r'^yes$')


def test_autosuggest_and_highlight(env):
    t = env.term()
    t.run('echo suggestion-test')
    t.send('echo sugg')
    raw = t.raw.decode('utf-8', 'replace')
    assert '\x1b[90mestion-test' in raw, 'grey autosuggestion expected'
    t.send(RIGHT + '\r')
    lines = t.screen.text().split('\n')
    assert lines.count('suggestion-test') == 2, t.screen.text()
    t.raw = b''
    t.send('nosuchcmd_zz')
    raw = t.raw.decode('utf-8', 'replace')
    assert '\x1b[31mnosuchcmd_zz' in raw, 'unknown command should be red'
    t.send(C('u') + 'echo')
    raw = t.raw.decode('utf-8', 'replace')
    assert '\x1b[32mecho' in raw, 'known command should be green'
    t.send(C('u') + 'nosuchcmd_zz\r')
    t.wait_for(r'nosuchcmd_zz: command not found')
    t.run('echo $?')
    t.wait_for(r'^127$')


def test_clear_screen(env):
    t = env.term()
    t.run('echo before-clear')
    t.send('echo typed' + C('l'))
    lines = t.screen.lines()
    assert lines[0] == '$ echo typed', lines
    t.send('\r')
    t.wait_for(r'^typed$')


def test_exit_and_status(env):
    t = env.term()
    t.run('exit 7')
    assert t.wait_exit() == 7


TESTS = [v for k, v in sorted(globals().items()) if k.startswith('test_')]


def main():
    global VERBOSE
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    zensh = os.path.abspath(args[0])
    only = None
    if '-v' in args:
        VERBOSE = True
    if '-k' in args:
        only = args[args.index('-k') + 1]
    failed = []
    passed = 0
    for fn in TESTS:
        name = fn.__name__
        if only and only not in name:
            continue
        env = Env(zensh)
        try:
            fn(env)
            passed += 1
            if VERBOSE:
                print('ok   ', name)
        except Exception as e:
            failed.append(name)
            print('FAIL: pty', name)
            print('   ', ''.join(traceback.format_exception_only(type(e), e)).strip().replace('\n', '\n    '))
        finally:
            env.cleanup()
    print('pty tests: %d passed, %d failed' % (passed, len(failed)))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
