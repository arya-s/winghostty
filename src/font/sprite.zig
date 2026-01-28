//! Sprite rendering for built-in glyphs (box drawing, powerline, etc.)
//!
//! This uses z2d for anti-aliased rendering, following Ghostty's approach.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const canvas_mod = @import("sprite/canvas.zig");
pub const Canvas = canvas_mod.Canvas;
pub const Color = canvas_mod.Color;
pub const box = @import("sprite/draw/box.zig");
pub const braille = @import("sprite/draw/braille.zig");
pub const common = @import("sprite/draw/common.zig");

/// Metrics needed for sprite rendering
pub const Metrics = common.Metrics;

/// Check if a codepoint should be rendered as a sprite
pub fn isSprite(codepoint: u32) bool {
    return switch (codepoint) {
        // Box drawing (U+2500 - U+257F)
        0x2500...0x257F => true,
        // Block elements (U+2580 - U+259F)
        0x2580...0x259F => true,
        // Braille patterns (U+2800 - U+28FF)
        0x2800...0x28FF => true,
        // Powerline symbols
        0xE0B0...0xE0B3 => true,
        else => false,
    };
}

/// Check if a codepoint needs padding for anti-aliased rendering
fn needsPadding(codepoint: u32) bool {
    return switch (codepoint) {
        // Rounded corners need padding for bezier curves
        0x256D...0x2570 => true,
        // Diagonals need padding for anti-aliased lines
        0x2571...0x2573 => true,
        // Powerline triangles need padding
        0xE0B0...0xE0B3 => true,
        // Everything else tiles and should have no padding
        else => false,
    };
}

/// Check if a codepoint should skip trimming (use full cell size)
fn skipTrim(codepoint: u32) bool {
    return switch (codepoint) {
        // Braille patterns must all use the same size for consistent positioning
        // Different patterns have different dots filled, but should align the same
        0x2800...0x28FF => true,
        else => false,
    };
}

/// Render a sprite to a pixel buffer
/// Returns the pixel data as grayscale or null if not a sprite
pub fn renderSprite(
    alloc: Allocator,
    codepoint: u32,
    metrics: Metrics,
) !?SpriteResult {
    if (!isSprite(codepoint)) return null;

    // Only add padding for glyphs that need anti-aliasing (curves, diagonals)
    // Box drawing and blocks must tile seamlessly with zero padding
    const needs_padding = needsPadding(codepoint);
    const padding_x: u32 = if (needs_padding) @max(metrics.cell_width / 4, 2) else 0;
    const padding_y: u32 = if (needs_padding) @max(metrics.cell_height / 4, 2) else 0;

    var canvas = try Canvas.init(alloc, metrics.cell_width, metrics.cell_height, padding_x, padding_y);
    errdefer canvas.deinit();

    // Draw based on codepoint range
    switch (codepoint) {
        0x2500...0x257F => try box.draw(codepoint, &canvas, metrics),
        0x2580...0x259F => drawBlockElement(codepoint, &canvas, metrics),
        0x2800...0x28FF => braille.draw(codepoint, &canvas, metrics),
        0xE0B0...0xE0B3 => try drawPowerline(codepoint, &canvas, metrics),
        else => return null,
    }

    // Trim empty rows/columns to find actual content bounds (like Ghostty)
    // But skip trimming for certain sprites that need consistent sizing (e.g., braille)
    if (!skipTrim(codepoint)) {
        canvas.trim();
    }

    const surface_width = canvas.getSurfaceWidth();
    const surface_height = canvas.getSurfaceHeight();
    const region_width = surface_width - canvas.clip_left - canvas.clip_right;
    const region_height = surface_height - canvas.clip_top - canvas.clip_bottom;

    return .{
        .surface_width = surface_width,
        .surface_height = surface_height,
        .width = region_width,
        .height = region_height,
        .cell_width = metrics.cell_width,
        .cell_height = metrics.cell_height,
        .padding_x = padding_x,
        .padding_y = padding_y,
        .clip_top = canvas.clip_top,
        .clip_bottom = canvas.clip_bottom,
        .clip_left = canvas.clip_left,
        .clip_right = canvas.clip_right,
        .data = canvas.getPixels(),
        .canvas = canvas,
    };
}

pub const SpriteResult = struct {
    /// Full surface dimensions (including padding)
    surface_width: u32,
    surface_height: u32,
    /// Trimmed region dimensions (actual content)
    width: u32,
    height: u32,
    cell_width: u32,
    cell_height: u32,
    padding_x: u32,
    padding_y: u32,
    /// Clipping bounds from trim()
    clip_top: u32,
    clip_bottom: u32,
    clip_left: u32,
    clip_right: u32,
    /// Full pixel data (caller must extract trimmed region)
    data: []const u8,
    canvas: Canvas,

    pub fn deinit(self: *SpriteResult) void {
        self.canvas.deinit();
    }
};

/// Draw block elements (U+2580 - U+259F)
fn drawBlockElement(codepoint: u32, canvas: *Canvas, metrics: Metrics) void {
    const w: i32 = @intCast(metrics.cell_width);
    const h: i32 = @intCast(metrics.cell_height);
    const half_h = @divFloor(h, 2);
    const half_w = @divFloor(w, 2);

    switch (codepoint) {
        0x2580 => canvas.box(0, 0, w, half_h, .on), // Upper half
        0x2581 => canvas.box(0, h - @divFloor(h, 8), w, h, .on), // Lower 1/8
        0x2582 => canvas.box(0, h - @divFloor(h, 4), w, h, .on), // Lower 2/8
        0x2583 => canvas.box(0, h - @divFloor(h * 3, 8), w, h, .on), // Lower 3/8
        0x2584 => canvas.box(0, half_h, w, h, .on), // Lower half
        0x2585 => canvas.box(0, h - @divFloor(h * 5, 8), w, h, .on), // Lower 5/8
        0x2586 => canvas.box(0, h - @divFloor(h * 3, 4), w, h, .on), // Lower 3/4
        0x2587 => canvas.box(0, h - @divFloor(h * 7, 8), w, h, .on), // Lower 7/8
        0x2588 => canvas.box(0, 0, w, h, .on), // Full block
        0x2589 => canvas.box(0, 0, @divFloor(w * 7, 8), h, .on), // Left 7/8
        0x258A => canvas.box(0, 0, @divFloor(w * 3, 4), h, .on), // Left 3/4
        0x258B => canvas.box(0, 0, @divFloor(w * 5, 8), h, .on), // Left 5/8
        0x258C => canvas.box(0, 0, half_w, h, .on), // Left half
        0x258D => canvas.box(0, 0, @divFloor(w * 3, 8), h, .on), // Left 3/8
        0x258E => canvas.box(0, 0, @divFloor(w, 4), h, .on), // Left 1/4
        0x258F => canvas.box(0, 0, @divFloor(w, 8), h, .on), // Left 1/8
        0x2590 => canvas.box(half_w, 0, w, h, .on), // Right half
        0x2591 => canvas.box(0, 0, w, h, @enumFromInt(0x40)), // Light shade (25%)
        0x2592 => canvas.box(0, 0, w, h, @enumFromInt(0x80)), // Medium shade (50%)
        0x2593 => canvas.box(0, 0, w, h, @enumFromInt(0xc0)), // Dark shade (75%)
        0x2594 => canvas.box(0, 0, w, @divFloor(h, 8), .on), // Upper 1/8
        0x2595 => canvas.box(w - @divFloor(w, 8), 0, w, h, .on), // Right 1/8
        // Quadrants
        0x2596 => canvas.box(0, half_h, half_w, h, .on),
        0x2597 => canvas.box(half_w, half_h, w, h, .on),
        0x2598 => canvas.box(0, 0, half_w, half_h, .on),
        0x2599 => {
            canvas.box(0, 0, half_w, half_h, .on);
            canvas.box(0, half_h, w, h, .on);
        },
        0x259A => {
            canvas.box(0, 0, half_w, half_h, .on);
            canvas.box(half_w, half_h, w, h, .on);
        },
        0x259B => {
            canvas.box(0, 0, w, half_h, .on);
            canvas.box(0, half_h, half_w, h, .on);
        },
        0x259C => {
            canvas.box(0, 0, w, half_h, .on);
            canvas.box(half_w, half_h, w, h, .on);
        },
        0x259D => canvas.box(half_w, 0, w, half_h, .on),
        0x259E => {
            canvas.box(half_w, 0, w, half_h, .on);
            canvas.box(0, half_h, half_w, h, .on);
        },
        0x259F => {
            canvas.box(half_w, 0, w, half_h, .on);
            canvas.box(0, half_h, w, h, .on);
        },
        else => {},
    }
}

/// Draw powerline symbols (U+E0B0 - U+E0B3)
fn drawPowerline(codepoint: u32, canvas: *Canvas, metrics: Metrics) !void {
    const w: f64 = @floatFromInt(metrics.cell_width);
    const h: f64 = @floatFromInt(metrics.cell_height);

    switch (codepoint) {
        // Right-pointing solid triangle
        0xE0B0 => {
            try canvas.triangle(.{
                .p0 = .{ .x = 0, .y = 0 },
                .p1 = .{ .x = w, .y = h / 2 },
                .p2 = .{ .x = 0, .y = h },
            }, .on);
        },
        // Right-pointing arrow (outline)
        0xE0B1 => {
            const thickness: f64 = @floatFromInt(@max(metrics.box_thickness, 1));
            try canvas.line(.{
                .p0 = .{ .x = 0, .y = 0 },
                .p1 = .{ .x = w, .y = h / 2 },
            }, thickness, .on);
            try canvas.line(.{
                .p0 = .{ .x = w, .y = h / 2 },
                .p1 = .{ .x = 0, .y = h },
            }, thickness, .on);
        },
        // Left-pointing solid triangle
        0xE0B2 => {
            try canvas.triangle(.{
                .p0 = .{ .x = w, .y = 0 },
                .p1 = .{ .x = 0, .y = h / 2 },
                .p2 = .{ .x = w, .y = h },
            }, .on);
        },
        // Left-pointing arrow (outline)
        0xE0B3 => {
            const thickness: f64 = @floatFromInt(@max(metrics.box_thickness, 1));
            try canvas.line(.{
                .p0 = .{ .x = w, .y = 0 },
                .p1 = .{ .x = 0, .y = h / 2 },
            }, thickness, .on);
            try canvas.line(.{
                .p0 = .{ .x = 0, .y = h / 2 },
                .p1 = .{ .x = w, .y = h },
            }, thickness, .on);
        },
        else => {},
    }
}
