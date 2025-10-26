const std = @import("std");
const builtin_mod = @import("builtin.zig");
pub const interface = builtin_mod.interface_mod;

const BuiltinHook = builtin_mod.BuiltinHook;
const BuiltinHooks = builtin_mod.BuiltinHooks;
const CommandHookData = builtin_mod.CommandHookData;
const DirectoryHookData = builtin_mod.DirectoryHookData;
const PromptHookData = builtin_mod.PromptHookData;
const CompletionHookData = builtin_mod.CompletionHookData;
const HistoryHookData = builtin_mod.HistoryHookData;

test "BuiltinHook - names" {
    try std.testing.expectEqualStrings("shell:init", BuiltinHook.shell_init.getName());
    try std.testing.expectEqualStrings("shell:start", BuiltinHook.shell_start.getName());
    try std.testing.expectEqualStrings("shell:exit", BuiltinHook.shell_exit.getName());
    try std.testing.expectEqualStrings("command:before", BuiltinHook.command_before.getName());
    try std.testing.expectEqualStrings("command:after", BuiltinHook.command_after.getName());
    try std.testing.expectEqualStrings("command:error", BuiltinHook.command_error.getName());
    try std.testing.expectEqualStrings("directory:change", BuiltinHook.directory_change.getName());
    try std.testing.expectEqualStrings("prompt:before", BuiltinHook.prompt_before.getName());
    try std.testing.expectEqualStrings("completion:before", BuiltinHook.completion_before.getName());
    try std.testing.expectEqualStrings("history:add", BuiltinHook.history_add.getName());
}

test "BuiltinHooks - initialization" {
    const allocator = std.testing.allocator;

    var hooks = BuiltinHooks.init(allocator);
    defer hooks.deinit();

    try std.testing.expect(!hooks.isEnabled(.shell_init));
    try std.testing.expect(!hooks.isEnabled(.command_before));
}

test "BuiltinHooks - enable/disable" {
    const allocator = std.testing.allocator;

    var hooks = BuiltinHooks.init(allocator);
    defer hooks.deinit();

    try hooks.enable(.shell_init);
    try std.testing.expect(hooks.isEnabled(.shell_init));

    try hooks.disable(.shell_init);
    try std.testing.expect(!hooks.isEnabled(.shell_init));
}

test "BuiltinHooks - enable all" {
    const allocator = std.testing.allocator;

    var hooks = BuiltinHooks.init(allocator);
    defer hooks.deinit();

    try hooks.enableAll();

    try std.testing.expect(hooks.isEnabled(.shell_init));
    try std.testing.expect(hooks.isEnabled(.shell_start));
    try std.testing.expect(hooks.isEnabled(.shell_exit));
    try std.testing.expect(hooks.isEnabled(.command_before));
    try std.testing.expect(hooks.isEnabled(.command_after));
    try std.testing.expect(hooks.isEnabled(.command_error));
    try std.testing.expect(hooks.isEnabled(.directory_change));
    try std.testing.expect(hooks.isEnabled(.prompt_before));
    try std.testing.expect(hooks.isEnabled(.completion_before));
    try std.testing.expect(hooks.isEnabled(.history_add));
}

test "BuiltinHooks - disable all" {
    const allocator = std.testing.allocator;

    var hooks = BuiltinHooks.init(allocator);
    defer hooks.deinit();

    try hooks.enableAll();
    try hooks.disableAll();

    try std.testing.expect(!hooks.isEnabled(.shell_init));
    try std.testing.expect(!hooks.isEnabled(.command_before));
}

test "BuiltinHooks - list enabled" {
    const allocator = std.testing.allocator;

    var hooks = BuiltinHooks.init(allocator);
    defer hooks.deinit();

    try hooks.enable(.shell_init);
    try hooks.enable(.command_before);

    const enabled = try hooks.listEnabled();
    defer allocator.free(enabled);

    try std.testing.expectEqual(@as(usize, 2), enabled.len);
}

test "CommandHookData - initialization" {
    const allocator = std.testing.allocator;

    const args = [_][]const u8{ "arg1", "arg2" };
    var data = try CommandHookData.init(allocator, "test-command", &args);
    defer data.deinit();

    try std.testing.expectEqualStrings("test-command", data.command);
    try std.testing.expectEqual(@as(usize, 2), data.args.len);
    try std.testing.expect(data.exit_code == null);
    try std.testing.expect(data.error_msg == null);
}

test "CommandHookData - with exit code" {
    const allocator = std.testing.allocator;

    const args = [_][]const u8{};
    var data = try CommandHookData.init(allocator, "ls", &args);
    defer data.deinit();

    data.exit_code = 0;
    try std.testing.expectEqual(@as(i32, 0), data.exit_code.?);
}

test "CommandHookData - with error message" {
    const allocator = std.testing.allocator;

    const args = [_][]const u8{};
    var data = try CommandHookData.init(allocator, "bad-command", &args);
    defer data.deinit();

    data.error_msg = try allocator.dupe(u8, "Command not found");
    try std.testing.expectEqualStrings("Command not found", data.error_msg.?);
}

test "DirectoryHookData - initialization" {
    const allocator = std.testing.allocator;

    var data = try DirectoryHookData.init(allocator, "/home/user", "/home/user/projects");
    defer data.deinit();

    try std.testing.expectEqualStrings("/home/user", data.old_path);
    try std.testing.expectEqualStrings("/home/user/projects", data.new_path);
}

test "PromptHookData - initialization" {
    const allocator = std.testing.allocator;

    var data = try PromptHookData.init(allocator, "/home/user", "john", "myhost");
    defer data.deinit();

    try std.testing.expectEqualStrings("/home/user", data.current_dir);
    try std.testing.expectEqualStrings("john", data.user);
    try std.testing.expectEqualStrings("myhost", data.hostname);
    try std.testing.expect(data.custom_prompt == null);
}

test "PromptHookData - set custom prompt" {
    const allocator = std.testing.allocator;

    var data = try PromptHookData.init(allocator, "/home/user", "john", "myhost");
    defer data.deinit();

    try data.setCustomPrompt(">>> ");
    try std.testing.expectEqualStrings(">>> ", data.custom_prompt.?);

    // Update custom prompt
    try data.setCustomPrompt("$ ");
    try std.testing.expectEqualStrings("$ ", data.custom_prompt.?);
}

test "CompletionHookData - initialization" {
    const allocator = std.testing.allocator;

    var data = try CompletionHookData.init(allocator, "ls /h", 5);
    defer data.deinit();

    try std.testing.expectEqualStrings("ls /h", data.input);
    try std.testing.expectEqual(@as(usize, 5), data.cursor_pos);
    try std.testing.expectEqual(@as(usize, 0), data.suggestions.items.len);
}

test "CompletionHookData - add suggestions" {
    const allocator = std.testing.allocator;

    var data = try CompletionHookData.init(allocator, "ls /h", 5);
    defer data.deinit();

    try data.addSuggestion("/home");
    try data.addSuggestion("/host");

    try std.testing.expectEqual(@as(usize, 2), data.suggestions.items.len);
    try std.testing.expectEqualStrings("/home", data.suggestions.items[0]);
    try std.testing.expectEqualStrings("/host", data.suggestions.items[1]);
}

test "HistoryHookData - initialization" {
    const allocator = std.testing.allocator;

    var data = try HistoryHookData.init(allocator, "ls -la");
    defer data.deinit();

    try std.testing.expectEqualStrings("ls -la", data.command);
    try std.testing.expect(data.should_add);
    try std.testing.expect(data.timestamp > 0);
}

test "HistoryHookData - prevent adding" {
    const allocator = std.testing.allocator;

    var data = try HistoryHookData.init(allocator, "secret command");
    defer data.deinit();

    data.should_add = false;
    try std.testing.expect(!data.should_add);
}

test "Hook context creation - command" {
    const allocator = std.testing.allocator;

    const args = [_][]const u8{};
    var data = try CommandHookData.init(allocator, "test", &args);
    defer data.deinit();

    const ctx = builtin_mod.createCommandContext(allocator, .pre_command, &data);

    try std.testing.expectEqual(ctx.hook_type, .pre_command);
    try std.testing.expect(ctx.data != null);
}

test "Hook context creation - directory" {
    const allocator = std.testing.allocator;

    var data = try DirectoryHookData.init(allocator, "/old", "/new");
    defer data.deinit();

    const ctx = builtin_mod.createDirectoryContext(allocator, &data);

    try std.testing.expectEqual(ctx.hook_type, .post_command);
    try std.testing.expect(ctx.data != null);
}

test "Hook context creation - prompt" {
    const allocator = std.testing.allocator;

    var data = try PromptHookData.init(allocator, "/home", "user", "host");
    defer data.deinit();

    const ctx = builtin_mod.createPromptContext(allocator, &data);

    try std.testing.expectEqual(ctx.hook_type, .pre_prompt);
    try std.testing.expect(ctx.data != null);
}

test "Hook context creation - completion" {
    const allocator = std.testing.allocator;

    var data = try CompletionHookData.init(allocator, "ls", 2);
    defer data.deinit();

    const ctx = builtin_mod.createCompletionContext(allocator, &data);

    try std.testing.expectEqual(ctx.hook_type, .pre_prompt);
    try std.testing.expect(ctx.data != null);
}

test "Hook context creation - history" {
    const allocator = std.testing.allocator;

    var data = try HistoryHookData.init(allocator, "echo hello");
    defer data.deinit();

    const ctx = builtin_mod.createHistoryContext(allocator, &data);

    try std.testing.expectEqual(ctx.hook_type, .post_command);
    try std.testing.expect(ctx.data != null);
}
