//! Shell module - modular shell components for Den
//!
//! This module provides:
//! - Version detection for various languages/tools
//! - Builtin command implementations
//! - Loop execution (C-style for, select)

pub const version = @import("version.zig");
pub const builtins = @import("builtins.zig");
pub const loops = @import("loops.zig");

// Re-export version detection functions for convenience
pub const detectPackageVersion = version.detectPackageVersion;
pub const detectBunVersion = version.detectBunVersion;
pub const detectNodeVersion = version.detectNodeVersion;
pub const detectPythonVersion = version.detectPythonVersion;
pub const detectRubyVersion = version.detectRubyVersion;
pub const detectGoVersion = version.detectGoVersion;
pub const detectRustVersion = version.detectRustVersion;
pub const detectZigVersion = version.detectZigVersion;

// Re-export builtin functions for convenience
pub const builtinHistory = builtins.builtinHistory;
pub const builtinAlias = builtins.builtinAlias;
pub const builtinUnalias = builtins.builtinUnalias;
pub const builtinType = builtins.builtinType;
pub const builtinWhich = builtins.builtinWhich;
pub const builtinHelp = builtins.builtinHelp;
pub const builtinBasename = builtins.builtinBasename;
pub const builtinDirname = builtins.builtinDirname;
pub const builtinRealpath = builtins.builtinRealpath;
pub const builtinUname = builtins.builtinUname;
pub const builtinWhoami = builtins.builtinWhoami;
pub const builtinClear = builtins.builtinClear;
pub const builtinSleep = builtins.builtinSleep;
pub const builtinReturn = builtins.builtinReturn;
pub const builtinBreak = builtins.builtinBreak;
pub const builtinContinue = builtins.builtinContinue;

// Re-export loop functions for convenience
pub const executeCStyleForLoopOneline = loops.executeCStyleForLoopOneline;
pub const executeCStyleLoopBodyCommand = loops.executeCStyleLoopBodyCommand;
pub const executeArithmeticStatement = loops.executeArithmeticStatement;
pub const evaluateArithmeticCondition = loops.evaluateArithmeticCondition;
pub const evaluateArithmeticExpression = loops.evaluateArithmeticExpression;
