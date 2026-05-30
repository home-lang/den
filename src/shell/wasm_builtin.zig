//! `wasm` builtin — load a WebAssembly plugin module and call an exported
//! function.
//!
//! Usage:
//!   wasm <module.wasm> <export> [int-args...]   call an exported function
//!   wasm --exports <module.wasm>                list exported functions
//!
//! Arguments and return values are integers (i32/i64). This is the user-facing
//! entry point to Den's WebAssembly plugin host (src/plugins/wasm.zig).

const std = @import("std");
const IO = @import("../utils/io.zig").IO;
const types = @import("../types/mod.zig");
const wasm = @import("../plugins/wasm.zig");

const Shell = @import("../shell.zig").Shell;

pub fn builtinWasm(self: *Shell, cmd: *types.ParsedCommand) !void {
    if (cmd.args.len == 0) {
        try IO.eprint("usage: wasm <module.wasm> <export> [int-args...]\n       wasm --exports <module.wasm>\n", .{});
        self.last_exit_code = 2;
        return;
    }

    const list_mode = std.mem.eql(u8, cmd.args[0], "--exports");
    const path_idx: usize = if (list_mode) 1 else 0;
    if (cmd.args.len <= path_idx) {
        try IO.eprint("wasm: missing module path\n", .{});
        self.last_exit_code = 2;
        return;
    }
    const path = cmd.args[path_idx];

    const bytes = readModule(self.allocator, path) catch {
        try IO.eprint("wasm: cannot read '{s}'\n", .{path});
        self.last_exit_code = 1;
        return;
    };
    defer self.allocator.free(bytes);

    var module = wasm.Module.parse(self.allocator, bytes) catch |err| {
        try IO.eprint("wasm: failed to parse '{s}': {s}\n", .{ path, @errorName(err) });
        self.last_exit_code = 1;
        return;
    };
    defer module.deinit();

    if (list_mode) {
        for (module.exports) |e| {
            if (e.kind == .func) try IO.print("{s}\n", .{e.name});
        }
        self.last_exit_code = 0;
        return;
    }

    if (cmd.args.len < 2) {
        try IO.eprint("wasm: missing export name\n", .{});
        self.last_exit_code = 2;
        return;
    }
    const export_name = cmd.args[1];

    // Parse remaining integer arguments.
    var args_buf: std.ArrayList(i64) = .empty;
    defer args_buf.deinit(self.allocator);
    for (cmd.args[2..]) |a| {
        const v = std.fmt.parseInt(i64, a, 10) catch {
            try IO.eprint("wasm: argument '{s}' is not an integer\n", .{a});
            self.last_exit_code = 2;
            return;
        };
        try args_buf.append(self.allocator, v);
    }

    var inst = wasm.Instance.init(self.allocator, &module) catch {
        try IO.eprint("wasm: out of memory instantiating module\n", .{});
        self.last_exit_code = 1;
        return;
    };
    defer inst.deinit();

    const result = inst.callExport(export_name, args_buf.items) catch |err| {
        try IO.eprint("wasm: calling '{s}': {s}\n", .{ export_name, @errorName(err) });
        self.last_exit_code = 1;
        return;
    };

    if (result) |v| {
        try IO.print("{d}\n", .{v});
    }
    self.last_exit_code = 0;
}

fn readModule(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Options.debug_io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return IO.readFileAlloc(allocator, file, 16 * 1024 * 1024);
}
