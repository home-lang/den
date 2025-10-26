const std = @import("std");

pub const config = @import("config.zig");
pub const command = @import("command.zig");

// Re-export commonly used types
pub const DenConfig = config.DenConfig;
pub const PromptConfig = config.PromptConfig;
pub const HistoryConfig = config.HistoryConfig;
pub const CompletionConfig = config.CompletionConfig;
pub const ThemeConfig = config.ThemeConfig;

pub const ParsedCommand = command.ParsedCommand;
pub const CommandType = command.CommandType;
pub const Operator = command.Operator;
pub const Redirection = command.Redirection;
pub const CommandChain = command.CommandChain;

test {
    std.testing.refAllDecls(@This());
}
