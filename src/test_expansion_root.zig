//! src-rooted aggregator for the expansion test suite. `utils/expansion.zig`
//! imports `../`, so the module must be rooted at `src/`.

test {
    _ = @import("utils/test_expansion.zig");
}
