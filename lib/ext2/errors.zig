//! Error set for all filesystem operations, mapping naturally to POSIX errno.

/// Every public filesystem operation returns (a subset of) this error set.
pub const Error = error{
    /// ENOENT: a path component or directory entry does not exist.
    NotFound,
    /// EEXIST: the target name already exists.
    Exists,
    /// ENOTDIR: a directory was expected.
    NotDir,
    /// EISDIR: the operation is not valid on a directory.
    IsDir,
    /// ENOTEMPTY: directory is not empty.
    NotEmpty,
    /// ENOSPC: no free blocks or inodes.
    NoSpace,
    /// ENAMETOOLONG: a name exceeds 255 bytes or a path/symlink is too long.
    NameTooLong,
    /// ELOOP: too many symbolic links while resolving a path.
    Loop,
    /// EINVAL: bad argument (e.g. renaming a directory into itself).
    InvalidArgument,
    /// EXDEV: operation across filesystems.
    CrossDevice,
    /// EROFS: filesystem mounted read-only.
    ReadOnly,
    /// EIO: the block device reported an error.
    Io,
    /// EUCLEAN: on-disk structures are inconsistent.
    Corrupt,
    /// EOPNOTSUPP: filesystem uses features this implementation lacks.
    Unsupported,
    /// EFBIG: file would exceed the maximum size.
    FileTooBig,
    /// EMLINK: link count limit reached.
    TooManyLinks,
    /// EPERM: operation not permitted (e.g. hard link to a directory).
    NotPermitted,
    /// EBUSY: object in use (e.g. removing the root directory).
    Busy,
    /// ENOMEM: allocator failure.
    OutOfMemory,
};

/// Linux errno value for an error (useful for the file server).
pub fn errno(err: Error) u16 {
    return switch (err) {
        error.NotPermitted => 1,
        error.NotFound => 2,
        error.Io => 5,
        error.OutOfMemory => 12,
        error.Busy => 16,
        error.Exists => 17,
        error.CrossDevice => 18,
        error.NotDir => 20,
        error.IsDir => 21,
        error.InvalidArgument => 22,
        error.FileTooBig => 27,
        error.NoSpace => 28,
        error.ReadOnly => 30,
        error.TooManyLinks => 31,
        error.NameTooLong => 36,
        error.NotEmpty => 39,
        error.Loop => 40,
        error.Unsupported => 95,
        error.Corrupt => 117,
    };
}
