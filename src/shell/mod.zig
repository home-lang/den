//! Shell module - modular shell components for Den
//!
//! This module provides:
//! - Version detection for various languages/tools
//! - Builtin command implementations
//! - Loop execution (C-style for, select)
//! - Directory stack management
//! - Printf formatting

pub const version = @import("version.zig");
pub const builtins = @import("builtins.zig");
pub const loops = @import("loops.zig");
pub const directory_stack = @import("directory_stack.zig");
pub const printf_builtin = @import("printf_builtin.zig");
pub const test_builtin = @import("test_builtin.zig");
pub const variable_builtins = @import("variable_builtins.zig");

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

// Re-export directory stack functions
pub const builtinPushd = directory_stack.builtinPushd;
pub const builtinPopd = directory_stack.builtinPopd;
pub const builtinDirs = directory_stack.builtinDirs;
pub const rotateDirStack = directory_stack.rotateDirStack;
pub const printDirStack = directory_stack.printDirStack;

// Re-export printf functions
pub const builtinPrintf = printf_builtin.builtinPrintf;

// Re-export test functions
pub const builtinTest = test_builtin.builtinTest;
pub const matchRegex = test_builtin.matchRegex;

// Re-export variable builtin functions
pub const builtinLocal = variable_builtins.builtinLocal;
pub const builtinDeclare = variable_builtins.builtinDeclare;
pub const builtinReadonly = variable_builtins.builtinReadonly;
pub const builtinTypeset = variable_builtins.builtinTypeset;
pub const builtinLet = variable_builtins.builtinLet;
pub const printDeclare = variable_builtins.printDeclare;
pub const setVarAttributes = variable_builtins.setVarAttributes;
