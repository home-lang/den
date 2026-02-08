const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../types/mod.zig");
const IO = @import("../../utils/io.zig").IO;
const common = @import("common.zig");

/// macOS-specific and system utility builtins
/// Includes: copyssh, reloaddns, emptytrash, show, hide, dotfiles, library

/// copyssh - Copy SSH public key to clipboard
pub fn copyssh(_: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;

    // Get home directory
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: copyssh: HOME environment variable not set\n", .{});
        return 1;
    };

    // SSH key files to try (in order of preference)
    const key_files = [_][]const u8{
        "/.ssh/id_ed25519.pub",
        "/.ssh/id_rsa.pub",
        "/.ssh/id_ecdsa.pub",
        "/.ssh/id_dsa.pub",
    };

    var found_key: ?[]const u8 = null;
    var found_path: ?[]const u8 = null;
    var key_buffer: [8192]u8 = undefined;

    for (key_files) |key_suffix| {
        // Build full path
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, key_suffix }) catch continue;

        // Try to open and read the key file
        const file = std.Io.Dir.cwd().openFile(std.Options.debug_io,full_path, .{}) catch continue;
        defer file.close(std.Options.debug_io);

        const bytes_read = file.readStreaming(std.Options.debug_io, &.{&key_buffer}) catch continue;
        if (bytes_read > 0) {
            found_key = key_buffer[0..bytes_read];
            found_path = key_suffix;
            break;
        }
    }

    const key_content = found_key orelse {
        try IO.eprint("den: copyssh: no SSH public key found\n", .{});
        try IO.eprint("den: copyssh: try generating one with: ssh-keygen -t ed25519\n", .{});
        return 1;
    };

    // Remove trailing newline if present
    var trimmed_key = key_content;
    while (trimmed_key.len > 0 and (trimmed_key[trimmed_key.len - 1] == '\n' or trimmed_key[trimmed_key.len - 1] == '\r')) {
        trimmed_key = trimmed_key[0 .. trimmed_key.len - 1];
    }

    // Copy to clipboard using platform-specific command
    if (builtin.os.tag == .macos) {
        // Use pbcopy on macOS
        var child = std.process.spawn(std.Options.debug_io, .{
            .argv = &[_][]const u8{"pbcopy"},
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch {
            try IO.eprint("den: copyssh: failed to run pbcopy\n", .{});
            return 1;
        };

        if (child.stdin) |stdin| {
            stdin.writeStreamingAll(std.Options.debug_io, trimmed_key) catch {
                try IO.eprint("den: copyssh: failed to write to pbcopy\n", .{});
                return 1;
            };
            stdin.close(std.Options.debug_io);
            child.stdin = null;
        }

        _ = child.wait(std.Options.debug_io) catch {
            try IO.eprint("den: copyssh: pbcopy failed\n", .{});
            return 1;
        };

        try IO.print("SSH public key (~{s}) copied to clipboard\n", .{found_path.?});
    } else if (builtin.os.tag == .linux) {
        // Try xclip or xsel on Linux
        if (std.process.spawn(std.Options.debug_io, .{
            .argv = &[_][]const u8{ "xclip", "-selection", "clipboard" },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        })) |*child| {
            if (child.stdin) |stdin| {
                stdin.writeStreamingAll(std.Options.debug_io, trimmed_key) catch {};
                stdin.close(std.Options.debug_io);
                child.stdin = null;
            }
            _ = child.wait(std.Options.debug_io) catch {};
            try IO.print("SSH public key (~{s}) copied to clipboard\n", .{found_path.?});
        } else |_| {
            // Fallback: just print the key
            try IO.print("{s}\n", .{trimmed_key});
            try IO.eprint("den: copyssh: (xclip not found - key printed above)\n", .{});
        }
    } else {
        // Fallback: just print the key
        try IO.print("{s}\n", .{trimmed_key});
    }

    return 0;
}

/// reloaddns - Flush DNS cache (macOS only)
pub fn reloaddns(_: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;

    if (builtin.os.tag != .macos) {
        try IO.eprint("den: reloaddns: only supported on macOS\n", .{});
        return 1;
    }

    // Run dscacheutil -flushcache
    var flush_child = std.process.spawn(std.Options.debug_io, .{
        .argv = &[_][]const u8{ "dscacheutil", "-flushcache" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch {
        try IO.eprint("den: reloaddns: failed to run dscacheutil\n", .{});
        return 1;
    };

    const flush_result = flush_child.wait(std.Options.debug_io) catch {
        try IO.eprint("den: reloaddns: dscacheutil failed\n", .{});
        return 1;
    };

    if (flush_result.exited != 0) {
        try IO.eprint("den: reloaddns: dscacheutil returned error\n", .{});
        return 1;
    }

    // Run killall -HUP mDNSResponder
    var kill_child = std.process.spawn(std.Options.debug_io, .{
        .argv = &[_][]const u8{ "killall", "-HUP", "mDNSResponder" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch {
        try IO.eprint("den: reloaddns: failed to run killall\n", .{});
        return 1;
    };

    const kill_result = kill_child.wait(std.Options.debug_io) catch {
        try IO.eprint("den: reloaddns: killall failed\n", .{});
        return 1;
    };

    if (kill_result.exited != 0) {
        try IO.eprint("den: reloaddns: killall mDNSResponder returned error (may need sudo)\n", .{});
        return 1;
    }

    try IO.print("DNS cache flushed successfully\n", .{});
    return 0;
}

/// emptytrash - Empty the Trash (macOS only)
pub fn emptytrash(_: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    _ = command;

    if (builtin.os.tag != .macos) {
        try IO.eprint("den: emptytrash: only supported on macOS\n", .{});
        return 1;
    }

    // Use osascript to empty trash
    var child = std.process.spawn(std.Options.debug_io, .{
        .argv = &[_][]const u8{
            "osascript", "-e", "tell application \"Finder\" to empty trash",
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch {
        try IO.eprint("den: emptytrash: failed to run osascript\n", .{});
        return 1;
    };

    const result = child.wait(std.Options.debug_io) catch {
        try IO.eprint("den: emptytrash: osascript failed\n", .{});
        return 1;
    };

    if (result.exited != 0) {
        try IO.eprint("den: emptytrash: failed to empty trash\n", .{});
        return 1;
    }

    try IO.print("Trash emptied successfully\n", .{});
    return 0;
}

/// show - Remove hidden attribute from files (macOS)
pub fn show(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (builtin.os.tag != .macos) {
        try IO.eprint("den: show: only supported on macOS\n", .{});
        return 1;
    }

    if (command.args.len == 0) {
        try IO.eprint("den: show: usage: show <file>...\n", .{});
        return 1;
    }

    var exit_code: i32 = 0;
    for (command.args) |file| {
        // Execute: chflags nohidden <file>
        const file_z = try allocator.dupeZ(u8, file);
        defer allocator.free(file_z);

        const argv = [_]?[*:0]const u8{
            "chflags",
            "nohidden",
            file_z,
            null,
        };

        const fork_ret = std.c.fork();
        if (fork_ret < 0) return error.Unexpected;
        const pid: std.posix.pid_t = @intCast(fork_ret);
        if (pid == 0) {
            _ = common.c_exec.execvp("chflags", @ptrCast(&argv));
            std.c._exit(127);
        } else {
            var wait_status: c_int = 0;
            _ = std.c.waitpid(pid, &wait_status, 0);
            const code: i32 = @intCast(std.posix.W.EXITSTATUS(@as(u32, @bitCast(wait_status))));
            if (code != 0) {
                try IO.eprint("den: show: failed to show {s}\n", .{file});
                exit_code = code;
            }
        }
    }
    return exit_code;
}

/// hide - Set hidden attribute on files (macOS)
pub fn hide(allocator: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (builtin.os.tag != .macos) {
        try IO.eprint("den: hide: only supported on macOS\n", .{});
        return 1;
    }

    if (command.args.len == 0) {
        try IO.eprint("den: hide: usage: hide <file>...\n", .{});
        return 1;
    }

    var exit_code: i32 = 0;
    for (command.args) |file| {
        // Execute: chflags hidden <file>
        const file_z = try allocator.dupeZ(u8, file);
        defer allocator.free(file_z);

        const argv = [_]?[*:0]const u8{
            "chflags",
            "hidden",
            file_z,
            null,
        };

        const fork_ret2 = std.c.fork();
        if (fork_ret2 < 0) return error.Unexpected;
        const pid: std.posix.pid_t = @intCast(fork_ret2);
        if (pid == 0) {
            _ = common.c_exec.execvp("chflags", @ptrCast(&argv));
            std.c._exit(127);
        } else {
            var wait_status: c_int = 0;
            _ = std.c.waitpid(pid, &wait_status, 0);
            const code: i32 = @intCast(std.posix.W.EXITSTATUS(@as(u32, @bitCast(wait_status))));
            if (code != 0) {
                try IO.eprint("den: hide: failed to hide {s}\n", .{file});
                exit_code = code;
            }
        }
    }
    return exit_code;
}

/// dotfiles - Manage dotfiles
pub fn dotfiles(_: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.print("dotfiles - manage your dotfiles\n", .{});
        try IO.print("Usage: dotfiles <command> [args]\n", .{});
        try IO.print("\nCommands:\n", .{});
        try IO.print("  list              List tracked dotfiles\n", .{});
        try IO.print("  status            Show status of dotfiles\n", .{});
        try IO.print("  link <file>       Create symlink for dotfile\n", .{});
        try IO.print("  unlink <file>     Remove symlink\n", .{});
        try IO.print("  backup <file>     Backup a dotfile\n", .{});
        try IO.print("  restore <file>    Restore from backup\n", .{});
        try IO.print("  edit <file>       Edit a dotfile\n", .{});
        try IO.print("  diff <file>       Show diff with backup\n", .{});
        try IO.print("\nCommon dotfiles:\n", .{});
        try IO.print("  .bashrc, .zshrc, .vimrc, .gitconfig, .tmux.conf\n", .{});
        try IO.print("  .config/*, .ssh/config\n", .{});
        return 0;
    }

    const subcmd = command.args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        return try dotfilesList();
    } else if (std.mem.eql(u8, subcmd, "status")) {
        return try dotfilesStatus();
    } else if (std.mem.eql(u8, subcmd, "link")) {
        if (command.args.len < 2) {
            try IO.eprint("dotfiles link: missing file argument\n", .{});
            return 1;
        }
        return try dotfilesLink(command.args[1]);
    } else if (std.mem.eql(u8, subcmd, "unlink")) {
        if (command.args.len < 2) {
            try IO.eprint("dotfiles unlink: missing file argument\n", .{});
            return 1;
        }
        return try dotfilesUnlink(command.args[1]);
    } else if (std.mem.eql(u8, subcmd, "backup")) {
        if (command.args.len < 2) {
            try IO.eprint("dotfiles backup: missing file argument\n", .{});
            return 1;
        }
        return try dotfilesBackup(command.args[1]);
    } else if (std.mem.eql(u8, subcmd, "restore")) {
        if (command.args.len < 2) {
            try IO.eprint("dotfiles restore: missing file argument\n", .{});
            return 1;
        }
        return try dotfilesRestore(command.args[1]);
    } else if (std.mem.eql(u8, subcmd, "edit")) {
        if (command.args.len < 2) {
            try IO.eprint("dotfiles edit: missing file argument\n", .{});
            return 1;
        }
        return try dotfilesEdit(command.args[1]);
    } else if (std.mem.eql(u8, subcmd, "diff")) {
        if (command.args.len < 2) {
            try IO.eprint("dotfiles diff: missing file argument\n", .{});
            return 1;
        }
        return try dotfilesDiff(command.args[1]);
    } else {
        try IO.eprint("den: dotfiles: unknown command '{s}'\n", .{subcmd});
        return 1;
    }
}

/// library - Manage shell function libraries
pub fn library(_: std.mem.Allocator, command: *types.ParsedCommand) !i32 {
    if (command.args.len == 0) {
        try IO.print("library - manage shell function libraries\n", .{});
        try IO.print("Usage: library <command> [args]\n", .{});
        try IO.print("\nCommands:\n", .{});
        try IO.print("  list                  List available libraries\n", .{});
        try IO.print("  info <name>           Show library information\n", .{});
        try IO.print("  load <name|path>      Load a library\n", .{});
        try IO.print("  unload <name>         Unload a library\n", .{});
        try IO.print("  create <name>         Create a new library template\n", .{});
        try IO.print("  path                  Show library search paths\n", .{});
        try IO.print("\nLibrary locations:\n", .{});
        try IO.print("  ~/.config/den/lib/    User libraries\n", .{});
        try IO.print("  /usr/local/share/den/lib/  System libraries\n", .{});
        try IO.print("\nExamples:\n", .{});
        try IO.print("  library list\n", .{});
        try IO.print("  library load git-helpers\n", .{});
        try IO.print("  library create my-utils\n", .{});
        return 0;
    }

    const subcmd = command.args[0];

    if (std.mem.eql(u8, subcmd, "list")) {
        return try libraryList();
    } else if (std.mem.eql(u8, subcmd, "path")) {
        return try libraryPath();
    } else if (std.mem.eql(u8, subcmd, "info")) {
        if (command.args.len < 2) {
            try IO.eprint("den: library: info: missing library name\n", .{});
            return 1;
        }
        return try libraryInfo(command.args[1]);
    } else if (std.mem.eql(u8, subcmd, "load")) {
        if (command.args.len < 2) {
            try IO.eprint("den: library: load: missing library name\n", .{});
            return 1;
        }
        return try libraryLoad(command.args[1]);
    } else if (std.mem.eql(u8, subcmd, "unload")) {
        if (command.args.len < 2) {
            try IO.eprint("den: library: unload: missing library name\n", .{});
            return 1;
        }
        try IO.print("library unload: not yet implemented\n", .{});
        return 1;
    } else if (std.mem.eql(u8, subcmd, "create")) {
        if (command.args.len < 2) {
            try IO.eprint("den: library: create: missing library name\n", .{});
            return 1;
        }
        return try libraryCreate(command.args[1]);
    } else {
        try IO.eprint("den: library: unknown command '{s}'\n", .{subcmd});
        return 1;
    }
}

// ============ Library Helper Functions ============

fn libraryList() !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: library: HOME not set\n", .{});
        return 1;
    };

    try IO.print("\x1b[1;36m=== Shell Libraries ===\x1b[0m\n\n", .{});

    // Check user library directory
    var user_lib_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const user_lib_path = std.fmt.bufPrint(&user_lib_buf, "{s}/.config/den/lib", .{home}) catch return 1;

    try IO.print("\x1b[1;33mUser libraries:\x1b[0m {s}\n", .{user_lib_path});

    if (std.Io.Dir.cwd().openDir(std.Options.debug_io,user_lib_path, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(std.Options.debug_io);
        var iter = dir.iterate();
        var count: usize = 0;
        while (iter.next(std.Options.debug_io) catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".den") or
                std.mem.endsWith(u8, entry.name, ".sh"))
            {
                try IO.print("  \x1b[1;32m*\x1b[0m {s}\n", .{entry.name});
                count += 1;
            }
        }
        if (count == 0) {
            try IO.print("  \x1b[2m(none)\x1b[0m\n", .{});
        }
    } else |_| {
        try IO.print("  \x1b[2m(directory not found)\x1b[0m\n", .{});
    }

    // Check system library directory
    try IO.print("\n\x1b[1;33mSystem libraries:\x1b[0m /usr/local/share/den/lib\n", .{});

    if (std.Io.Dir.cwd().openDir(std.Options.debug_io,"/usr/local/share/den/lib", .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(std.Options.debug_io);
        var iter = dir.iterate();
        var count: usize = 0;
        while (iter.next(std.Options.debug_io) catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".den") or
                std.mem.endsWith(u8, entry.name, ".sh"))
            {
                try IO.print("  \x1b[1;32m*\x1b[0m {s}\n", .{entry.name});
                count += 1;
            }
        }
        if (count == 0) {
            try IO.print("  \x1b[2m(none)\x1b[0m\n", .{});
        }
    } else |_| {
        try IO.print("  \x1b[2m(directory not found)\x1b[0m\n", .{});
    }

    return 0;
}

fn libraryPath() !i32 {
    const home = common.getenv("HOME") orelse "";

    try IO.print("\x1b[1;36m=== Library Search Paths ===\x1b[0m\n\n", .{});

    var user_lib_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const user_lib_path = std.fmt.bufPrint(&user_lib_buf, "{s}/.config/den/lib", .{home}) catch "(error)";

    const paths = [_][]const u8{
        user_lib_path,
        "/usr/local/share/den/lib",
        "/usr/share/den/lib",
    };

    for (paths, 1..) |path, i| {
        const exists = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch null;
        const status = if (exists != null) "\x1b[1;32m+\x1b[0m" else "\x1b[2m-\x1b[0m";
        try IO.print("{s} {}. {s}\n", .{ status, i, path });
    }

    return 0;
}

fn libraryInfo(name: []const u8) !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: library: HOME not set\n", .{});
        return 1;
    };

    // Try to find the library
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    // Try user lib directory
    const user_path = std.fmt.bufPrint(&path_buf, "{s}/.config/den/lib/{s}.den", .{ home, name }) catch return 1;

    var lib_path: []const u8 = user_path;
    var file = std.Io.Dir.cwd().openFile(std.Options.debug_io,user_path, .{}) catch blk: {
        // Try with .sh extension
        const user_sh_path = std.fmt.bufPrint(&path_buf, "{s}/.config/den/lib/{s}.sh", .{ home, name }) catch return 1;
        lib_path = user_sh_path;
        break :blk std.Io.Dir.cwd().openFile(std.Options.debug_io,user_sh_path, .{}) catch {
            try IO.eprint("den: library: '{s}' not found\n", .{name});
            return 1;
        };
    };
    defer file.close(std.Options.debug_io);

    try IO.print("\x1b[1;36m=== Library: {s} ===\x1b[0m\n\n", .{name});
    try IO.print("\x1b[1;33mPath:\x1b[0m {s}\n", .{lib_path});

    const stat = file.stat(std.Options.debug_io) catch return 1;
    try IO.print("\x1b[1;33mSize:\x1b[0m {} bytes\n", .{stat.size});

    // Read and show header comments
    var buf: [4096]u8 = undefined;
    const n = file.readStreaming(std.Options.debug_io, &.{&buf}) catch 0;

    if (n > 0) {
        try IO.print("\n\x1b[1;33mDescription:\x1b[0m\n", .{});

        var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        var found_desc = false;
        while (lines.next()) |line| {
            if (line.len > 0 and line[0] == '#') {
                if (line.len > 2) {
                    try IO.print("  {s}\n", .{line[2..]});
                    found_desc = true;
                }
            } else if (found_desc) {
                break;
            }
        }

        if (!found_desc) {
            try IO.print("  \x1b[2m(no description)\x1b[0m\n", .{});
        }

        // Count functions
        try IO.print("\n\x1b[1;33mFunctions:\x1b[0m\n", .{});
        var func_count: usize = 0;
        var content_lines = std.mem.splitScalar(u8, buf[0..n], '\n');
        while (content_lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "function ") or
                (std.mem.indexOf(u8, line, "()") != null and !std.mem.startsWith(u8, line, "#")))
            {
                // Extract function name
                var func_name: []const u8 = "";
                if (std.mem.startsWith(u8, line, "function ")) {
                    const rest = line[9..];
                    if (std.mem.indexOf(u8, rest, " ")) |space_idx| {
                        func_name = rest[0..space_idx];
                    } else if (std.mem.indexOf(u8, rest, "(")) |paren_idx| {
                        func_name = rest[0..paren_idx];
                    }
                } else if (std.mem.indexOf(u8, line, "()")) |paren_idx| {
                    func_name = std.mem.trim(u8, line[0..paren_idx], " \t");
                }

                if (func_name.len > 0) {
                    try IO.print("  \x1b[1;32m*\x1b[0m {s}\n", .{func_name});
                    func_count += 1;
                }
            }
        }

        if (func_count == 0) {
            try IO.print("  \x1b[2m(no functions found)\x1b[0m\n", .{});
        }
    }

    return 0;
}

fn libraryLoad(name: []const u8) !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: library: HOME not set\n", .{});
        return 1;
    };

    // Try to find the library
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    // If it's an absolute path, use directly
    if (name[0] == '/') {
        _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, name, .{}) catch {
            try IO.eprint("den: library: '{s}' not found\n", .{name});
            return 1;
        };
        try IO.print("\x1b[1;32m+\x1b[0m Loading {s}\n", .{name});
        try IO.print("  \x1b[2mRun: source {s}\x1b[0m\n", .{name});
        return 0;
    }

    // Try user lib directory
    const extensions = [_][]const u8{ ".den", ".sh", "" };
    for (extensions) |ext| {
        const path = std.fmt.bufPrint(&path_buf, "{s}/.config/den/lib/{s}{s}", .{ home, name, ext }) catch continue;

        if (std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{})) |_| {
            try IO.print("\x1b[1;32m+\x1b[0m Found library: {s}\n", .{path});
            try IO.print("  \x1b[2mRun: source {s}\x1b[0m\n", .{path});
            return 0;
        } else |_| {}
    }

    // Try system lib directory
    for (extensions) |ext| {
        const path = std.fmt.bufPrint(&path_buf, "/usr/local/share/den/lib/{s}{s}", .{ name, ext }) catch continue;

        if (std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{})) |_| {
            try IO.print("\x1b[1;32m+\x1b[0m Found library: {s}\n", .{path});
            try IO.print("  \x1b[2mRun: source {s}\x1b[0m\n", .{path});
            return 0;
        } else |_| {}
    }

    try IO.eprint("den: library: '{s}' not found\n", .{name});
    try IO.eprint("den: library: try: library list\n", .{});
    return 1;
}

fn libraryCreate(name: []const u8) !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: library: HOME not set\n", .{});
        return 1;
    };

    // Create lib directory if needed
    var lib_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const lib_dir = std.fmt.bufPrint(&lib_dir_buf, "{s}/.config/den/lib", .{home}) catch return 1;

    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, lib_dir) catch |err| {
        try IO.eprint("den: library: cannot create directory: {}\n", .{err});
        return 1;
    };

    // Create library file
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.den", .{ lib_dir, name }) catch return 1;

    // Check if file exists
    if (std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{})) |_| {
        try IO.eprint("den: library: '{s}' already exists\n", .{path});
        return 1;
    } else |_| {}

    // Create template
    const template =
        \\# {s} - Den Shell Library
        \\# Description: Add your description here
        \\# Author: Your Name
        \\# Version: 1.0.0
        \\
        \\# Example function
        \\{s}_hello() {{
        \\    echo "Hello from {s} library!"
        \\}}
        \\
        \\# Add your functions below
        \\
    ;

    var content_buf: [2048]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf, template, .{ name, name, name }) catch return 1;

    const file = std.Io.Dir.cwd().createFile(std.Options.debug_io,path, .{}) catch |err| {
        try IO.eprint("den: library: cannot create file: {}\n", .{err});
        return 1;
    };
    defer file.close(std.Options.debug_io);

    _ = file.writeStreamingAll(std.Options.debug_io, content) catch |err| {
        try IO.eprint("den: library: cannot write file: {}\n", .{err});
        return 1;
    };

    try IO.print("\x1b[1;32m+\x1b[0m Created library: {s}\n", .{path});
    try IO.print("\nNext steps:\n", .{});
    try IO.print("  1. Edit: dotfiles edit {s}\n", .{path});
    try IO.print("  2. Load: source {s}\n", .{path});
    try IO.print("  3. Use:  {s}_hello\n", .{name});

    return 0;
}

// ============ Dotfiles Helper Functions ============

fn dotfilesList() !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: dotfiles: HOME not set\n", .{});
        return 1;
    };

    try IO.print("\x1b[1;36m=== Dotfiles ===\x1b[0m\n\n", .{});

    const dotfiles_list = [_][]const u8{
        ".bashrc",
        ".bash_profile",
        ".zshrc",
        ".zprofile",
        ".vimrc",
        ".gitconfig",
        ".gitignore_global",
        ".tmux.conf",
        ".inputrc",
        ".profile",
        ".denrc",
    };

    for (dotfiles_list) |dotfile| {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, dotfile }) catch continue;

        const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch {
            continue;
        };

        const kind_str = switch (stat.kind) {
            .sym_link => "\x1b[1;36m->\x1b[0m",
            .file => "\x1b[1;32m*\x1b[0m",
            else => " ",
        };

        const size_kb = stat.size / 1024;
        if (size_kb > 0) {
            try IO.print("{s} {s:<20} ({} KB)\n", .{ kind_str, dotfile, size_kb });
        } else {
            try IO.print("{s} {s:<20} ({} bytes)\n", .{ kind_str, dotfile, stat.size });
        }
    }

    // Check .config directory
    var config_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const config_path = std.fmt.bufPrint(&config_path_buf, "{s}/.config", .{home}) catch return 0;

    var dir = std.Io.Dir.cwd().openDir(std.Options.debug_io,config_path, .{ .iterate = true }) catch return 0;
    defer dir.close(std.Options.debug_io);

    try IO.print("\n\x1b[1;33m.config/\x1b[0m\n", .{});

    var iter = dir.iterate();
    var count: usize = 0;
    while (iter.next(std.Options.debug_io) catch null) |entry| {
        if (count >= 10) {
            try IO.print("  ... and more\n", .{});
            break;
        }
        const kind_str = switch (entry.kind) {
            .directory => "\x1b[1;34m[d]\x1b[0m",
            .file => "\x1b[1;32m[f]\x1b[0m",
            .sym_link => "\x1b[1;36m[l]\x1b[0m",
            else => "   ",
        };
        try IO.print("  {s} {s}\n", .{ kind_str, entry.name });
        count += 1;
    }

    return 0;
}

fn dotfilesStatus() !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: dotfiles: HOME not set\n", .{});
        return 1;
    };

    try IO.print("\x1b[1;36m=== Dotfiles Status ===\x1b[0m\n\n", .{});

    const dotfiles_list = [_][]const u8{
        ".bashrc",
        ".zshrc",
        ".vimrc",
        ".gitconfig",
        ".tmux.conf",
        ".denrc",
    };

    for (dotfiles_list) |dotfile| {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, dotfile }) catch continue;

        var backup_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const backup_path = std.fmt.bufPrint(&backup_buf, "{s}/{s}.bak", .{ home, dotfile }) catch continue;

        const exists = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch null;
        const backup_exists = std.Io.Dir.cwd().statFile(std.Options.debug_io, backup_path, .{}) catch null;

        if (exists != null) {
            const stat = exists.?;
            const is_symlink = stat.kind == .sym_link;

            if (is_symlink) {
                try IO.print("\x1b[1;36m[symlink]\x1b[0m {s}\n", .{dotfile});
            } else if (backup_exists != null) {
                try IO.print("\x1b[1;33m[modified]\x1b[0m {s} (backup exists)\n", .{dotfile});
            } else {
                try IO.print("\x1b[1;32m[ok]\x1b[0m      {s}\n", .{dotfile});
            }
        } else {
            try IO.print("\x1b[2m[missing]\x1b[0m {s}\n", .{dotfile});
        }
    }

    return 0;
}

fn dotfilesLink(file: []const u8) !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: dotfiles: HOME not set\n", .{});
        return 1;
    };

    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buf, "{s}/{s}", .{ home, file }) catch {
        try IO.eprint("den: dotfiles: path too long\n", .{});
        return 1;
    };

    // Check if source file exists
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, file, .{}) catch {
        try IO.eprint("dotfiles link: source file '{s}' not found\n", .{file});
        return 1;
    };

    // Check if target already exists
    if (std.Io.Dir.cwd().statFile(std.Options.debug_io, target, .{})) |_| {
        try IO.eprint("den: dotfiles: link: '{s}' already exists\n", .{target});
        try IO.eprint("den: dotfiles: use 'dotfiles backup {s}' first, then try again\n", .{file});
        return 1;
    } else |_| {}

    // Get absolute path to source
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = blk: {
        const result = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse {
            try IO.eprint("den: dotfiles: cannot get current directory\n", .{});
            return 1;
        };
        break :blk std.mem.sliceTo(@as([*:0]u8, @ptrCast(result)), 0);
    };

    var abs_source_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_source = std.fmt.bufPrint(&abs_source_buf, "{s}/{s}", .{ cwd, file }) catch {
        try IO.eprint("den: dotfiles: path too long\n", .{});
        return 1;
    };

    // Create symlink
    std.Io.Dir.symLinkAbsolute(std.Options.debug_io, abs_source, target, .{}) catch |err| {
        try IO.eprint("dotfiles link: failed to create symlink: {}\n", .{err});
        return 1;
    };

    try IO.print("\x1b[1;32m+\x1b[0m Linked {s} -> {s}\n", .{ target, abs_source });
    return 0;
}

fn dotfilesUnlink(file: []const u8) !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: dotfiles: HOME not set\n", .{});
        return 1;
    };

    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buf, "{s}/{s}", .{ home, file }) catch {
        try IO.eprint("den: dotfiles: path too long\n", .{});
        return 1;
    };

    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, target, .{}) catch {
        try IO.eprint("dotfiles unlink: '{s}' not found\n", .{target});
        return 1;
    };

    if (stat.kind != .sym_link) {
        try IO.eprint("dotfiles unlink: '{s}' is not a symlink\n", .{target});
        return 1;
    }

    std.Io.Dir.cwd().deleteFile(std.Options.debug_io,target) catch |err| {
        try IO.eprint("dotfiles unlink: failed to remove: {}\n", .{err});
        return 1;
    };

    try IO.print("\x1b[1;32m+\x1b[0m Unlinked {s}\n", .{target});
    return 0;
}

fn dotfilesBackup(file: []const u8) !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: dotfiles: HOME not set\n", .{});
        return 1;
    };

    var source_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var backup_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const source = if (file[0] == '/')
        file
    else blk: {
        const s = std.fmt.bufPrint(&source_buf, "{s}/{s}", .{ home, file }) catch {
            try IO.eprint("den: dotfiles: path too long\n", .{});
            return 1;
        };
        break :blk s;
    };

    const backup = std.fmt.bufPrint(&backup_buf, "{s}.bak", .{source}) catch {
        try IO.eprint("den: dotfiles: path too long\n", .{});
        return 1;
    };

    // Check if source exists
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, source, .{}) catch {
        try IO.eprint("dotfiles backup: '{s}' not found\n", .{source});
        return 1;
    };

    // Copy file
    std.Io.Dir.cwd().copyFile(source, std.Io.Dir.cwd(), backup, std.Options.debug_io, .{}) catch |err| {
        try IO.eprint("dotfiles backup: failed to copy: {}\n", .{err});
        return 1;
    };

    try IO.print("\x1b[1;32m+\x1b[0m Backed up {s} -> {s}\n", .{ source, backup });
    return 0;
}

fn dotfilesRestore(file: []const u8) !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: dotfiles: HOME not set\n", .{});
        return 1;
    };

    var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var backup_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const target = if (file[0] == '/')
        file
    else blk: {
        const t = std.fmt.bufPrint(&target_buf, "{s}/{s}", .{ home, file }) catch {
            try IO.eprint("den: dotfiles: path too long\n", .{});
            return 1;
        };
        break :blk t;
    };

    const backup = std.fmt.bufPrint(&backup_buf, "{s}.bak", .{target}) catch {
        try IO.eprint("den: dotfiles: path too long\n", .{});
        return 1;
    };

    // Check if backup exists
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, backup, .{}) catch {
        try IO.eprint("dotfiles restore: backup '{s}' not found\n", .{backup});
        return 1;
    };

    // Copy backup to original
    std.Io.Dir.cwd().copyFile(backup, std.Io.Dir.cwd(), target, std.Options.debug_io, .{}) catch |err| {
        try IO.eprint("dotfiles restore: failed to copy: {}\n", .{err});
        return 1;
    };

    try IO.print("\x1b[1;32m+\x1b[0m Restored {s} from {s}\n", .{ target, backup });
    return 0;
}

fn dotfilesEdit(file: []const u8) !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: dotfiles: HOME not set\n", .{});
        return 1;
    };

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = if (file[0] == '/' or file[0] == '.')
        file
    else blk: {
        const p = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, file }) catch {
            try IO.eprint("den: dotfiles: path too long\n", .{});
            return 1;
        };
        break :blk p;
    };

    // Get editor
    const editor = common.getenv("EDITOR") orelse common.getenv("VISUAL") orelse "vim";

    try IO.print("Opening {s} with {s}...\n", .{ path, editor });

    // Fork and exec editor
    const fork_ret3 = std.c.fork();
    if (fork_ret3 < 0) {
        try IO.eprint("dotfiles edit: failed to fork\n", .{});
        return 1;
    }
    const pid3: std.posix.pid_t = @intCast(fork_ret3);

    if (pid3 == 0) {
        // Child process
        var editor_buf: [256]u8 = undefined;
        const editor_z = std.fmt.bufPrintZ(&editor_buf, "{s}", .{editor}) catch std.c._exit(127);

        var path_z_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path}) catch std.c._exit(127);

        const argv = [_]?[*:0]const u8{ editor_z, path_z, null };
        _ = common.c_exec.execvp(editor_z, @ptrCast(&argv));
        std.c._exit(127);
    } else {
        // Parent process - wait for editor
        var wait_status3: c_int = 0;
        _ = std.c.waitpid(pid3, &wait_status3, 0);
        return @intCast(std.posix.W.EXITSTATUS(@as(u32, @bitCast(wait_status3))));
    }
}

fn dotfilesDiff(file: []const u8) !i32 {
    const home = common.getenv("HOME") orelse {
        try IO.eprint("den: dotfiles: HOME not set\n", .{});
        return 1;
    };

    var current_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var backup_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const current = if (file[0] == '/')
        file
    else blk: {
        const c = std.fmt.bufPrint(&current_buf, "{s}/{s}", .{ home, file }) catch {
            try IO.eprint("den: dotfiles: path too long\n", .{});
            return 1;
        };
        break :blk c;
    };

    const backup = std.fmt.bufPrint(&backup_buf, "{s}.bak", .{current}) catch {
        try IO.eprint("den: dotfiles: path too long\n", .{});
        return 1;
    };

    // Check both files exist
    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, current, .{}) catch {
        try IO.eprint("dotfiles diff: '{s}' not found\n", .{current});
        return 1;
    };

    _ = std.Io.Dir.cwd().statFile(std.Options.debug_io, backup, .{}) catch {
        try IO.eprint("dotfiles diff: backup '{s}' not found\n", .{backup});
        return 1;
    };

    // Fork and exec diff
    const fork_ret4 = std.c.fork();
    if (fork_ret4 < 0) {
        try IO.eprint("dotfiles diff: failed to fork\n", .{});
        return 1;
    }
    const pid4: std.posix.pid_t = @intCast(fork_ret4);

    if (pid4 == 0) {
        // Child process
        var backup_z_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const backup_z = std.fmt.bufPrintZ(&backup_z_buf, "{s}", .{backup}) catch std.c._exit(127);

        var current_z_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const current_z = std.fmt.bufPrintZ(&current_z_buf, "{s}", .{current}) catch std.c._exit(127);

        const argv = [_]?[*:0]const u8{ "diff", "-u", "--color=auto", backup_z, current_z, null };
        _ = common.c_exec.execvp("diff", @ptrCast(&argv));
        std.c._exit(127);
    } else {
        // Parent process - wait for diff
        var wait_status4: c_int = 0;
        _ = std.c.waitpid(pid4, &wait_status4, 0);
        const code = std.posix.W.EXITSTATUS(@as(u32, @bitCast(wait_status4)));
        // diff returns 0 if same, 1 if different, 2 if error
        if (code == 0) {
            try IO.print("\x1b[1;32m+\x1b[0m No differences\n", .{});
        }
        return @intCast(code);
    }
}
