//! src-rooted aggregator for the built-in hooks test suite. `hooks/manager.zig`
//! imports `../`, so the module must be rooted at `src/`.

test {
    _ = @import("hooks/test_builtin.zig");
}
