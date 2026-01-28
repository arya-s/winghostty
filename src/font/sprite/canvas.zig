//! Canvas for drawing sprites using z2d.
//!
//! This is adapted from Ghostty's sprite canvas implementation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");

pub fn Point(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

pub fn Line(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),
    };
}

pub fn Box(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),

        pub fn rect(self: Box(T)) Rect(T) {
            const tl_x = @min(self.p0.x, self.p1.x);
            const tl_y = @min(self.p0.y, self.p1.y);
            const br_x = @max(self.p0.x, self.p1.x);
            const br_y = @max(self.p0.y, self.p1.y);

            return .{
                .x = tl_x,
                .y = tl_y,
                .width = br_x - tl_x,
                .height = br_y - tl_y,
            };
        }
    };
}

pub fn Rect(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        width: T,
        height: T,
    };
}

pub fn Triangle(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),
        p2: Point(T),
    };
}

pub fn Quad(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),
        p2: Point(T),
        p3: Point(T),
    };
}

/// We only use alpha-channel so a pixel can only be "on" or "off".
pub const Color = enum(u8) {
    on = 255,
    off = 0,
    _,
};

/// Canvas for drawing sprites using z2d.
pub const Canvas = struct {
    /// The underlying z2d surface.
    sfc: z2d.Surface,

    width: u32,
    height: u32,
    padding_x: u32,
    padding_y: u32,

    /// Clipping bounds (set by trim())
    clip_top: u32 = 0,
    clip_bottom: u32 = 0,
    clip_left: u32 = 0,
    clip_right: u32 = 0,

    alloc: Allocator,

    pub fn init(
        alloc: Allocator,
        width: u32,
        height: u32,
        padding_x: u32,
        padding_y: u32,
    ) !Canvas {
        // Create the surface we'll be using.
        // We add padding to both sides (hence `2 *`)
        const sfc = try z2d.Surface.initPixel(
            .{ .alpha8 = .{ .a = 0 } },
            alloc,
            @intCast(width + 2 * padding_x),
            @intCast(height + 2 * padding_y),
        );
        errdefer sfc.deinit(alloc);

        return .{
            .sfc = sfc,
            .width = width,
            .height = height,
            .padding_x = padding_x,
            .padding_y = padding_y,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.sfc.deinit(self.alloc);
        self.* = undefined;
    }

    /// Get the raw pixel data (for creating OpenGL texture)
    pub fn getPixels(self: *const Canvas) []const u8 {
        return std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);
    }

    /// Get actual surface dimensions (including padding)
    pub fn getSurfaceWidth(self: *const Canvas) u32 {
        return @intCast(self.sfc.getWidth());
    }

    pub fn getSurfaceHeight(self: *const Canvas) u32 {
        return @intCast(self.sfc.getHeight());
    }

    /// Trim empty rows/columns from the canvas bounds.
    /// This finds the actual bounding box of drawn content.
    /// Used by Ghostty to calculate proper glyph offsets.
    pub fn trim(self: *Canvas) void {
        const surf_width: u32 = @intCast(self.sfc.getWidth());
        const surf_height: u32 = @intCast(self.sfc.getHeight());

        const buf = std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);

        // Trim from top
        top: while (self.clip_top < surf_height - self.clip_bottom) {
            const y = self.clip_top;
            const x0 = self.clip_left;
            const x1 = surf_width - self.clip_right;
            for (buf[y * surf_width ..][x0..x1]) |v| {
                if (v != 0) break :top;
            }
            self.clip_top += 1;
        }

        // Trim from bottom
        bottom: while (self.clip_bottom < surf_height - self.clip_top) {
            const y = surf_height - self.clip_bottom -| 1;
            const x0 = self.clip_left;
            const x1 = surf_width - self.clip_right;
            for (buf[y * surf_width ..][x0..x1]) |v| {
                if (v != 0) break :bottom;
            }
            self.clip_bottom += 1;
        }

        // Trim from left
        left: while (self.clip_left < surf_width - self.clip_right) {
            const x = self.clip_left;
            const y0 = self.clip_top;
            const y1 = surf_height - self.clip_bottom;
            for (y0..y1) |y| {
                if (buf[y * surf_width + x] != 0) break :left;
            }
            self.clip_left += 1;
        }

        // Trim from right
        right: while (self.clip_right < surf_width - self.clip_left) {
            const x = surf_width - self.clip_right -| 1;
            const y0 = self.clip_top;
            const y1 = surf_height - self.clip_bottom;
            for (y0..y1) |y| {
                if (buf[y * surf_width + x] != 0) break :right;
            }
            self.clip_right += 1;
        }
    }

    /// Return a transformation representing the translation for our padding.
    pub fn transformation(self: Canvas) z2d.Transformation {
        return .{
            .ax = 1,
            .by = 0,
            .cx = 0,
            .dy = 1,
            .tx = @as(f64, @floatFromInt(self.padding_x)),
            .ty = @as(f64, @floatFromInt(self.padding_y)),
        };
    }

    /// Acquires a z2d drawing context, caller MUST deinit context.
    pub fn getContext(self: *Canvas) z2d.Context {
        var ctx = z2d.Context.init(self.alloc, &self.sfc);
        // Offset by our padding to keep coordinates relative to the cell.
        ctx.setTransformation(self.transformation());
        return ctx;
    }

    /// Draw and fill a single pixel
    pub fn pixel(self: *Canvas, x: i32, y: i32, color: Color) void {
        self.sfc.putPixel(
            x + @as(i32, @intCast(self.padding_x)),
            y + @as(i32, @intCast(self.padding_y)),
            .{ .alpha8 = .{ .a = @intFromEnum(color) } },
        );
    }

    /// Draw and fill a rectangle.
    pub fn rect(self: *Canvas, v: Rect(i32), color: Color) void {
        var y = v.y;
        while (y < v.y + v.height) : (y += 1) {
            var x = v.x;
            while (x < v.x + v.width) : (x += 1) {
                self.pixel(x, y, color);
            }
        }
    }

    /// Convenience wrapper for `Canvas.rect`
    pub fn box(
        self: *Canvas,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
        color: Color,
    ) void {
        self.rect((Box(i32){
            .p0 = .{ .x = x0, .y = y0 },
            .p1 = .{ .x = x1, .y = y1 },
        }).rect(), color);
    }

    /// Draw and fill a quad.
    pub fn quad(self: *Canvas, q: Quad(f64), color: Color) !void {
        var path = self.staticPath(6);
        path.moveTo(q.p0.x, q.p0.y);
        path.lineTo(q.p1.x, q.p1.y);
        path.lineTo(q.p2.x, q.p2.y);
        path.lineTo(q.p3.x, q.p3.y);
        path.close();
        try self.fillPath(path.wrapped_path, .{}, color);
    }

    /// Draw and fill a triangle.
    pub fn triangle(self: *Canvas, t: Triangle(f64), color: Color) !void {
        var path = self.staticPath(5);
        path.moveTo(t.p0.x, t.p0.y);
        path.lineTo(t.p1.x, t.p1.y);
        path.lineTo(t.p2.x, t.p2.y);
        path.close();
        try self.fillPath(path.wrapped_path, .{}, color);
    }

    /// Stroke a line.
    pub fn line(
        self: *Canvas,
        l: Line(f64),
        thickness: f64,
        color: Color,
    ) !void {
        var path = self.staticPath(2);
        path.moveTo(l.p0.x, l.p0.y);
        path.lineTo(l.p1.x, l.p1.y);
        try self.strokePath(
            path.wrapped_path,
            .{
                .line_cap_mode = .butt,
                .line_width = thickness,
            },
            color,
        );
    }

    /// Create a static path of the provided len and initialize it.
    pub inline fn staticPath(
        self: *Canvas,
        comptime len: usize,
    ) z2d.StaticPath(len) {
        var path: z2d.StaticPath(len) = .{};
        path.init();
        path.wrapped_path.transformation = self.transformation();
        return path;
    }

    /// Stroke a z2d path.
    pub fn strokePath(
        self: *Canvas,
        path: z2d.Path,
        opts: z2d.painter.StrokeOptions,
        color: Color,
    ) z2d.painter.StrokeError!void {
        try z2d.painter.stroke(
            self.alloc,
            &self.sfc,
            &.{ .opaque_pattern = .{
                .pixel = .{ .alpha8 = .{ .a = @intFromEnum(color) } },
            } },
            path.nodes.items,
            opts,
        );
    }

    /// Fill a z2d path.
    pub fn fillPath(
        self: *Canvas,
        path: z2d.Path,
        opts: z2d.painter.FillOptions,
        color: Color,
    ) z2d.painter.FillError!void {
        try z2d.painter.fill(
            self.alloc,
            &self.sfc,
            &.{ .opaque_pattern = .{
                .pixel = .{ .alpha8 = .{ .a = @intFromEnum(color) } },
            } },
            path.nodes.items,
            opts,
        );
    }

    /// Invert all pixels on the canvas.
    pub fn invert(self: *Canvas) void {
        for (std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf)) |*v| {
            v.* = 255 - v.*;
        }
    }

    /// Mirror the canvas horizontally.
    pub fn flipHorizontal(self: *Canvas) Allocator.Error!void {
        const buf = std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);
        const clone = try self.alloc.dupe(u8, buf);
        defer self.alloc.free(clone);
        const width: usize = @intCast(self.sfc.getWidth());
        const height: usize = @intCast(self.sfc.getHeight());
        for (0..height) |y| {
            for (0..width) |x| {
                buf[y * width + x] = clone[y * width + width - x - 1];
            }
        }
    }

    /// Mirror the canvas vertically.
    pub fn flipVertical(self: *Canvas) Allocator.Error!void {
        const buf = std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);
        const clone = try self.alloc.dupe(u8, buf);
        defer self.alloc.free(clone);
        const width: usize = @intCast(self.sfc.getWidth());
        const height: usize = @intCast(self.sfc.getHeight());
        for (0..height) |y| {
            for (0..width) |x| {
                buf[y * width + x] = clone[(height - y - 1) * width + x];
            }
        }
    }

    // Convenience methods for common drawing operations

    /// Draw a horizontal line
    pub fn hline(self: *Canvas, x1: i32, x2: i32, y: i32, thickness: u32) void {
        self.box(x1, y, x2, y + @as(i32, @intCast(thickness)), .on);
    }

    /// Draw a vertical line
    pub fn vline(self: *Canvas, x: i32, y1: i32, y2: i32, thickness: u32) void {
        self.box(x, y1, x + @as(i32, @intCast(thickness)), y2, .on);
    }
};
