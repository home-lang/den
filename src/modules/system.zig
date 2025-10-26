const std = @import("std");
const types = @import("types.zig");
const builtin = @import("builtin");

const ModuleInfo = types.ModuleInfo;

/// Get battery status on macOS
fn getMacOSBattery(allocator: std.mem.Allocator) !?types.BatteryInfo {
    var child = std.process.Child.init(&[_][]const u8{ "pmset", "-g", "batt" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    const output = child.stdout.?.readToEndAlloc(allocator, 4096) catch return null;
    defer allocator.free(output);

    const status = child.wait() catch return null;
    if (status != .Exited or status.Exited != 0) return null;

    // Parse output like: "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234567) 95%; discharging; 5:23 remaining present: true"
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        // Look for percentage
        if (std.mem.indexOf(u8, line, "%")) |pct_pos| {
            // Find start of percentage number
            var start = pct_pos;
            while (start > 0 and std.ascii.isDigit(line[start - 1])) : (start -= 1) {}

            const pct_str = line[start..pct_pos];
            const percentage = std.fmt.parseInt(u8, pct_str, 10) catch continue;

            // Determine charging status
            const is_charging = std.mem.indexOf(u8, line, "charging") != null and
                std.mem.indexOf(u8, line, "discharging") == null;

            return types.BatteryInfo{
                .percentage = percentage,
                .is_charging = is_charging,
            };
        }
    }

    return null;
}

/// Get battery status on Linux
fn getLinuxBattery(allocator: std.mem.Allocator) !?types.BatteryInfo {
    // Try /sys/class/power_supply/BAT0/
    const capacity_path = "/sys/class/power_supply/BAT0/capacity";
    const status_path = "/sys/class/power_supply/BAT0/status";

    const capacity_file = std.fs.openFileAbsolute(capacity_path, .{}) catch return null;
    defer capacity_file.close();

    var buf: [16]u8 = undefined;
    const capacity_size = capacity_file.readAll(&buf) catch return null;
    const capacity_str = std.mem.trim(u8, buf[0..capacity_size], &std.ascii.whitespace);
    const percentage = std.fmt.parseInt(u8, capacity_str, 10) catch return null;

    const status_file = std.fs.openFileAbsolute(status_path, .{}) catch return null;
    defer status_file.close();

    const status_size = status_file.readAll(&buf) catch return null;
    const status_str = std.mem.trim(u8, buf[0..status_size], &std.ascii.whitespace);
    const is_charging = std.mem.eql(u8, status_str, "Charging");

    _ = allocator;
    return types.BatteryInfo{
        .percentage = percentage,
        .is_charging = is_charging,
    };
}

/// Detect battery module
pub fn detectBattery(allocator: std.mem.Allocator, _: []const u8) !?ModuleInfo {
    const battery = switch (builtin.os.tag) {
        .macos => try getMacOSBattery(allocator),
        .linux => try getLinuxBattery(allocator),
        else => null,
    } orelse return null;

    var info = ModuleInfo.init("battery");
    info.version = try std.fmt.allocPrint(allocator, "{d}%", .{battery.percentage});

    // Icon based on percentage and charging status
    if (battery.is_charging) {
        info.icon = "🔌";
    } else if (battery.percentage >= 80) {
        info.icon = "🔋";
    } else if (battery.percentage >= 50) {
        info.icon = "🔋";
    } else if (battery.percentage >= 20) {
        info.icon = "🪫";
    } else {
        info.icon = "🪫";
    }

    info.color = if (battery.percentage < 20) "#ff0000" else if (battery.percentage < 50) "#ffaa00" else "#00ff00";

    return info;
}

/// Get memory usage
fn getMemoryUsage(allocator: std.mem.Allocator) !?types.MemoryInfo {
    switch (builtin.os.tag) {
        .macos => {
            var child = std.process.Child.init(&[_][]const u8{ "vm_stat" }, allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Ignore;

            child.spawn() catch return null;

            const output = child.stdout.?.readToEndAlloc(allocator, 8192) catch return null;
            defer allocator.free(output);

            _ = child.wait() catch return null;

            // Parse vm_stat output to calculate memory usage
            // This is simplified - real implementation would parse pages free, active, inactive, etc.
            var free_pages: u64 = 0;
            var active_pages: u64 = 0;
            var inactive_pages: u64 = 0;

            var lines = std.mem.splitScalar(u8, output, '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, "Pages free:")) |_| {
                    if (std.mem.lastIndexOfScalar(u8, line, ' ')) |space_pos| {
                        const num_str = std.mem.trim(u8, line[space_pos + 1 ..], " .\t\r\n");
                        free_pages = std.fmt.parseInt(u64, num_str, 10) catch continue;
                    }
                } else if (std.mem.indexOf(u8, line, "Pages active:")) |_| {
                    if (std.mem.lastIndexOfScalar(u8, line, ' ')) |space_pos| {
                        const num_str = std.mem.trim(u8, line[space_pos + 1 ..], " .\t\r\n");
                        active_pages = std.fmt.parseInt(u64, num_str, 10) catch continue;
                    }
                } else if (std.mem.indexOf(u8, line, "Pages inactive:")) |_| {
                    if (std.mem.lastIndexOfScalar(u8, line, ' ')) |space_pos| {
                        const num_str = std.mem.trim(u8, line[space_pos + 1 ..], " .\t\r\n");
                        inactive_pages = std.fmt.parseInt(u64, num_str, 10) catch continue;
                    }
                }
            }

            const page_size: u64 = 4096; // 4KB pages on most systems
            const total_pages = free_pages + active_pages + inactive_pages;
            if (total_pages == 0) return null;

            const used_bytes = (active_pages + inactive_pages) * page_size;
            const total_bytes = total_pages * page_size;
            const percentage = @as(u8, @intCast((used_bytes * 100) / total_bytes));

            return types.MemoryInfo{
                .used_bytes = used_bytes,
                .total_bytes = total_bytes,
                .percentage = percentage,
            };
        },
        .linux => {
            const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return null;
            defer file.close();

            const content = file.readToEndAlloc(allocator, 8192) catch return null;
            defer allocator.free(content);

            var mem_total: u64 = 0;
            var mem_available: u64 = 0;

            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "MemTotal:")) {
                    var parts = std.mem.tokenizeAny(u8, line, " \t");
                    _ = parts.next(); // Skip "MemTotal:"
                    if (parts.next()) |val| {
                        mem_total = std.fmt.parseInt(u64, val, 10) catch continue;
                        mem_total *= 1024; // Convert KB to bytes
                    }
                } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                    var parts = std.mem.tokenizeAny(u8, line, " \t");
                    _ = parts.next(); // Skip "MemAvailable:"
                    if (parts.next()) |val| {
                        mem_available = std.fmt.parseInt(u64, val, 10) catch continue;
                        mem_available *= 1024; // Convert KB to bytes
                    }
                }
            }

            if (mem_total == 0) return null;

            const used_bytes = mem_total - mem_available;
            const percentage = @as(u8, @intCast((used_bytes * 100) / mem_total));

            return types.MemoryInfo{
                .used_bytes = used_bytes,
                .total_bytes = mem_total,
                .percentage = percentage,
            };
        },
        else => return null,
    }
}

/// Detect memory module
pub fn detectMemory(allocator: std.mem.Allocator, _: []const u8) !?ModuleInfo {
    const memory = try getMemoryUsage(allocator) orelse return null;

    var info = ModuleInfo.init("memory");

    // Format as GB or MB
    const used_gb = memory.used_bytes / (1024 * 1024 * 1024);
    const total_gb = memory.total_bytes / (1024 * 1024 * 1024);

    if (total_gb > 0) {
        info.version = try std.fmt.allocPrint(allocator, "{d}/{d}GB", .{ used_gb, total_gb });
    } else {
        const used_mb = memory.used_bytes / (1024 * 1024);
        const total_mb = memory.total_bytes / (1024 * 1024);
        info.version = try std.fmt.allocPrint(allocator, "{d}/{d}MB", .{ used_mb, total_mb });
    }

    info.icon = "🧠";
    info.color = if (memory.percentage > 90) "#ff0000" else if (memory.percentage > 70) "#ffaa00" else "#00ff00";

    return info;
}

/// Detect OS module
pub fn detectOS(allocator: std.mem.Allocator, _: []const u8) !?ModuleInfo {
    var info = ModuleInfo.init("os");

    const os_name = switch (builtin.os.tag) {
        .macos => "macOS",
        .linux => "Linux",
        .windows => "Windows",
        .freebsd => "FreeBSD",
        .openbsd => "OpenBSD",
        .netbsd => "NetBSD",
        else => "Unknown",
    };

    info.version = try allocator.dupe(u8, os_name);

    info.icon = switch (builtin.os.tag) {
        .macos => "",
        .linux => "🐧",
        .windows => "🪟",
        .freebsd, .openbsd, .netbsd => "😈",
        else => "💻",
    };

    return info;
}

/// Detect time module
pub fn detectTime(allocator: std.mem.Allocator, _: []const u8) !?ModuleInfo {
    var info = ModuleInfo.init("time");

    const timestamp = std.time.timestamp();
    const seconds_in_day = @mod(timestamp, 86400);
    const hours = @divFloor(seconds_in_day, 3600);
    const minutes = @divFloor(@mod(seconds_in_day, 3600), 60);
    const seconds = @mod(seconds_in_day, 60);

    info.version = try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds });
    info.icon = "🕐";

    return info;
}

/// Detect Nix shell
pub fn detectNixShell(allocator: std.mem.Allocator, _: []const u8) !?ModuleInfo {
    // Check for IN_NIX_SHELL environment variable
    const in_nix_shell = std.process.getEnvVarOwned(allocator, "IN_NIX_SHELL") catch return null;
    defer allocator.free(in_nix_shell);

    var info = ModuleInfo.init("nix");

    if (std.mem.eql(u8, in_nix_shell, "pure")) {
        info.version = try allocator.dupe(u8, "pure");
    } else if (std.mem.eql(u8, in_nix_shell, "impure")) {
        info.version = try allocator.dupe(u8, "impure");
    } else {
        info.version = try allocator.dupe(u8, "nix-shell");
    }

    info.icon = "❄️";
    info.color = "#5277c3";

    return info;
}

/// Detect Docker context
pub fn detectDocker(allocator: std.mem.Allocator, _: []const u8) !?ModuleInfo {
    // Check for DOCKER_CONTEXT or use docker context show
    if (std.process.getEnvVarOwned(allocator, "DOCKER_CONTEXT")) |context| {
        var info = ModuleInfo.init("docker");
        info.version = context;
        info.icon = "🐳";
        info.color = "#2496ed";
        return info;
    } else |_| {
        var child = std.process.Child.init(&[_][]const u8{ "docker", "context", "show" }, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        child.spawn() catch return null;

        const output = child.stdout.?.readToEndAlloc(allocator, 1024) catch return null;
        defer allocator.free(output);

        const status = child.wait() catch return null;
        if (status != .Exited or status.Exited != 0) return null;

        const context = std.mem.trim(u8, output, &std.ascii.whitespace);
        if (context.len == 0 or std.mem.eql(u8, context, "default")) return null;

        var info = ModuleInfo.init("docker");
        info.version = try allocator.dupe(u8, context);
        info.icon = "🐳";
        info.color = "#2496ed";
        return info;
    }
}

/// Detect Kubernetes context
pub fn detectKubernetes(allocator: std.mem.Allocator, _: []const u8) !?ModuleInfo {
    var child = std.process.Child.init(&[_][]const u8{ "kubectl", "config", "current-context" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return null;

    const output = child.stdout.?.readToEndAlloc(allocator, 1024) catch return null;
    defer allocator.free(output);

    const status = child.wait() catch return null;
    if (status != .Exited or status.Exited != 0) return null;

    const context = std.mem.trim(u8, output, &std.ascii.whitespace);
    if (context.len == 0) return null;

    var info = ModuleInfo.init("kubernetes");
    info.version = try allocator.dupe(u8, context);
    info.icon = "☸️";
    info.color = "#326ce5";

    return info;
}
