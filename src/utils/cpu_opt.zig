// CPU optimization utilities for Den Shell
const std = @import("std");

/// Simple LRU cache for expensive operations
pub fn LRUCache(comptime K: type, comptime V: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            key: K,
            value: V,
            age: usize,
        };

        entries: [capacity]?Entry,
        current_age: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .entries = [_]?Entry{null} ** capacity,
                .current_age = 0,
                .allocator = allocator,
            };
        }

        pub fn get(self: *Self, key: K) ?V {
            for (&self.entries) |*maybe_entry| {
                if (maybe_entry.*) |*entry| {
                    if (std.meta.eql(entry.key, key)) {
                        entry.age = self.current_age;
                        self.current_age += 1;
                        return entry.value;
                    }
                }
            }
            return null;
        }

        pub fn put(self: *Self, key: K, value: V) void {
            // Check if key exists, update if so
            for (&self.entries) |*maybe_entry| {
                if (maybe_entry.*) |*entry| {
                    if (std.meta.eql(entry.key, key)) {
                        entry.value = value;
                        entry.age = self.current_age;
                        self.current_age += 1;
                        return;
                    }
                }
            }

            // Find empty slot or evict oldest
            var oldest_idx: usize = 0;
            var oldest_age: usize = std.math.maxInt(usize);

            for (self.entries, 0..) |maybe_entry, i| {
                if (maybe_entry == null) {
                    // Found empty slot
                    self.entries[i] = Entry{
                        .key = key,
                        .value = value,
                        .age = self.current_age,
                    };
                    self.current_age += 1;
                    return;
                } else if (maybe_entry.?.age < oldest_age) {
                    oldest_age = maybe_entry.?.age;
                    oldest_idx = i;
                }
            }

            // Evict oldest
            self.entries[oldest_idx] = Entry{
                .key = key,
                .value = value,
                .age = self.current_age,
            };
            self.current_age += 1;
        }

        pub fn clear(self: *Self) void {
            for (&self.entries) |*entry| {
                entry.* = null;
            }
            self.current_age = 0;
        }
    };
}

/// Fast string matching using Boyer-Moore-Horspool algorithm
pub const FastStringMatcher = struct {
    bad_char_skip: [256]usize,
    pattern: []const u8,

    pub fn init(pattern: []const u8) FastStringMatcher {
        var matcher = FastStringMatcher{
            .bad_char_skip = [_]usize{pattern.len} ** 256,
            .pattern = pattern,
        };

        // Build bad character skip table
        for (pattern, 0..) |c, i| {
            if (i < pattern.len - 1) {
                matcher.bad_char_skip[c] = pattern.len - 1 - i;
            }
        }

        return matcher;
    }

    pub fn find(self: *const FastStringMatcher, text: []const u8) ?usize {
        if (self.pattern.len == 0 or text.len < self.pattern.len) {
            return null;
        }

        var pos: usize = 0;
        while (pos <= text.len - self.pattern.len) {
            var i: usize = self.pattern.len - 1;

            while (i >= 0 and text[pos + i] == self.pattern[i]) {
                if (i == 0) return pos;
                i -= 1;
            }

            pos += self.bad_char_skip[text[pos + self.pattern.len - 1]];
        }

        return null;
    }

    pub fn matches(self: *const FastStringMatcher, text: []const u8) bool {
        return self.find(text) != null;
    }
};

/// Optimized prefix matching for completion
pub fn hasPrefix(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;

    // Use SIMD-friendly comparison for longer strings
    if (needle.len >= 16 and @hasDecl(std.simd, "Vector")) {
        const chunk_size = 16;
        var i: usize = 0;

        // Process 16-byte chunks
        while (i + chunk_size <= needle.len) {
            const hay_chunk = haystack[i..][0..chunk_size];
            const need_chunk = needle[i..][0..chunk_size];

            if (!std.mem.eql(u8, hay_chunk, need_chunk)) {
                return false;
            }

            i += chunk_size;
        }

        // Handle remaining bytes
        return std.mem.eql(u8, haystack[i..needle.len], needle[i..]);
    }

    // Fallback to simple comparison
    return std.mem.startsWith(u8, haystack, needle);
}

/// Fuzzy matching score (0-100, higher is better)
pub fn fuzzyScore(haystack: []const u8, needle: []const u8) u8 {
    if (needle.len == 0) return 100;
    if (haystack.len == 0) return 0;

    var score: usize = 0;
    var needle_idx: usize = 0;
    var consecutive: usize = 0;
    var bonus_given: bool = false;

    for (haystack, 0..) |c, hay_idx| {
        if (needle_idx < needle.len and c == needle[needle_idx]) {
            // Match found
            score += 10;

            // Bonus for consecutive matches
            consecutive += 1;
            if (consecutive > 1) {
                score += 5; // Bonus for consecutive (not per character)
            }

            // Bonus for start of string (only once)
            if (!bonus_given and hay_idx == 0) {
                score += 20;
                bonus_given = true;
            }

            // Bonus for start of word (after space/slash/dash)
            if (!bonus_given and hay_idx > 0) {
                const prev = haystack[hay_idx - 1];
                if (prev == ' ' or prev == '/' or prev == '-' or prev == '_') {
                    score += 15;
                    bonus_given = true;
                }
            }

            needle_idx += 1;
        } else {
            consecutive = 0;
            bonus_given = false;
        }
    }

    // Check if all characters matched
    if (needle_idx != needle.len) {
        return 0;
    }

    // Normalize to 0-100
    // For exact match at start: 10*n + 20 + 5*(n-1) = 15n + 15
    // For n=5: 90 points -> normalized to ~100
    const max_score = needle.len * 20;
    return @min(100, @as(u8, @intCast((score * 100) / max_score)));
}

/// History index for fast search
pub const HistoryIndex = struct {
    const MAX_ENTRIES = 1000;
    const HASH_SIZE = 256;

    hash_table: [HASH_SIZE]?usize,
    entries: [MAX_ENTRIES]?[]const u8,
    count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HistoryIndex {
        return .{
            .hash_table = [_]?usize{null} ** HASH_SIZE,
            .entries = [_]?[]const u8{null} ** MAX_ENTRIES,
            .count = 0,
            .allocator = allocator,
        };
    }

    fn hash(self: *const HistoryIndex, s: []const u8) usize {
        _ = self;
        var h: u32 = 5381;
        for (s) |c| {
            h = ((h << 5) +% h) +% c;
        }
        return h % HASH_SIZE;
    }

    pub fn add(self: *HistoryIndex, entry: []const u8) !void {
        if (self.count >= MAX_ENTRIES) {
            // Shift entries (remove oldest)
            if (self.entries[0]) |old| {
                self.allocator.free(old);
            }

            var i: usize = 0;
            while (i < MAX_ENTRIES - 1) : (i += 1) {
                self.entries[i] = self.entries[i + 1];
            }
            self.count -= 1;
        }

        const owned = try self.allocator.dupe(u8, entry);
        self.entries[self.count] = owned;
        self.count += 1;

        // Update hash table
        const h = self.hash(entry);
        self.hash_table[h] = self.count - 1;
    }

    pub fn search(self: *const HistoryIndex, pattern: []const u8) ?[]const u8 {
        // Try hash table first
        const h = self.hash(pattern);
        if (self.hash_table[h]) |idx| {
            if (self.entries[idx]) |entry| {
                if (std.mem.eql(u8, entry, pattern)) {
                    return entry;
                }
            }
        }

        // Fall back to linear search
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            if (self.entries[i]) |entry| {
                if (std.mem.indexOf(u8, entry, pattern) != null) {
                    return entry;
                }
            }
        }

        return null;
    }

    pub fn prefixSearch(self: *const HistoryIndex, prefix: []const u8) ?[]const u8 {
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            if (self.entries[i]) |entry| {
                if (std.mem.startsWith(u8, entry, prefix)) {
                    return entry;
                }
            }
        }
        return null;
    }

    pub fn deinit(self: *HistoryIndex) void {
        for (self.entries) |maybe_entry| {
            if (maybe_entry) |entry| {
                self.allocator.free(entry);
            }
        }
    }
};

/// Memoization helper for expensive pure functions
pub fn memoize(
    comptime func: anytype,
    comptime cache_size: usize,
) type {
    const Fn = @TypeOf(func);
    const fn_info = @typeInfo(Fn).Fn;
    const ArgType = fn_info.params[0].type.?;
    const ReturnType = fn_info.return_type.?;

    return struct {
        cache: LRUCache(ArgType, ReturnType, cache_size),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .cache = LRUCache(ArgType, ReturnType, cache_size).init(allocator),
            };
        }

        pub fn call(self: *@This(), arg: ArgType) ReturnType {
            if (self.cache.get(arg)) |cached| {
                return cached;
            }

            const result = func(arg);
            self.cache.put(arg, result);
            return result;
        }
    };
}

/// String hash set for O(1) deduplication
/// Much faster than linear search for checking duplicates in completion results
pub const StringHashSet = struct {
    const Self = @This();

    map: std.StringHashMap(void),
    allocator: std.mem.Allocator,
    owns_strings: bool,

    /// Initialize a new StringHashSet
    /// If owns_strings is true, the set will duplicate and own the strings
    pub fn init(allocator: std.mem.Allocator, owns_strings: bool) Self {
        return .{
            .map = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
            .owns_strings = owns_strings,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.owns_strings) {
            var iter = self.map.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
        }
        self.map.deinit();
    }

    /// Add a string to the set
    /// Returns true if the string was added (not a duplicate)
    /// Returns false if the string was already present
    pub fn add(self: *Self, s: []const u8) !bool {
        if (self.map.contains(s)) {
            return false;
        }

        const key = if (self.owns_strings)
            try self.allocator.dupe(u8, s)
        else
            s;

        try self.map.put(key, {});
        return true;
    }

    /// Check if the set contains a string (O(1) lookup)
    pub fn contains(self: *const Self, s: []const u8) bool {
        return self.map.contains(s);
    }

    /// Get the number of unique strings in the set
    pub fn count(self: *const Self) usize {
        return self.map.count();
    }

    /// Clear all entries from the set
    pub fn clear(self: *Self) void {
        if (self.owns_strings) {
            var iter = self.map.keyIterator();
            while (iter.next()) |key| {
                self.allocator.free(key.*);
            }
        }
        self.map.clearRetainingCapacity();
    }
};

/// Inline deduplication helper - returns true if value should be added
/// Uses a pre-allocated hash set for O(1) lookups
pub fn shouldAddUnique(seen: *StringHashSet, value: []const u8) bool {
    return seen.add(value) catch false;
}

// Tests
test "LRUCache basic operations" {
    var cache = LRUCache(i32, []const u8, 3).init(std.testing.allocator);

    cache.put(1, "one");
    cache.put(2, "two");
    cache.put(3, "three");

    try std.testing.expectEqualStrings("one", cache.get(1).?);
    try std.testing.expectEqualStrings("two", cache.get(2).?);

    // Add fourth item, should evict least recently used (key 3)
    // Keys 1 and 2 were just accessed, so key 3 is the oldest
    cache.put(4, "four");

    try std.testing.expect(cache.get(3) == null); // Key 3 should be evicted
    try std.testing.expectEqualStrings("one", cache.get(1).?); // Key 1 should still be there
    try std.testing.expectEqualStrings("four", cache.get(4).?);
}

test "FastStringMatcher" {
    const pattern = "hello";
    const matcher = FastStringMatcher.init(pattern);

    try std.testing.expect(matcher.matches("hello world"));
    try std.testing.expect(matcher.matches("say hello"));
    try std.testing.expect(!matcher.matches("helo world"));
    try std.testing.expectEqual(@as(?usize, 0), matcher.find("hello world"));
    try std.testing.expectEqual(@as(?usize, 4), matcher.find("say hello"));
}

test "hasPrefix optimization" {
    try std.testing.expect(hasPrefix("hello world", "hello"));
    try std.testing.expect(hasPrefix("hello", "h"));
    try std.testing.expect(!hasPrefix("hello", "world"));
    try std.testing.expect(hasPrefix("", ""));
    try std.testing.expect(!hasPrefix("", "x"));
}

test "fuzzyScore" {
    // Exact match at start should score very high
    try std.testing.expect(fuzzyScore("hello", "hello") >= 90);

    // Prefix match with word boundary should score well
    try std.testing.expect(fuzzyScore("hello-world", "hw") >= 50);

    // No match
    try std.testing.expectEqual(@as(u8, 0), fuzzyScore("hello", "xyz"));

    // Consecutive bonus - continuous match should score higher than scattered
    const score1 = fuzzyScore("hello", "hel");
    const score2 = fuzzyScore("hxexl", "hel");
    try std.testing.expect(score1 > score2);
}

test "HistoryIndex" {
    var index = HistoryIndex.init(std.testing.allocator);
    defer index.deinit();

    try index.add("git commit");
    try index.add("git push");
    try index.add("ls -la");

    const result = index.search("git");
    try std.testing.expect(result != null);

    const prefix_result = index.prefixSearch("git");
    try std.testing.expect(prefix_result != null);
}

test "StringHashSet deduplication" {
    var set = StringHashSet.init(std.testing.allocator, true);
    defer set.deinit();

    // First add should succeed
    try std.testing.expect(try set.add("hello"));
    try std.testing.expect(try set.add("world"));

    // Duplicate should return false
    try std.testing.expect(!try set.add("hello"));

    // Contains should work
    try std.testing.expect(set.contains("hello"));
    try std.testing.expect(set.contains("world"));
    try std.testing.expect(!set.contains("foo"));

    // Count should be correct
    try std.testing.expectEqual(@as(usize, 2), set.count());
}

test "StringHashSet non-owning" {
    var set = StringHashSet.init(std.testing.allocator, false);
    defer set.deinit();

    const s1 = "hello";
    const s2 = "world";

    try std.testing.expect(try set.add(s1));
    try std.testing.expect(try set.add(s2));
    try std.testing.expect(!try set.add(s1)); // Duplicate

    try std.testing.expectEqual(@as(usize, 2), set.count());
}
