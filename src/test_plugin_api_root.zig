//! src-rooted aggregator for the plugin API test suite. `plugins/api.zig`
//! imports `../shell.zig` and `../utils/io.zig`, so the module must be rooted
//! at `src/` for those imports to resolve.

test {
    _ = @import("plugins/test_api.zig");
}
