const std = @import("std");

/// Simple regex matching utilities for shell pattern matching.
///
/// This module provides lightweight regex matching for shell operations
/// without depending on external regex libraries.

/// Match a regex pattern at a specific position in a string.
///
/// Supports:
/// - `.` - Match any character
/// - `[abc]` or `[a-z]` - Character classes
/// - `[^abc]` - Negated character classes
/// - `*`, `+`, `?` - Quantifiers
/// - `\x` - Escaped characters
///
/// Parameters:
/// - `string`: The string to match against
/// - `pattern`: The regex pattern
/// - `pos`: Starting position in the string
/// - `anchored_end`: If true, pattern must match to end of string
///
/// Returns true if the pattern matches at the given position.
pub fn matchRegexAt(string: []const u8, pattern: []const u8, pos: usize, anchored_end: bool) bool {
    var str_pos = pos;
    var pat_pos: usize = 0;

    while (pat_pos < pattern.len) {
        const pat_char = pattern[pat_pos];

        // Check for quantifiers
        var quantifier: u8 = 0;
        if (pat_pos + 1 < pattern.len) {
            const next = pattern[pat_pos + 1];
            if (next == '*' or next == '+' or next == '?') {
                quantifier = next;
            }
        }

        if (pat_char == '.') {
            // Match any character
            if (quantifier != 0) {
                pat_pos += 2;
                const min_match: usize = if (quantifier == '+') 1 else 0;
                var count: usize = 0;
                // Greedy match
                while (str_pos < string.len) {
                    str_pos += 1;
                    count += 1;
                }
                // Backtrack to find match
                while (count >= min_match) {
                    if (matchRegexAt(string, pattern[pat_pos..], str_pos, anchored_end)) {
                        return true;
                    }
                    if (count > 0) {
                        str_pos -= 1;
                        count -= 1;
                    } else {
                        break;
                    }
                }
                return false;
            } else {
                if (str_pos >= string.len) return false;
                str_pos += 1;
                pat_pos += 1;
            }
        } else if (pat_char == '[') {
            // Character class
            const class_end = std.mem.indexOfScalarPos(u8, pattern, pat_pos + 1, ']') orelse return false;
            const class = pattern[pat_pos + 1 .. class_end];
            const negate = class.len > 0 and class[0] == '^';
            const actual_class = if (negate) class[1..] else class;

            if (str_pos >= string.len) return false;
            const ch = string[str_pos];
            var matches_class = false;

            var i: usize = 0;
            while (i < actual_class.len) {
                if (i + 2 < actual_class.len and actual_class[i + 1] == '-') {
                    // Range
                    if (ch >= actual_class[i] and ch <= actual_class[i + 2]) {
                        matches_class = true;
                        break;
                    }
                    i += 3;
                } else {
                    if (ch == actual_class[i]) {
                        matches_class = true;
                        break;
                    }
                    i += 1;
                }
            }

            if (negate) matches_class = !matches_class;
            if (!matches_class) return false;

            str_pos += 1;
            pat_pos = class_end + 1;
            // Skip quantifier if present
            if (pat_pos < pattern.len and (pattern[pat_pos] == '*' or pattern[pat_pos] == '+' or pattern[pat_pos] == '?')) {
                pat_pos += 1;
            }
        } else if (pat_char == '\\' and pat_pos + 1 < pattern.len) {
            // Escaped character
            pat_pos += 1;
            const escaped = pattern[pat_pos];
            if (str_pos >= string.len or string[str_pos] != escaped) return false;
            str_pos += 1;
            pat_pos += 1;
        } else {
            // Literal character
            if (quantifier != 0) {
                pat_pos += 2;
                const min_match: usize = if (quantifier == '+') 1 else 0;
                var count: usize = 0;
                // Match as many as possible
                while (str_pos < string.len and string[str_pos] == pat_char) {
                    str_pos += 1;
                    count += 1;
                }
                // Backtrack
                while (count >= min_match) {
                    if (matchRegexAt(string, pattern[pat_pos..], str_pos, anchored_end)) {
                        return true;
                    }
                    if (count > 0) {
                        str_pos -= 1;
                        count -= 1;
                    } else {
                        break;
                    }
                }
                return false;
            } else {
                if (str_pos >= string.len or string[str_pos] != pat_char) return false;
                str_pos += 1;
                pat_pos += 1;
            }
        }
    }

    // If anchored at end, must have consumed entire string
    if (anchored_end) {
        return str_pos == string.len;
    }
    return true;
}

/// Match a pattern against a string from the beginning.
pub fn matchRegex(string: []const u8, pattern: []const u8) bool {
    return matchRegexAt(string, pattern, 0, true);
}

/// Find the first match of a pattern in a string.
/// Returns the starting position of the match, or null if not found.
pub fn findRegex(string: []const u8, pattern: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < string.len) {
        if (matchRegexAt(string, pattern, pos, false)) {
            return pos;
        }
        pos += 1;
    }
    return null;
}

// ========================================
// Tests
// ========================================

test "matchRegex literal match" {
    try std.testing.expect(matchRegex("hello", "hello"));
    try std.testing.expect(!matchRegex("hello", "world"));
    try std.testing.expect(!matchRegex("hello", "helloworld"));
}

test "matchRegex dot wildcard" {
    try std.testing.expect(matchRegex("hello", "h.llo"));
    try std.testing.expect(matchRegex("hello", "....."));
    try std.testing.expect(!matchRegex("hello", "......"));
}

test "matchRegex character class" {
    try std.testing.expect(matchRegex("hello", "h[aeiou]llo"));
    try std.testing.expect(!matchRegex("hxllo", "h[aeiou]llo"));
    try std.testing.expect(matchRegex("h5llo", "h[0-9]llo"));
}

test "matchRegex quantifiers" {
    try std.testing.expect(matchRegex("aaa", "a+"));
    try std.testing.expect(!matchRegex("", "a+"));
    try std.testing.expect(matchRegex("", "a*"));
    try std.testing.expect(matchRegex("aaa", "a*"));
}

test "findRegex" {
    try std.testing.expectEqual(@as(?usize, 0), findRegex("hello", "hel"));
    try std.testing.expectEqual(@as(?usize, 2), findRegex("hello", "llo"));
    try std.testing.expect(findRegex("hello", "xyz") == null);
}
