//! Shell module - modular shell components for Den
//!
//! This module provides:
//! - Version detection for various languages/tools
//! - Builtin command implementations
//! - Loop execution (C-style for, select)

pub const version = @import("version.zig");

// Re-export version detection functions for convenience
pub const detectPackageVersion = version.detectPackageVersion;
pub const detectBunVersion = version.detectBunVersion;
pub const detectNodeVersion = version.detectNodeVersion;
pub const detectPythonVersion = version.detectPythonVersion;
pub const detectRubyVersion = version.detectRubyVersion;
pub const detectGoVersion = version.detectGoVersion;
pub const detectRustVersion = version.detectRustVersion;
pub const detectZigVersion = version.detectZigVersion;
