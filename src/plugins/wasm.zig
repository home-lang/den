//! Minimal WebAssembly plugin host.
//!
//! Den can load `.wasm` plugin modules and call their exported functions. This
//! is a from-scratch, dependency-free interpreter covering the core integer
//! instruction set, structured control flow (block/loop/if/br/br_if/return),
//! function calls, and linear-memory load/store — enough to run real compute
//! and string-processing plugins.
//!
//! Supported value types: i32, i64. Float types are parsed but not executed.
//! The interpreter is a tree-walking stack machine; control flow uses a signal
//! returned up the recursion so `br`/`return` stay correct without a manual
//! label stack.

const std = @import("std");

pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    Truncated,
    Malformed,
    Unsupported,
    Trap,
    StackUnderflow,
    OutOfMemory,
    ExportNotFound,
    TypeMismatch,
};

pub const ValType = enum(u8) { i32 = 0x7f, i64 = 0x7e, f32 = 0x7d, f64 = 0x7c, other = 0 };

pub const FuncType = struct {
    params: []ValType,
    results: []ValType,
};

pub const Func = struct {
    type_index: u32,
    locals: []ValType, // expanded local declarations (not counting params)
    code: []const u8, // instruction bytes (without the size prefix)
};

pub const ExportKind = enum(u8) { func = 0, table = 1, mem = 2, global = 3, other = 0xff };

pub const Export = struct {
    name: []const u8,
    kind: ExportKind,
    index: u32,
};

// ---------------------------------------------------------------------------
// LEB128 reader over a byte slice.
// ---------------------------------------------------------------------------

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *Reader) !u8 {
        if (self.pos >= self.bytes.len) return Error.Truncated;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    fn bytesN(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return Error.Truncated;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn uleb(self: *Reader) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.byte();
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
            if (shift >= 64) return Error.Malformed;
        }
        return result;
    }

    fn uleb32(self: *Reader) !u32 {
        return @intCast(try self.uleb());
    }

    fn sleb(self: *Reader, comptime T: type) !T {
        const bits = @typeInfo(T).int.bits;
        var result: i64 = 0;
        var shift: u6 = 0;
        var b: u8 = 0;
        while (true) {
            b = try self.byte();
            result |= @as(i64, b & 0x7f) << shift;
            shift += 7;
            if (b & 0x80 == 0) break;
            if (shift >= 64) return Error.Malformed;
        }
        if (shift < 64 and (b & 0x40) != 0) {
            result |= @as(i64, -1) << shift;
        }
        _ = bits;
        return @truncate(result);
    }
};

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

pub const Module = struct {
    allocator: std.mem.Allocator,
    types: []FuncType = &.{},
    funcs: []Func = &.{},
    exports: []Export = &.{},
    mem_min_pages: u32 = 0,
    num_imported_funcs: u32 = 0,

    pub fn deinit(self: *Module) void {
        const a = self.allocator;
        for (self.types) |t| {
            a.free(t.params);
            a.free(t.results);
        }
        a.free(self.types);
        for (self.funcs) |f| a.free(f.locals);
        a.free(self.funcs);
        for (self.exports) |e| a.free(e.name);
        a.free(self.exports);
    }

    /// Parse a WebAssembly binary module.
    pub fn parse(allocator: std.mem.Allocator, wasm: []const u8) !Module {
        var r = Reader{ .bytes = wasm };
        const magic = try r.bytesN(4);
        if (!std.mem.eql(u8, magic, "\x00asm")) return Error.BadMagic;
        const version = try r.bytesN(4);
        if (!std.mem.eql(u8, version, "\x01\x00\x00\x00")) return Error.UnsupportedVersion;

        var module = Module{ .allocator = allocator };
        errdefer module.deinit();

        while (r.pos < wasm.len) {
            const section_id = try r.byte();
            const section_len = try r.uleb32();
            const section_start = r.pos;
            const section_bytes = try r.bytesN(section_len);
            _ = section_start;

            switch (section_id) {
                1 => try module.parseTypes(section_bytes),
                2 => try module.parseImports(section_bytes),
                3 => try module.parseFunctions(section_bytes),
                5 => try module.parseMemory(section_bytes),
                7 => try module.parseExports(section_bytes),
                10 => try module.parseCode(section_bytes),
                else => {}, // skip custom/table/global/data/etc.
            }
        }
        return module;
    }

    fn parseTypes(self: *Module, bytes: []const u8) !void {
        var r = Reader{ .bytes = bytes };
        const count = try r.uleb32();
        var list = try self.allocator.alloc(FuncType, count);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |t| {
                self.allocator.free(t.params);
                self.allocator.free(t.results);
            }
            self.allocator.free(list);
        }
        for (0..count) |i| {
            const form = try r.byte();
            if (form != 0x60) return Error.Malformed; // func type
            const np = try r.uleb32();
            var params = try self.allocator.alloc(ValType, np);
            errdefer self.allocator.free(params);
            for (0..np) |k| params[k] = valType(try r.byte());
            const nr = try r.uleb32();
            var results = try self.allocator.alloc(ValType, nr);
            for (0..nr) |k| results[k] = valType(try r.byte());
            list[i] = .{ .params = params, .results = results };
            filled += 1;
        }
        self.types = list;
    }

    fn parseImports(self: *Module, bytes: []const u8) !void {
        var r = Reader{ .bytes = bytes };
        const count = try r.uleb32();
        var imported_funcs: u32 = 0;
        for (0..count) |_| {
            const mod_len = try r.uleb32();
            _ = try r.bytesN(mod_len);
            const name_len = try r.uleb32();
            _ = try r.bytesN(name_len);
            const kind = try r.byte();
            switch (kind) {
                0 => {
                    _ = try r.uleb32(); // type index
                    imported_funcs += 1;
                },
                1 => { // table: elemtype + limits
                    _ = try r.byte();
                    try skipLimits(&r);
                },
                2 => try skipLimits(&r), // memory
                3 => {
                    _ = try r.byte(); // valtype
                    _ = try r.byte(); // mutability
                },
                else => return Error.Malformed,
            }
        }
        self.num_imported_funcs = imported_funcs;
    }

    fn parseFunctions(self: *Module, bytes: []const u8) !void {
        var r = Reader{ .bytes = bytes };
        const count = try r.uleb32();
        var list = try self.allocator.alloc(Func, count);
        for (0..count) |i| {
            list[i] = .{ .type_index = try r.uleb32(), .locals = &.{}, .code = &.{} };
        }
        self.funcs = list;
    }

    fn parseMemory(self: *Module, bytes: []const u8) !void {
        var r = Reader{ .bytes = bytes };
        const count = try r.uleb32();
        if (count == 0) return;
        const flags = try r.byte();
        self.mem_min_pages = try r.uleb32();
        if (flags & 1 != 0) _ = try r.uleb32(); // max
    }

    fn parseExports(self: *Module, bytes: []const u8) !void {
        var r = Reader{ .bytes = bytes };
        const count = try r.uleb32();
        var list = try self.allocator.alloc(Export, count);
        var filled: usize = 0;
        errdefer {
            for (list[0..filled]) |e| self.allocator.free(e.name);
            self.allocator.free(list);
        }
        for (0..count) |i| {
            const name_len = try r.uleb32();
            const name = try self.allocator.dupe(u8, try r.bytesN(name_len));
            errdefer self.allocator.free(name);
            const kind: ExportKind = switch (try r.byte()) {
                0 => .func,
                1 => .table,
                2 => .mem,
                3 => .global,
                else => .other,
            };
            const index = try r.uleb32();
            list[i] = .{ .name = name, .kind = kind, .index = index };
            filled += 1;
        }
        self.exports = list;
    }

    fn parseCode(self: *Module, bytes: []const u8) !void {
        var r = Reader{ .bytes = bytes };
        const count = try r.uleb32();
        for (0..count) |i| {
            if (i >= self.funcs.len) return Error.Malformed;
            const body_len = try r.uleb32();
            const body = try r.bytesN(body_len);
            var br = Reader{ .bytes = body };
            const local_decls = try br.uleb32();
            var locals: std.ArrayList(ValType) = .empty;
            errdefer locals.deinit(self.allocator);
            for (0..local_decls) |_| {
                const n = try br.uleb32();
                const t = valType(try br.byte());
                for (0..n) |_| try locals.append(self.allocator, t);
            }
            self.funcs[i].locals = try locals.toOwnedSlice(self.allocator);
            self.funcs[i].code = body[br.pos..];
        }
    }

    pub fn findExport(self: *const Module, name: []const u8, kind: ExportKind) ?Export {
        for (self.exports) |e| {
            if (e.kind == kind and std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

fn valType(b: u8) ValType {
    return switch (b) {
        0x7f => .i32,
        0x7e => .i64,
        0x7d => .f32,
        0x7c => .f64,
        else => .other,
    };
}

fn skipLimits(r: *Reader) !void {
    const flags = try r.byte();
    _ = try r.uleb32();
    if (flags & 1 != 0) _ = try r.uleb32();
}

// ---------------------------------------------------------------------------
// Interpreter
// ---------------------------------------------------------------------------

const Signal = union(enum) {
    normal,
    branch: u32, // break out `n` enclosing blocks
    ret,
};

pub const Instance = struct {
    module: *const Module,
    allocator: std.mem.Allocator,
    memory: []u8,
    stack: std.ArrayList(i64),

    pub fn init(allocator: std.mem.Allocator, module: *const Module) !Instance {
        const mem = try allocator.alloc(u8, @as(usize, module.mem_min_pages) * 64 * 1024);
        @memset(mem, 0);
        return .{
            .module = module,
            .allocator = allocator,
            .memory = mem,
            .stack = .empty,
        };
    }

    pub fn deinit(self: *Instance) void {
        self.allocator.free(self.memory);
        self.stack.deinit(self.allocator);
    }

    fn push(self: *Instance, v: i64) !void {
        try self.stack.append(self.allocator, v);
    }
    fn pop(self: *Instance) !i64 {
        return self.stack.pop() orelse return Error.StackUnderflow;
    }

    /// Call an exported function by name with i64-typed arguments.
    pub fn callExport(self: *Instance, name: []const u8, args: []const i64) !?i64 {
        const exp = self.module.findExport(name, .func) orelse return Error.ExportNotFound;
        return self.callFunc(exp.index, args);
    }

    fn callFunc(self: *Instance, func_index: u32, args: []const i64) !?i64 {
        if (func_index < self.module.num_imported_funcs) return Error.Unsupported;
        const local_idx = func_index - self.module.num_imported_funcs;
        if (local_idx >= self.module.funcs.len) return Error.Malformed;
        const func = self.module.funcs[local_idx];
        const ftype = self.module.types[func.type_index];

        // Set up locals: params followed by declared locals (zeroed).
        const total_locals = ftype.params.len + func.locals.len;
        const locals = try self.allocator.alloc(i64, total_locals);
        defer self.allocator.free(locals);
        @memset(locals, 0);
        if (args.len != ftype.params.len) return Error.TypeMismatch;
        for (args, 0..) |a, i| locals[i] = a;

        const base = self.stack.items.len;
        const sig = try self.execBlock(func.code, locals, 0);
        _ = sig;

        // Return value: top of stack if the function has a result.
        if (ftype.results.len > 0) {
            const v = try self.pop();
            self.stack.shrinkRetainingCapacity(base);
            return v;
        }
        self.stack.shrinkRetainingCapacity(base);
        return null;
    }

    /// Execute an instruction sequence. `depth` is the current block nesting.
    fn execBlock(self: *Instance, code: []const u8, locals: []i64, depth: u32) Error!Signal {
        var r = Reader{ .bytes = code };
        while (r.pos < code.len) {
            const op = try r.byte();
            switch (op) {
                0x00 => return Error.Trap, // unreachable
                0x01 => {}, // nop
                0x0b => return .normal, // end of this (function-level) block
                0x02, 0x03 => { // block / loop
                    _ = try readBlockType(&r);
                    const is_loop = (op == 0x03);
                    const body = try sliceToEnd(&r);
                    while (true) {
                        const sig = try self.execBlock(body, locals, depth + 1);
                        switch (sig) {
                            .normal => break,
                            .ret => return .ret,
                            .branch => |n| {
                                if (n == 0) {
                                    if (is_loop) continue; // restart loop
                                    break; // exit block
                                } else return .{ .branch = n - 1 };
                            },
                        }
                    }
                },
                0x04 => { // if
                    _ = try readBlockType(&r);
                    const cond = try self.pop();
                    const then_body, const else_body = try sliceIfElse(&r);
                    const chosen = if (cond != 0) then_body else else_body;
                    const sig = try self.execBlock(chosen, locals, depth + 1);
                    switch (sig) {
                        .normal => {},
                        .ret => return .ret,
                        .branch => |n| {
                            if (n == 0) {} else return .{ .branch = n - 1 };
                        },
                    }
                },
                0x0c => return .{ .branch = try r.uleb32() }, // br
                0x0d => { // br_if
                    const n = try r.uleb32();
                    const c = try self.pop();
                    if (c != 0) return .{ .branch = n };
                },
                0x0f => return .ret, // return
                0x10 => { // call
                    const callee = try r.uleb32();
                    const cf_local = callee - self.module.num_imported_funcs;
                    if (cf_local >= self.module.funcs.len) return Error.Malformed;
                    const callee_type = self.module.types[self.module.funcs[cf_local].type_index];
                    const nargs = callee_type.params.len;
                    var call_args = try self.allocator.alloc(i64, nargs);
                    defer self.allocator.free(call_args);
                    var k = nargs;
                    while (k > 0) {
                        k -= 1;
                        call_args[k] = try self.pop();
                    }
                    const ret = try self.callFunc(callee, call_args);
                    if (ret) |v| try self.push(v);
                },
                0x1a => _ = try self.pop(), // drop
                0x1b => { // select
                    const c = try self.pop();
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(if (c != 0) a else b);
                },
                0x20 => try self.push(locals[try r.uleb32()]), // local.get
                0x21 => locals[try r.uleb32()] = try self.pop(), // local.set
                0x22 => { // local.tee
                    const v = try self.pop();
                    locals[try r.uleb32()] = v;
                    try self.push(v);
                },
                0x41 => try self.push(try r.sleb(i32)), // i32.const
                0x42 => try self.push(try r.sleb(i64)), // i64.const
                0x28 => { // i32.load
                    _ = try r.uleb32(); // align
                    const offset = try r.uleb32();
                    const addr: usize = @intCast(try self.pop());
                    try self.push(try self.load32(addr + offset));
                },
                0x2d => { // i32.load8_u
                    _ = try r.uleb32();
                    const offset = try r.uleb32();
                    const addr: usize = @intCast(try self.pop());
                    if (addr + offset >= self.memory.len) return Error.Trap;
                    try self.push(self.memory[addr + offset]);
                },
                0x36 => { // i32.store
                    _ = try r.uleb32();
                    const offset = try r.uleb32();
                    const val = try self.pop();
                    const addr: usize = @intCast(try self.pop());
                    try self.store32(addr + offset, @truncate(@as(u64, @bitCast(val))));
                },
                0x3a => { // i32.store8
                    _ = try r.uleb32();
                    const offset = try r.uleb32();
                    const val = try self.pop();
                    const addr: usize = @intCast(try self.pop());
                    if (addr + offset >= self.memory.len) return Error.Trap;
                    self.memory[addr + offset] = @truncate(@as(u64, @bitCast(val)));
                },
                0x45 => try self.push(if (try self.pop() == 0) 1 else 0), // i32.eqz
                else => try self.execNumeric(op),
            }
        }
        return .normal;
    }

    fn execNumeric(self: *Instance, op: u8) !void {
        // Binary i32 ops operate on the low 32 bits, results sign/zero handled.
        switch (op) {
            0x46 => try self.cmp(.eq),
            0x47 => try self.cmp(.ne),
            0x48 => try self.cmp(.lt_s),
            0x49 => try self.cmp(.lt_u),
            0x4a => try self.cmp(.gt_s),
            0x4b => try self.cmp(.gt_u),
            0x4c => try self.cmp(.le_s),
            0x4d => try self.cmp(.le_u),
            0x4e => try self.cmp(.ge_s),
            0x4f => try self.cmp(.ge_u),
            0x6a => try self.bin(.add),
            0x6b => try self.bin(.sub),
            0x6c => try self.bin(.mul),
            0x6d => try self.bin(.div_s),
            0x6e => try self.bin(.div_u),
            0x6f => try self.bin(.rem_s),
            0x70 => try self.bin(.rem_u),
            0x71 => try self.bin(.@"and"),
            0x72 => try self.bin(.@"or"),
            0x73 => try self.bin(.xor),
            0x74 => try self.bin(.shl),
            0x75 => try self.bin(.shr_s),
            0x76 => try self.bin(.shr_u),
            // i64 add/sub/mul reuse the same 64-bit math.
            0x7c => try self.bin(.add),
            0x7d => try self.bin(.sub),
            0x7e => try self.bin(.mul),
            else => return Error.Unsupported,
        }
    }

    const Cmp = enum { eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u };
    fn cmp(self: *Instance, c: Cmp) !void {
        const b: i32 = @truncate(try self.pop());
        const a: i32 = @truncate(try self.pop());
        const ua: u32 = @bitCast(a);
        const ub: u32 = @bitCast(b);
        const res: bool = switch (c) {
            .eq => a == b,
            .ne => a != b,
            .lt_s => a < b,
            .lt_u => ua < ub,
            .gt_s => a > b,
            .gt_u => ua > ub,
            .le_s => a <= b,
            .le_u => ua <= ub,
            .ge_s => a >= b,
            .ge_u => ua >= ub,
        };
        try self.push(if (res) 1 else 0);
    }

    const Bin = enum { add, sub, mul, div_s, div_u, rem_s, rem_u, @"and", @"or", xor, shl, shr_s, shr_u };
    fn bin(self: *Instance, op: Bin) !void {
        const b = try self.pop();
        const a = try self.pop();
        const res: i64 = switch (op) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
            .div_s => if (b == 0) return Error.Trap else @divTrunc(a, b),
            .div_u => if (b == 0) return Error.Trap else @bitCast(@as(u64, @bitCast(a)) / @as(u64, @bitCast(b))),
            .rem_s => if (b == 0) return Error.Trap else @rem(a, b),
            .rem_u => if (b == 0) return Error.Trap else @bitCast(@as(u64, @bitCast(a)) % @as(u64, @bitCast(b))),
            .@"and" => a & b,
            .@"or" => a | b,
            .xor => a ^ b,
            .shl => a << @intCast(@as(u6, @truncate(@as(u64, @bitCast(b))))),
            .shr_s => a >> @intCast(@as(u6, @truncate(@as(u64, @bitCast(b))))),
            .shr_u => @bitCast(@as(u64, @bitCast(a)) >> @intCast(@as(u6, @truncate(@as(u64, @bitCast(b)))))),
        };
        try self.push(res);
    }

    fn load32(self: *Instance, addr: usize) !i64 {
        if (addr + 4 > self.memory.len) return Error.Trap;
        const v = std.mem.readInt(u32, self.memory[addr..][0..4], .little);
        return @as(i32, @bitCast(v));
    }
    fn store32(self: *Instance, addr: usize, val: u32) !void {
        if (addr + 4 > self.memory.len) return Error.Trap;
        std.mem.writeInt(u32, self.memory[addr..][0..4], val, .little);
    }
};

/// Read (and discard) a blocktype: 0x40 (empty) or a single value type, or a
/// signed type index (we only need to skip it).
fn readBlockType(r: *Reader) !void {
    const b = try r.byte();
    if (b == 0x40 or b == 0x7f or b == 0x7e or b == 0x7d or b == 0x7c) return;
    // Otherwise it's an s33 type index; first byte already consumed, but it may
    // be multi-byte LEB. Back up and read as sleb.
    r.pos -= 1;
    _ = try r.sleb(i64);
}

/// Slice from the reader's current position up to (and consuming) the matching
/// `end` (0x0b), handling nested blocks. Returns the body excluding `end`.
fn sliceToEnd(r: *Reader) ![]const u8 {
    const start = r.pos;
    var nest: usize = 0;
    while (r.pos < r.bytes.len) {
        const op = try r.byte();
        if (op == 0x02 or op == 0x03 or op == 0x04) {
            nest += 1;
            try readBlockType(r);
        } else if (op == 0x0b) {
            if (nest == 0) return r.bytes[start .. r.pos - 1];
            nest -= 1;
        } else {
            try skipImmediates(r, op);
        }
    }
    return Error.Truncated;
}

/// Like sliceToEnd but splits an `if` body at the optional `else` (0x05).
fn sliceIfElse(r: *Reader) !struct { []const u8, []const u8 } {
    const start = r.pos;
    var nest: usize = 0;
    var else_pos: ?usize = null;
    while (r.pos < r.bytes.len) {
        const op_pos = r.pos;
        const op = try r.byte();
        if (op == 0x02 or op == 0x03 or op == 0x04) {
            nest += 1;
            try readBlockType(r);
        } else if (op == 0x05 and nest == 0) {
            else_pos = op_pos;
        } else if (op == 0x0b) {
            if (nest == 0) {
                const end_pos = r.pos - 1;
                if (else_pos) |ep| {
                    return .{ r.bytes[start..ep], r.bytes[ep + 1 .. end_pos] };
                }
                return .{ r.bytes[start..end_pos], r.bytes[end_pos..end_pos] };
            }
            nest -= 1;
        } else {
            try skipImmediates(r, op);
        }
    }
    return Error.Truncated;
}

/// Advance the reader past the immediate operands of instruction `op`.
fn skipImmediates(r: *Reader, op: u8) !void {
    switch (op) {
        // uleb immediate
        0x0c, 0x0d, 0x10, 0x20, 0x21, 0x22, 0x23, 0x24 => _ = try r.uleb32(),
        0x41 => _ = try r.sleb(i32), // i32.const
        0x42 => _ = try r.sleb(i64), // i64.const
        0x43 => _ = try r.bytesN(4), // f32.const
        0x44 => _ = try r.bytesN(8), // f64.const
        // memarg: align + offset
        0x28...0x3e => {
            _ = try r.uleb32();
            _ = try r.uleb32();
        },
        0x3f, 0x40 => _ = try r.byte(), // memory.size/grow reserved byte
        0x0e => { // br_table
            const n = try r.uleb32();
            for (0..n + 1) |_| _ = try r.uleb32();
        },
        else => {}, // no immediates
    }
}

// ---------------------------------------------------------------------------
// Tests — modules are hand-assembled to keep the test dependency-free.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Helper: build a single-function module exporting `name`.
/// type = (params i32...) -> i32, body = `code` (without trailing end here;
/// caller includes end). Builds the full binary.
fn buildModule(allocator: std.mem.Allocator, nparams: u8, body: []const u8, name: []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(allocator);
    try b.appendSlice(allocator, "\x00asm\x01\x00\x00\x00");

    // Type section (id 1): 1 type, func (nparams i32) -> (i32)
    var ts: std.ArrayList(u8) = .empty;
    defer ts.deinit(allocator);
    try ts.append(allocator, 1); // count
    try ts.append(allocator, 0x60);
    try ts.append(allocator, nparams);
    for (0..nparams) |_| try ts.append(allocator, 0x7f);
    try ts.append(allocator, 1); // 1 result
    try ts.append(allocator, 0x7f);
    try appendSection(allocator, &b, 1, ts.items);

    // Function section (id 3): 1 func of type 0
    try appendSection(allocator, &b, 3, &[_]u8{ 1, 0 });

    // Export section (id 7): export name -> func 0
    var es: std.ArrayList(u8) = .empty;
    defer es.deinit(allocator);
    try es.append(allocator, 1); // count
    try es.append(allocator, @intCast(name.len));
    try es.appendSlice(allocator, name);
    try es.append(allocator, 0); // func kind
    try es.append(allocator, 0); // index
    try appendSection(allocator, &b, 7, es.items);

    // Code section (id 10): 1 body: 0 local decls + code
    var cs: std.ArrayList(u8) = .empty;
    defer cs.deinit(allocator);
    try cs.append(allocator, 1); // count
    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(allocator);
    try body_buf.append(allocator, 0); // local decl count
    try body_buf.appendSlice(allocator, body);
    try cs.append(allocator, @intCast(body_buf.items.len));
    try cs.appendSlice(allocator, body_buf.items);
    try appendSection(allocator, &b, 10, cs.items);

    return b.toOwnedSlice(allocator);
}

fn appendSection(allocator: std.mem.Allocator, b: *std.ArrayList(u8), id: u8, contents: []const u8) !void {
    try b.append(allocator, id);
    try b.append(allocator, @intCast(contents.len));
    try b.appendSlice(allocator, contents);
}

test "wasm add function" {
    // body: local.get 0; local.get 1; i32.add; end
    const body = [_]u8{ 0x20, 0, 0x20, 1, 0x6a, 0x0b };
    const wasm = try buildModule(testing.allocator, 2, &body, "add");
    defer testing.allocator.free(wasm);

    var module = try Module.parse(testing.allocator, wasm);
    defer module.deinit();
    var inst = try Instance.init(testing.allocator, &module);
    defer inst.deinit();

    const r = try inst.callExport("add", &[_]i64{ 17, 25 });
    try testing.expectEqual(@as(i64, 42), r.?);
}

test "wasm loop sum 1..n" {
    // Computes sum(1..=n) using a loop with one local accumulator.
    // locals: param0 = n, local1 = acc, local2 = i
    // We hand-assemble with explicit locals, so build manually.
    const allocator = testing.allocator;
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(allocator);
    try b.appendSlice(allocator, "\x00asm\x01\x00\x00\x00");
    // type: (i32)->i32
    try appendSection(allocator, &b, 1, &[_]u8{ 1, 0x60, 1, 0x7f, 1, 0x7f });
    try appendSection(allocator, &b, 3, &[_]u8{ 1, 0 });
    var es: std.ArrayList(u8) = .empty;
    defer es.deinit(allocator);
    try es.appendSlice(allocator, &[_]u8{ 1, 3 });
    try es.appendSlice(allocator, "sum");
    try es.appendSlice(allocator, &[_]u8{ 0, 0 });
    try appendSection(allocator, &b, 7, es.items);

    // body with 1 local decl group: 2 i32 locals (acc=local1, i=local2)
    // acc=0 (init by zeroing). i starts at 1.
    // i32.const 1; local.set 2
    // loop:
    //   ; if i > n break
    //   local.get 2; local.get 0; i32.gt_s; br_if 1 (exit block)
    //   local.get 1; local.get 2; i32.add; local.set 1   (acc += i)
    //   local.get 2; i32.const 1; i32.add; local.set 2     (i += 1)
    //   br 0  (continue loop)
    // local.get 1 (return acc)
    const body = [_]u8{
        0x41, 1, 0x21, 2, // i = 1
        0x02, 0x40, // block
        0x03, 0x40, // loop
        0x20, 2, 0x20, 0, 0x4a, 0x0d, 1, // if i > n: br 1 (out of block)
        0x20, 1, 0x20, 2, 0x6a, 0x21, 1, // acc += i
        0x20, 2, 0x41, 1, 0x6a, 0x21, 2, // i += 1
        0x0c, 0, // br 0 (loop)
        0x0b, // end loop
        0x0b, // end block
        0x20, 1, // return acc
        0x0b, // end function
    };
    var cs: std.ArrayList(u8) = .empty;
    defer cs.deinit(allocator);
    try cs.append(allocator, 1);
    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(allocator);
    try body_buf.appendSlice(allocator, &[_]u8{ 1, 2, 0x7f }); // 1 decl group: 2 i32
    try body_buf.appendSlice(allocator, &body);
    try cs.append(allocator, @intCast(body_buf.items.len));
    try cs.appendSlice(allocator, body_buf.items);
    try appendSection(allocator, &b, 10, cs.items);

    var module = try Module.parse(allocator, b.items);
    defer module.deinit();
    var inst = try Instance.init(allocator, &module);
    defer inst.deinit();

    const r = try inst.callExport("sum", &[_]i64{10});
    try testing.expectEqual(@as(i64, 55), r.?); // 1+2+...+10
}

test "wasm rejects bad magic" {
    try testing.expectError(Error.BadMagic, Module.parse(testing.allocator, "nope"));
}
