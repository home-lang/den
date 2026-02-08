const std = @import("std");
const types = @import("../../types/mod.zig");
const Value = types.Value;
const IO = @import("../../utils/io.zig").IO;

/// Main path subcommand dispatcher
pub fn pathCmd(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.eprint("Usage: path <subcommand> [args...]\n  Subcommands: join, parse, split, type, exists, expand,\n    basename, dirname, extension\n", .{});
        return 1;
    }
    const subcmd = command.args[0];
    const rest_args = if (command.args.len > 1) command.args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcmd, "join")) return pathJoin(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "parse")) return pathParse(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "split")) return pathSplit(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "type")) return pathType(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "exists")) return pathExists(rest_args);
    if (std.mem.eql(u8, subcmd, "expand")) return pathExpand(allocator, rest_args);
    if (std.mem.eql(u8, subcmd, "basename")) return pathBasename(rest_args);
    if (std.mem.eql(u8, subcmd, "dirname")) return pathDirname(rest_args);
    if (std.mem.eql(u8, subcmd, "extension")) return pathExtension(rest_args);

    try IO.eprint("Unknown path subcommand: {s}\n", .{subcmd});
    return 1;
}

fn getPath(args: []const []const u8) []const u8 {
    if (args.len > 0) return args[0];
    return ".";
}

fn pathJoin(_: std.mem.Allocator, args: []const []const u8) !i32 {
    if (args.len == 0) {
        try IO.eprint("Usage: path join <part1> [part2] [...]\n", .{});
        return 1;
    }
    if (args.len == 1) {
        try IO.print("{s}\n", .{args[0]});
        return 0;
    }
    // Simple join with separator
    var first = true;
    for (args) |part| {
        if (!first) try IO.print("/", .{});
        first = false;
        // Strip trailing slash
        const trimmed = std.mem.trimEnd(u8, part, "/");
        try IO.print("{s}", .{trimmed});
    }
    try IO.print("\n", .{});
    return 0;
}

fn pathParse(allocator: std.mem.Allocator, args: []const []const u8) !i32 {
    const p = getPath(args);

    // Extract components
    const basename_val = std.fs.path.basename(p);
    const dirname_val = std.fs.path.dirname(p) orelse ".";
    const ext = std.fs.path.extension(p);
    const stem = if (ext.len > 0 and basename_val.len > ext.len)
        basename_val[0 .. basename_val.len - ext.len]
    else
        basename_val;
    const ext_no_dot = if (ext.len > 0 and ext[0] == '.') ext[1..] else ext;

    // Output as record format
    const keys = try allocator.alloc([]const u8, 4);
    keys[0] = try allocator.dupe(u8, "stem");
    keys[1] = try allocator.dupe(u8, "extension");
    keys[2] = try allocator.dupe(u8, "parent");
    keys[3] = try allocator.dupe(u8, "name");

    const values = try allocator.alloc(Value, 4);
    values[0] = .{ .string = try allocator.dupe(u8, stem) };
    values[1] = .{ .string = try allocator.dupe(u8, ext_no_dot) };
    values[2] = .{ .string = try allocator.dupe(u8, dirname_val) };
    values[3] = .{ .string = try allocator.dupe(u8, basename_val) };

    var record = Value{ .record = .{ .keys = keys, .values = values } };
    defer record.deinit(allocator);

    const output = try record.asString(allocator);
    defer allocator.free(output);
    try IO.print("{s}\n", .{output});
    return 0;
}

fn pathSplit(_: std.mem.Allocator, args: []const []const u8) !i32 {
    const p = getPath(args);
    var it = std.mem.splitScalar(u8, p, std.fs.path.sep);
    while (it.next()) |component| {
        if (component.len > 0) {
            try IO.print("{s}\n", .{component});
        }
    }
    return 0;
}

fn pathType(_: std.mem.Allocator, args: []const []const u8) !i32 {
    const p = getPath(args);
    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, p, .{}) catch {
        try IO.print("not found\n", .{});
        return 1;
    };
    const kind_str = switch (stat.kind) {
        .file => "file",
        .directory => "dir",
        .sym_link => "symlink",
        else => "other",
    };
    try IO.print("{s}\n", .{kind_str});
    return 0;
}

fn pathExists(args: []const []const u8) !i32 {
    const p = getPath(args);
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, p, .{}) catch {
        try IO.print("false\n", .{});
        return 1;
    };
    try IO.print("true\n", .{});
    return 0;
}

fn pathExpand(_: std.mem.Allocator, args: []const []const u8) !i32 {
    const p = getPath(args);
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved_len = std.Io.Dir.cwd().realPathFile(std.Options.debug_io, p, &buf) catch {
        try IO.print("{s}\n", .{p});
        return 0;
    };
    try IO.print("{s}\n", .{buf[0..resolved_len]});
    return 0;
}

fn pathBasename(args: []const []const u8) !i32 {
    const p = getPath(args);
    try IO.print("{s}\n", .{std.fs.path.basename(p)});
    return 0;
}

fn pathDirname(args: []const []const u8) !i32 {
    const p = getPath(args);
    try IO.print("{s}\n", .{std.fs.path.dirname(p) orelse "."});
    return 0;
}

fn pathExtension(args: []const []const u8) !i32 {
    const p = getPath(args);
    const ext = std.fs.path.extension(p);
    if (ext.len > 0 and ext[0] == '.') {
        try IO.print("{s}\n", .{ext[1..]});
    } else {
        try IO.print("{s}\n", .{ext});
    }
    return 0;
}
