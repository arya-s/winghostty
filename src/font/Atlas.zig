/// Font atlas — 2D rectangle bin packer for glyph textures.
/// Stub for Phase 1; will be implemented in Phase 3.
///
/// Modeled after Ghostty's `src/font/Atlas.zig`.
/// Uses a best-height-then-best-width bin packing algorithm
/// (from Jukka Jylänki's "A Thousand Ways to Pack the Bin").

const std = @import("std");

const Atlas = @This();

pub const Format = enum {
    grayscale,
    bgra,
};

pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

// Placeholder — will be fully implemented in Phase 3
format: Format,

pub fn init(_: std.mem.Allocator, format: Format) Atlas {
    return .{ .format = format };
}

pub fn deinit(_: *Atlas, _: std.mem.Allocator) void {}
