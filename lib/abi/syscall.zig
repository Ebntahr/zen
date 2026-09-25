//! Zen system call numbers.
//!
//! Zen implements the Linux riscv64 system-call ABI (numbers from the
//! asm-generic table: openat = 56, read = 63, …) so that static Zig and
//! musl C/C++ programs run unmodified. Zen-specific services live above
//! 500 and never collide with Linux numbers.

pub const zen_base: usize = 500;

pub const Zen = enum(usize) {
    /// (name_ptr, name_len, flags) → fd of the scheme server endpoint.
    scheme_register = 500,
    /// (phys_addr, len, flags) → user virtual address. Requires the
    /// `hardware` privilege (root, not sandboxed).
    physmap = 501,
    /// (len, *u64 out_phys) → user virtual address of zeroed, physically
    /// contiguous memory suitable for DMA.
    physalloc = 502,
    /// (virt_addr) → physical address.
    virt2phys = 503,
    /// (*const SpawnArgs) → pid.
    spawn = 504,
    /// (profile_ptr, profile_len) → 0. Irreversibly sandboxes the caller.
    sandbox_apply = 505,
    /// (pid, path_ptr, path_len, mode) → 0. Grants a sandboxed process
    /// access to one path (used by the trusted open/save panel).
    sandbox_grant = 506,
    /// (msg_ptr, msg_len) → 0. Appends to the kernel log.
    klog = 507,
    /// (pid, *ProcInfo out) → 0. Process information for Activity Monitor.
    proc_info = 508,
    /// (buf_ptr, max_count) → number of pids written (u32 each).
    proc_list = 509,
    /// (cmd) → does not return. 0 = power off, 1 = reboot.
    power = 510,
    /// (name_ptr, name_len) → 0. Set the kernel's human readable name for
    /// the calling process (shown in ps / Activity Monitor).
    set_name = 511,
    _,
};

/// Linux syscall numbers used directly by Zen user-space libraries.
pub const Linux = struct {
    pub const getcwd = 17;
    pub const dup = 23;
    pub const dup3 = 24;
    pub const fcntl = 25;
    pub const ioctl = 29;
    pub const mkdirat = 34;
    pub const unlinkat = 35;
    pub const symlinkat = 36;
    pub const linkat = 37;
    pub const renameat = 38;
    pub const ftruncate = 46;
    pub const faccessat = 48;
    pub const chdir = 49;
    pub const fchdir = 50;
    pub const fchmod = 52;
    pub const fchmodat = 53;
    pub const fchownat = 54;
    pub const fchown = 55;
    pub const openat = 56;
    pub const close = 57;
    pub const pipe2 = 59;
    pub const getdents64 = 61;
    pub const lseek = 62;
    pub const read = 63;
    pub const write = 64;
    pub const readv = 65;
    pub const writev = 66;
    pub const pread64 = 67;
    pub const pwrite64 = 68;
    pub const ppoll = 73;
    pub const readlinkat = 78;
    pub const newfstatat = 79;
    pub const fstat = 80;
    pub const fsync = 82;
    pub const utimensat = 88;
    pub const exit = 93;
    pub const exit_group = 94;
    pub const set_tid_address = 96;
    pub const futex = 98;
    pub const nanosleep = 101;
    pub const clock_gettime = 113;
    pub const sched_yield = 124;
    pub const kill = 129;
    pub const tgkill = 131;
    pub const rt_sigaction = 134;
    pub const rt_sigprocmask = 135;
    pub const rt_sigreturn = 139;
    pub const setpgid = 154;
    pub const getpgid = 155;
    pub const setsid = 157;
    pub const uname = 160;
    pub const getpid = 172;
    pub const getppid = 173;
    pub const getuid = 174;
    pub const geteuid = 175;
    pub const getgid = 176;
    pub const getegid = 177;
    pub const gettid = 178;
    pub const brk = 214;
    pub const munmap = 215;
    pub const clone = 220;
    pub const execve = 221;
    pub const mmap = 222;
    pub const mprotect = 226;
    pub const wait4 = 260;
    pub const getrandom = 278;
};

/// Argument block for `Zen.spawn`. All pointers are user addresses.
pub const SpawnArgs = extern struct {
    /// Executable path or URL (not NUL terminated).
    path: u64,
    path_len: u64,
    /// NULL-terminated array of NUL-terminated strings.
    argv: u64,
    envp: u64,
    /// `fds[i]` is the parent fd that becomes fd `i` in the child, or -1.
    fds: u64,
    nfds: u64,
    /// Working directory (0 = inherit).
    cwd: u64,
    cwd_len: u64,
    /// New credentials; -1 keeps the caller's. Changing them needs root.
    uid: i64 = -1,
    gid: i64 = -1,
    /// Optional sandbox profile (see sandbox.zig). Sandboxed callers may
    /// only spawn children that are at least as restricted.
    sandbox: u64 = 0,
    sandbox_len: u64 = 0,
    flags: u64 = 0,
    /// Process group for the child when `SPAWN_SETPGID` is set (0 = own).
    pgid: i64 = 0,
    /// Supplementary groups (u32 array) when `SPAWN_SETGROUPS` is set.
    groups: u64 = 0,
    ngroups: u64 = 0,
};

pub const SPAWN_SETSID: u64 = 1 << 0;
pub const SPAWN_SETPGID: u64 = 1 << 1;
pub const SPAWN_SETGROUPS: u64 = 1 << 2;
/// Ignore SIGINT/SIGQUIT in the child (for background services).
pub const SPAWN_DAEMON: u64 = 1 << 3;

pub const ProcState = enum(u32) { running = 0, sleeping = 1, stopped = 2, zombie = 3 };

/// Output of `Zen.proc_info`.
pub const ProcInfo = extern struct {
    pid: u32,
    ppid: u32,
    uid: u32,
    gid: u32,
    pgid: u32,
    sid: u32,
    state: ProcState,
    threads: u32,
    /// Resident memory in bytes.
    rss: u64,
    /// Virtual size in bytes.
    vsize: u64,
    /// CPU time consumed in nanoseconds.
    cpu_ns: u64,
    /// Monotonic start time in nanoseconds since boot.
    start_ns: u64,
    /// 1 if sandboxed.
    sandboxed: u32,
    nice: i32,
    name: [32]u8,
    exe: [128]u8,
};

/// Linux reboot(2) magic numbers (also accepted by Zen).
pub const LINUX_REBOOT_MAGIC1: usize = 0xfee1dead;
pub const LINUX_REBOOT_MAGIC2: usize = 672274793;
pub const LINUX_REBOOT_CMD_POWER_OFF: usize = 0x4321FEDC;
pub const LINUX_REBOOT_CMD_RESTART: usize = 0x01234567;
