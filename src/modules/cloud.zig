const std = @import("std");
const types = @import("types.zig");

const CloudContext = types.CloudContext;
const CloudProvider = types.CloudProvider;

fn getenv(key: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

fn getEnvOwned(allocator: std.mem.Allocator, key: [*:0]const u8) ?[]u8 {
    const value = getenv(key) orelse return null;
    return allocator.dupe(u8, value) catch null;
}

/// Parse INI-style config file
fn parseIniConfig(allocator: std.mem.Allocator, content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') {
            continue;
        }

        // Look for key = value
        if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
            const line_key = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
            const line_value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

            if (std.mem.eql(u8, line_key, key)) {
                return allocator.dupe(u8, line_value) catch null;
            }
        }
    }
    return null;
}

/// Read config file from home directory
fn readHomeConfig(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const home = getEnvOwned(allocator, "HOME") orelse return null;
    defer allocator.free(home);

    const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, path }) catch return null;
    defer allocator.free(full_path);

    const file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, full_path, .{}) catch return null;
    defer file.close(std.Options.debug_io);

    const content = blk: {
        var read_buf: [4096]u8 = undefined;
        var reader = file.readerStreaming(std.Options.debug_io, &read_buf);
        break :blk reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch break :blk null;
    };
    return content;
}

/// Detect AWS context
pub fn detectAWS(allocator: std.mem.Allocator, _: []const u8) !?CloudContext {
    var ctx = CloudContext.init(allocator, CloudProvider.AWS.name, CloudProvider.AWS.icon);

    // Check environment variables
    if (getEnvOwned(allocator, "AWS_PROFILE")) |profile| {
        ctx.profile = profile;
    } else {
        // Try to read from config
        if (readHomeConfig(allocator, ".aws/config")) |content| {
            defer allocator.free(content);

            // Look for default profile
            var lines = std.mem.splitScalar(u8, content, '\n');
            var in_default = false;
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

                if (std.mem.startsWith(u8, trimmed, "[default]")) {
                    in_default = true;
                    continue;
                }

                if (std.mem.startsWith(u8, trimmed, "[")) {
                    in_default = false;
                }

                if (in_default and std.mem.indexOf(u8, trimmed, "=")) |_| {
                    ctx.profile = try allocator.dupe(u8, "default");
                    break;
                }
            }
        }
    }

    if (getEnvOwned(allocator, "AWS_REGION")) |region| {
        ctx.region = region;
    } else {
        if (getEnvOwned(allocator, "AWS_DEFAULT_REGION")) |region| {
            ctx.region = region;
        } else {
            // Try to read from config
            if (readHomeConfig(allocator, ".aws/config")) |content| {
                defer allocator.free(content);
                if (parseIniConfig(allocator, content, "region")) |region| {
                    ctx.region = region;
                }
            }
        }
    }

    // Only return if we found something
    if (ctx.profile == null and ctx.region == null) {
        ctx.deinit();
        return null;
    }

    return ctx;
}

/// Detect Azure context
pub fn detectAzure(allocator: std.mem.Allocator, _: []const u8) !?CloudContext {
    var ctx = CloudContext.init(allocator, CloudProvider.Azure.name, CloudProvider.Azure.icon);

    // Check environment variables
    if (getEnvOwned(allocator, "AZURE_SUBSCRIPTION_ID")) |sub_id| {
        ctx.profile = sub_id;
    } else {
        // Try to read from Azure config
        if (readHomeConfig(allocator, ".azure/azureProfile.json")) |content| {
            defer allocator.free(content);

            // Simple JSON parsing - look for "isDefault": true
            if (std.mem.indexOf(u8, content, "\"isDefault\": true")) |_| {
                // Look for subscription ID before this
                if (std.mem.indexOf(u8, content, "\"id\":")) |id_pos| {
                    const after_id = content[id_pos + 6 ..];
                    if (std.mem.indexOf(u8, after_id, "\"")) |start| {
                        const after_start = after_id[start + 1 ..];
                        if (std.mem.indexOf(u8, after_start, "\"")) |end| {
                            ctx.profile = try allocator.dupe(u8, after_start[0..end]);
                        }
                    }
                }
            }
        }
    }

    if (getEnvOwned(allocator, "AZURE_TENANT_ID")) |tenant| {
        ctx.project = tenant;
    }

    // Only return if we found something
    if (ctx.profile == null and ctx.project == null) {
        ctx.deinit();
        return null;
    }

    return ctx;
}

/// Detect GCP context
pub fn detectGCP(allocator: std.mem.Allocator, _: []const u8) !?CloudContext {
    var ctx = CloudContext.init(allocator, CloudProvider.GCP.name, CloudProvider.GCP.icon);

    // Check environment variables
    if (getEnvOwned(allocator, "GOOGLE_CLOUD_PROJECT")) |project| {
        ctx.project = project;
    } else {
        if (getEnvOwned(allocator, "GCP_PROJECT")) |project| {
            ctx.project = project;
        } else {
            if (getEnvOwned(allocator, "GCLOUD_PROJECT")) |project| {
                ctx.project = project;
            } else {
                // Try to read from gcloud config
                if (readHomeConfig(allocator, ".config/gcloud/configurations/config_default")) |content| {
                    defer allocator.free(content);
                    if (parseIniConfig(allocator, content, "project")) |project| {
                        ctx.project = project;
                    }
                }
            }
        }
    }

    // Check for region
    if (readHomeConfig(allocator, ".config/gcloud/configurations/config_default")) |content| {
        defer allocator.free(content);
        if (parseIniConfig(allocator, content, "region")) |region| {
            ctx.region = region;
        } else if (parseIniConfig(allocator, content, "zone")) |zone| {
            // Extract region from zone (e.g., us-central1-a -> us-central1)
            if (std.mem.lastIndexOf(u8, zone, "-")) |last_dash| {
                ctx.region = try allocator.dupe(u8, zone[0..last_dash]);
                allocator.free(zone);
            } else {
                ctx.region = zone;
            }
        }
    }

    // Only return if we found something
    if (ctx.project == null and ctx.region == null) {
        ctx.deinit();
        return null;
    }

    return ctx;
}

/// Render cloud context to string
pub fn renderCloudContext(allocator: std.mem.Allocator, ctx: *const CloudContext) ![]const u8 {
    var result: std.ArrayList(u8) = .{
        .items = &[_]u8{},
        .capacity = 0,
    };
    defer result.deinit(allocator);

    // Icon
    try result.appendSlice(allocator, ctx.icon);
    try result.append(allocator, ' ');

    // Provider
    try result.appendSlice(allocator, ctx.provider);

    // Profile/Project
    if (ctx.profile) |profile| {
        try result.append(allocator, ':');
        try result.appendSlice(allocator, profile);
    } else if (ctx.project) |project| {
        try result.append(allocator, ':');
        try result.appendSlice(allocator, project);
    }

    // Region
    if (ctx.region) |region| {
        try result.append(allocator, '@');
        try result.appendSlice(allocator, region);
    }

    return try result.toOwnedSlice(allocator);
}
