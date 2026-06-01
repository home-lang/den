//! src-rooted aggregator for the hook manager test suite. `hooks/manager.zig`
//! imports `../`, so the module must be rooted at `src/`.

test {
    _ = @import("hooks/test_manager.zig");
}
