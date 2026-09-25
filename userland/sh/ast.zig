//! Abstract syntax tree for the zensh command language.
const std = @import("std");

pub const Part = union(enum) {
    /// Unquoted literal text (subject to globbing, tilde expansion).
    lit: []const u8,
    /// Quoted literal text ('...', \x, literal text inside "...").
    qlit: []const u8,
    /// "..." – the inner parts are expanded in a quoted context.
    dq: []const Part,
    param: *const Param,
    /// $(...) or `...`
    cmdsub: *const Node,
    /// $(( ... ))
    arith: []const Part,
};

pub const Word = struct {
    parts: []const Part,

    pub const empty: Word = .{ .parts = &.{} };

    /// Returns the literal text if the word is a single unquoted literal.
    pub fn plainLit(self: Word) ?[]const u8 {
        if (self.parts.len != 1) return null;
        return switch (self.parts[0]) {
            .lit => |s| s,
            else => null,
        };
    }
};

pub const ParamOp = enum {
    none,
    length, // ${#x}
    default, // ${x-w} / ${x:-w}
    assign, // ${x=w} / ${x:=w}
    alt, // ${x+w} / ${x:+w}
    err, // ${x?w} / ${x:?w}
    rm_prefix, // #
    rm_prefix_long, // ##
    rm_suffix, // %
    rm_suffix_long, // %%
    sub, // /pat/rep
    sub_all, // //pat/rep
    sub_prefix, // /#pat/rep
    sub_suffix, // /%pat/rep
    substr, // :off:len
    upper_first, // ^
    upper_all, // ^^
    lower_first, // ,
    lower_all, // ,,
    bad, // unsupported syntax: "bad substitution" when expanded
};

pub const Param = struct {
    name: []const u8,
    op: ParamOp = .none,
    colon: bool = false,
    arg: ?Word = null,
    arg2: ?Word = null,
};

pub const RedirOp = enum {
    in, // <
    out, // >
    append, // >>
    clobber, // >|
    rdwr, // <>
    dup_in, // <&
    dup_out, // >&
    heredoc, // << and <<-
    herestring, // <<<
    out_err, // &>
    append_err, // &>>
};

pub const Heredoc = struct {
    delim: []const u8,
    strip_tabs: bool,
    expand: bool,
    body: Word = Word.empty,
};

pub const Redir = struct {
    /// Explicit descriptor, or -1 for the default of the operator.
    fd: i32,
    op: RedirOp,
    target: Word,
    here: ?*Heredoc = null,
};

pub const Assign = struct {
    name: []const u8,
    value: Word,
    append: bool = false,
};

pub const Simple = struct {
    assigns: []const Assign,
    words: []const Word,
    redirs: []const Redir,
    line: u32,
};

pub const Pipeline = struct {
    cmds: []const *const Node,
    bang: bool,
    /// `time` prefix: report elapsed and CPU time
    timed: bool = false,
    text: []const u8,
};

pub const AndOrOp = enum { and_, or_ };
pub const AndOrItem = struct { op: AndOrOp, node: *const Node };
pub const AndOr = struct {
    first: *const Node,
    rest: []const AndOrItem,
};

pub const ListItem = struct {
    node: *const Node,
    bg: bool,
    text: []const u8,
};
pub const List = struct { items: []const ListItem };

pub const If = struct {
    cond: *const Node,
    then: *const Node,
    else_: ?*const Node,
};

pub const Loop = struct {
    cond: *const Node,
    body: *const Node,
    until: bool,
};

pub const For = struct {
    name: []const u8,
    words: ?[]const Word,
    body: *const Node,
};

pub const CaseTerm = enum { brk, fallthrough, cont };
pub const CaseItem = struct {
    pats: []const Word,
    body: ?*const Node,
    term: CaseTerm,
};
pub const Case = struct {
    word: Word,
    items: []const CaseItem,
};

pub const FuncDef = struct {
    name: []const u8,
    body: *const Node,
    src: []const u8,
};

pub const Redirected = struct {
    body: *const Node,
    redirs: []const Redir,
};

pub const ArithCmd = struct {
    expr: Word,
    line: u32,
};

pub const Node = union(enum) {
    simple: Simple,
    pipeline: Pipeline,
    and_or: AndOr,
    list: List,
    subshell: *const Node,
    group: *const Node,
    redirected: Redirected,
    if_: If,
    loop: Loop,
    for_: For,
    case_: Case,
    func: FuncDef,
    arith: ArithCmd,
};
