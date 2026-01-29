const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const freetype = @import("freetype");
const Pty = @import("pty.zig").Pty;
const sprite = @import("font/sprite.zig");
const directwrite = @import("directwrite.zig");

const c = @cImport({
    @cInclude("glad/gl.h");
    @cInclude("GLFW/glfw3.h");
});

/// Convert FreeType 26.6 fixed-point to f64 (like Ghostty)
fn f26dot6ToF64(v: anytype) f64 {
    return @as(f64, @floatFromInt(v)) / 64.0;
}

// ============================================================================
// Font Discovery Test Functions (use --list-fonts or --test-font-discovery)
// ============================================================================

fn listSystemFonts(allocator: std.mem.Allocator) !void {
    std.debug.print("Listing system fonts via DirectWrite...\n\n", .{});

    var dw = directwrite.FontDiscovery.init() catch |err| {
        std.debug.print("Failed to initialize DirectWrite: {}\n", .{err});
        return err;
    };
    defer dw.deinit();

    const families = try dw.listFontFamilies(allocator);
    defer {
        for (families) |f| allocator.free(f);
        allocator.free(families);
    }

    std.debug.print("Found {} font families:\n", .{families.len});
    for (families, 0..) |family, i| {
        std.debug.print("  {d:4}. {s}\n", .{ i + 1, family });
    }
}

fn testFontDiscovery(allocator: std.mem.Allocator) !void {
    std.debug.print("Testing font discovery...\n\n", .{});

    var dw = directwrite.FontDiscovery.init() catch |err| {
        std.debug.print("Failed to initialize DirectWrite: {}\n", .{err});
        return err;
    };
    defer dw.deinit();

    // Test fonts to look for
    const test_fonts = [_][]const u8{
        "JetBrains Mono",
        "Cascadia Code",
        "Consolas",
        "Courier New",
        "Arial",
        "Segoe UI",
        "NonExistentFont12345",
    };

    for (test_fonts) |font_name| {
        std.debug.print("Looking for '{s}'... ", .{font_name});

        if (dw.findFontFilePath(allocator, font_name, .NORMAL, .NORMAL)) |maybe_result| {
            if (maybe_result) |result| {
                var r = result;
                defer r.deinit();
                std.debug.print("FOUND\n", .{});
                std.debug.print("  Path: {s}\n", .{result.path});
                std.debug.print("  Face index: {}\n\n", .{result.face_index});
            } else {
                std.debug.print("NOT FOUND\n\n", .{});
            }
        } else |err| {
            std.debug.print("ERROR: {}\n\n", .{err});
        }
    }
}

// Global pointers for GLFW callbacks
var g_pty: ?*Pty = null;
var g_terminal: ?*ghostty_vt.Terminal = null;
var g_window: ?*c.GLFWwindow = null;
var g_allocator: ?std.mem.Allocator = null;

// Selection state
const Selection = struct {
    start_col: usize,
    start_row: usize,
    end_col: usize,
    end_row: usize,
    active: bool,
};
var g_selection: Selection = .{
    .start_col = 0,
    .start_row = 0,
    .end_col = 0,
    .end_row = 0,
    .active = false,
};
var g_selecting: bool = false; // True while mouse button is held
var g_click_x: f64 = 0; // X position of initial click (for threshold calculation)
var g_click_y: f64 = 0; // Y position of initial click

// Embed the font
// Embedded fallback font (JetBrains Mono, like Ghostty)
const embedded = @import("font/embedded.zig");

// Terminal dimensions (initial, will be updated on resize)
var term_cols: u16 = 80;
var term_rows: u16 = 24;
const FONT_SIZE: u32 = 14;

// OpenGL context from glad
var gl: c.GladGLContext = undefined;

const Character = struct {
    texture_id: c.GLuint,
    size_x: i32,
    size_y: i32,
    bearing_x: i32,
    bearing_y: i32,
    advance: i64,
    valid: bool = false,
};

// Glyph cache using a hashmap for Unicode support
var glyph_cache: std.AutoHashMapUnmanaged(u32, Character) = .empty;
var glyph_face: ?freetype.Face = null;
var vao: c.GLuint = 0;
var vbo: c.GLuint = 0;
var shader_program: c.GLuint = 0;
var cell_width: f32 = 10;
var cell_height: f32 = 20;
var cell_baseline: f32 = 4; // Distance from bottom of cell to baseline
var cursor_height: f32 = 16; // Height of cursor (ascender portion)
var box_thickness: u32 = 1; // Thickness for box drawing characters
var window_focused: bool = true; // Track window focus state

// Pending resize state (resize is deferred to main loop to avoid PageList integrity issues)
// Ghostty coalesces resize events with a 25ms timer to batch rapid resizes
var g_pending_resize: bool = false;
var g_pending_cols: u16 = 0;
var g_pending_rows: u16 = 0;
var g_last_resize_time: i64 = 0;
var g_resize_in_progress: bool = false; // Prevent rendering during resize
const RESIZE_COALESCE_MS: i64 = 25; // Same as Ghostty

// Cursor configuration (like Ghostty)
const CursorStyle = enum {
    block,
    bar,
    underline,
    block_hollow,
};

var g_cursor_style: CursorStyle = .block; // Default cursor style
var g_cursor_blink: bool = true; // Whether cursor should blink (default: true like Ghostty)
var g_cursor_blink_visible: bool = true; // Current blink state (toggled by timer)
var g_last_blink_time: i64 = 0; // Timestamp of last blink toggle
const CURSOR_BLINK_INTERVAL_MS: i64 = 600; // Blink interval in ms (same as Ghostty)

// Font fallback system
var g_ft_lib: ?freetype.Library = null;
var g_font_discovery: ?*directwrite.FontDiscovery = null;
var g_fallback_faces: std.AutoHashMapUnmanaged(u32, freetype.Face) = .empty; // codepoint -> fallback face
var g_font_size: u32 = FONT_SIZE;

const vertex_shader_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec4 vertex;
    \\out vec2 TexCoords;
    \\uniform mat4 projection;
    \\void main() {
    \\    gl_Position = projection * vec4(vertex.xy, 0.0, 1.0);
    \\    TexCoords = vertex.zw;
    \\}
;

const fragment_shader_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 TexCoords;
    \\out vec4 color;
    \\uniform sampler2D text;
    \\uniform vec3 textColor;
    \\void main() {
    \\    vec4 sampled = vec4(1.0, 1.0, 1.0, texture(text, TexCoords).r);
    \\    color = vec4(textColor, 1.0) * sampled;
    \\}
;

fn compileShader(shader_type: c.GLenum, source: [*c]const u8) ?c.GLuint {
    const shader = gl.CreateShader.?(shader_type);
    gl.ShaderSource.?(shader, 1, &source, null);
    gl.CompileShader.?(shader);

    var success: c.GLint = 0;
    gl.GetShaderiv.?(shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        gl.GetShaderInfoLog.?(shader, 512, null, &info_log);
        std.debug.print("Shader compilation failed: {s}\n", .{&info_log});
        return null;
    }
    return shader;
}

fn initShaders() bool {
    const vertex_shader = compileShader(c.GL_VERTEX_SHADER, vertex_shader_source) orelse return false;
    defer gl.DeleteShader.?(vertex_shader);

    const fragment_shader = compileShader(c.GL_FRAGMENT_SHADER, fragment_shader_source) orelse return false;
    defer gl.DeleteShader.?(fragment_shader);

    shader_program = gl.CreateProgram.?();
    gl.AttachShader.?(shader_program, vertex_shader);
    gl.AttachShader.?(shader_program, fragment_shader);
    gl.LinkProgram.?(shader_program);

    var success: c.GLint = 0;
    gl.GetProgramiv.?(shader_program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        gl.GetProgramInfoLog.?(shader_program, 512, null, &info_log);
        std.debug.print("Shader linking failed: {s}\n", .{&info_log});
        return false;
    }

    return true;
}

fn initBuffers() void {
    gl.GenVertexArrays.?(1, &vao);
    gl.GenBuffers.?(1, &vbo);
    gl.BindVertexArray.?(vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(f32) * 6 * 4, null, c.GL_DYNAMIC_DRAW);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 4, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.BindVertexArray.?(0);
}

/// Load a single glyph into the cache
fn loadGlyph(codepoint: u32) ?Character {
    // Check if already cached
    if (glyph_cache.get(codepoint)) |ch| {
        return ch;
    }

    const alloc = g_allocator orelse return null;

    // Try sprite rendering first for special characters
    if (sprite.isSprite(codepoint)) {
        if (loadSpriteGlyph(codepoint, alloc)) |char_data| {
            glyph_cache.put(alloc, codepoint, char_data) catch return null;
            return char_data;
        }
    }

    // Fall back to FreeType font rendering
    const primary_face = glyph_face orelse return null;

    // Get glyph index for this codepoint from primary font
    var glyph_index = primary_face.getCharIndex(codepoint) orelse 0;
    var face_to_use = primary_face;

    // If glyph is missing (index 0), try to find a fallback font
    if (glyph_index == 0) {
        if (findOrLoadFallbackFace(codepoint, alloc)) |fallback| {
            const fallback_index = fallback.getCharIndex(codepoint) orelse 0;
            if (fallback_index != 0) {
                glyph_index = fallback_index;
                face_to_use = fallback;
            }
        }
    }

    // Use light hinting like Ghostty (matches most fontconfig-aware software)
    face_to_use.loadGlyph(@intCast(glyph_index), .{ .target = .light }) catch return null;
    face_to_use.renderGlyph(.light) catch return null;

    const glyph = face_to_use.handle.*.glyph;
    const bitmap = glyph.*.bitmap;

    var texture: c.GLuint = 0;
    gl.GenTextures.?(1, &texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, texture);
    gl.TexImage2D.?(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RED,
        @intCast(bitmap.width),
        @intCast(bitmap.rows),
        0,
        c.GL_RED,
        c.GL_UNSIGNED_BYTE,
        bitmap.buffer,
    );
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

    const char_data = Character{
        .texture_id = texture,
        .size_x = @intCast(bitmap.width),
        .size_y = @intCast(bitmap.rows),
        .bearing_x = glyph.*.bitmap_left,
        .bearing_y = glyph.*.bitmap_top,
        .advance = glyph.*.advance.x,
        .valid = true,
    };

    // Store in cache
    glyph_cache.put(alloc, codepoint, char_data) catch return null;

    return char_data;
}

/// Find or load a fallback font that contains the given codepoint
fn findOrLoadFallbackFace(codepoint: u32, alloc: std.mem.Allocator) ?freetype.Face {
    // Check if we already have a fallback for this codepoint
    if (g_fallback_faces.get(codepoint)) |face| {
        return face;
    }

    // Need DirectWrite and FreeType library to find fallbacks
    const dw = g_font_discovery orelse return null;
    const ft_lib = g_ft_lib orelse return null;

    // Use DirectWrite to find a font with this codepoint
    const maybe_font = dw.findFallbackFont(codepoint) catch return null;
    const font = maybe_font orelse return null;
    defer font.release();

    // Get the font face to extract file path
    const dw_face = font.createFontFace() catch return null;
    defer dw_face.release();

    // Get font file
    const font_file = dw_face.getFiles() catch return null;
    defer font_file.release();

    // Get file loader
    const loader = font_file.getLoader() catch return null;
    defer loader.release();

    // Get local font file loader
    const local_loader = loader.queryLocalFontFileLoader() orelse return null;
    defer local_loader.release();

    // Get reference key
    const ref_key = font_file.getReferenceKey() catch return null;

    // Get path length
    const path_len = local_loader.getFilePathLengthFromKey(ref_key.key, ref_key.size) catch return null;

    // Allocate buffer for path
    var path_buf = alloc.alloc(u16, path_len + 1) catch return null;
    defer alloc.free(path_buf);

    // Get the path
    local_loader.getFilePathFromKey(ref_key.key, ref_key.size, path_buf) catch return null;

    // Convert to UTF-8
    const utf8_path = std.unicode.utf16LeToUtf8AllocZ(alloc, path_buf[0..path_len]) catch return null;
    defer alloc.free(utf8_path);

    const face_index = dw_face.getIndex();

    std.debug.print("Loading fallback font for U+{X:0>4}: {s}\n", .{ codepoint, utf8_path });

    // Load with FreeType
    const ft_face = ft_lib.initFace(utf8_path, @intCast(face_index)) catch return null;

    // Set size to match primary font
    ft_face.setCharSize(0, @as(i32, @intCast(g_font_size)) * 64, 96, 96) catch {
        ft_face.deinit();
        return null;
    };

    // Cache the fallback face for this codepoint
    g_fallback_faces.put(alloc, codepoint, ft_face) catch {
        ft_face.deinit();
        return null;
    };

    return ft_face;
}

/// Load a sprite glyph (box drawing, powerline, etc.)
fn loadSpriteGlyph(codepoint: u32, alloc: std.mem.Allocator) ?Character {
    const metrics = sprite.Metrics{
        .cell_width = @intFromFloat(cell_width),
        .cell_height = @intFromFloat(cell_height),
        .box_thickness = box_thickness,
    };

    var result = sprite.renderSprite(alloc, codepoint, metrics) catch return null;
    if (result == null) return null;

    defer result.?.deinit();

    const r = result.?;

    // Extract only the trimmed region for the texture (like Ghostty's writeAtlas)
    // We need to copy row by row since the trimmed region is smaller than the surface
    var trimmed_data = alloc.alloc(u8, r.width * r.height) catch return null;
    defer alloc.free(trimmed_data);

    const src_stride = r.surface_width;
    for (0..r.height) |y| {
        const src_y = y + r.clip_top;
        const src_start = src_y * src_stride + r.clip_left;
        const dst_start = y * r.width;
        @memcpy(trimmed_data[dst_start..][0..r.width], r.data[src_start..][0..r.width]);
    }

    // Create OpenGL texture from trimmed sprite data
    var texture: c.GLuint = 0;
    gl.GenTextures.?(1, &texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, texture);
    gl.TexImage2D.?(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RED,
        @intCast(r.width),
        @intCast(r.height),
        0,
        c.GL_RED,
        c.GL_UNSIGNED_BYTE,
        trimmed_data.ptr,
    );
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);

    // Calculate glyph offsets like Ghostty does:
    // Ghostty: offset_x = clip_left - padding_x  
    // Ghostty: offset_y = region.height + clip_bottom - padding_y
    //
    // Ghostty's offset_y is the distance from cell BOTTOM to glyph TOP.
    // 
    // Our renderChar formula: y0 = y + cell_baseline - (size_y - bearing_y)
    //                         glyph_top = y0 + size_y = y + cell_baseline + bearing_y
    //
    // We want glyph_top = y + offset_y (cell bottom + distance to glyph top)
    // So: y + cell_baseline + bearing_y = y + offset_y
    // Thus: bearing_y = offset_y - cell_baseline
    const offset_x: i32 = @as(i32, @intCast(r.clip_left)) - @as(i32, @intCast(r.padding_x));
    var offset_y: i32 = @as(i32, @intCast(r.height + r.clip_bottom)) - @as(i32, @intCast(r.padding_y));
    const baseline_i: i32 = @intFromFloat(cell_baseline);

    // For braille (no trim, no padding), offset_y = cell_height, meaning glyph top = cell top.
    // But braille should sit ON the baseline like text, not fill from cell top.
    // Experimentally: subtracting full baseline (6) is too low, 0 is too high.
    // Try half the baseline as a compromise.
    if (codepoint >= 0x2800 and codepoint <= 0x28FF) {
        offset_y -= @divFloor(baseline_i, 2);
    }

    const bearing_y = offset_y - baseline_i;

    return Character{
        .texture_id = texture,
        .size_x = @intCast(r.width),
        .size_y = @intCast(r.height),
        .bearing_x = offset_x,
        .bearing_y = bearing_y,
        .advance = @as(i64, @intCast(r.cell_width)) << 6, // Cell width in 26.6 fixed point
        .valid = true,
    };
}

/// Preload common character ranges
fn preloadCharacters(face: freetype.Face) void {
    gl.PixelStorei.?(c.GL_UNPACK_ALIGNMENT, 1);

    // Store face for later on-demand loading
    glyph_face = face;

    std.debug.print("Starting glyph preload, g_allocator set: {}\n", .{g_allocator != null});

    // Calculate cell dimensions FIRST from font metrics (like Ghostty)
    // This must happen before loading sprites so they use correct dimensions
    //
    // Cell width is the maximum advance of all visible ASCII characters (like Ghostty)
    // This ensures proper spacing for monospace fonts
    {
        var max_advance: f64 = 0;
        var ascii_char: u8 = ' ';
        while (ascii_char < 127) : (ascii_char += 1) {
            if (loadGlyph(ascii_char)) |char| {
                const advance = @as(f64, @floatFromInt(char.advance)) / 64.0; // 26.6 fixed point
                max_advance = @max(max_advance, advance);
            }
        }
        if (max_advance > 0) {
            cell_width = @floatCast(max_advance);
        }
    }

    if (loadGlyph('M')) |_| {

        // Get metrics like Ghostty does - from font tables with fallback to FreeType
        const size_metrics = face.handle.*.size.*.metrics;
        const px_per_em: f64 = @floatFromInt(size_metrics.y_ppem);

        // Get units_per_em from head table or FreeType
        const units_per_em: f64 = blk: {
            if (face.getSfntTable(.head)) |head| {
                break :blk @floatFromInt(head.Units_Per_EM);
            }
            if (face.handle.*.face_flags & freetype.c.FT_FACE_FLAG_SCALABLE != 0) {
                break :blk @floatFromInt(face.handle.*.units_per_EM);
            }
            break :blk @floatFromInt(size_metrics.y_ppem);
        };
        const px_per_unit = px_per_em / units_per_em;

        // Get vertical metrics from font tables (like Ghostty)
        const ascent: f64, const descent: f64, const line_gap: f64 = vertical_metrics: {
            const hhea_ = face.getSfntTable(.hhea);
            const os2_ = face.getSfntTable(.os2);

            // If no hhea table, fall back to FreeType metrics
            const hhea = hhea_ orelse {
                const ft_ascender = f26dot6ToF64(size_metrics.ascender);
                const ft_descender = f26dot6ToF64(size_metrics.descender);
                const ft_height = f26dot6ToF64(size_metrics.height);
                break :vertical_metrics .{
                    ft_ascender,
                    ft_descender,
                    ft_height + ft_descender - ft_ascender,
                };
            };

            const hhea_ascent: f64 = @floatFromInt(hhea.Ascender);
            const hhea_descent: f64 = @floatFromInt(hhea.Descender);
            const hhea_line_gap: f64 = @floatFromInt(hhea.Line_Gap);

            // If no OS/2 table, use hhea metrics
            const os2 = os2_ orelse break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };

            // Check for invalid OS/2 table
            if (os2.version == 0xFFFF) break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };

            const os2_ascent: f64 = @floatFromInt(os2.sTypoAscender);
            const os2_descent: f64 = @floatFromInt(os2.sTypoDescender);
            const os2_line_gap: f64 = @floatFromInt(os2.sTypoLineGap);

            // If USE_TYPO_METRICS bit is set (bit 7), use OS/2 typo metrics
            if (os2.fsSelection & (1 << 7) != 0) {
                break :vertical_metrics .{
                    os2_ascent * px_per_unit,
                    os2_descent * px_per_unit,
                    os2_line_gap * px_per_unit,
                };
            }

            // Otherwise prefer hhea if available
            if (hhea.Ascender != 0 or hhea.Descender != 0) {
                break :vertical_metrics .{
                    hhea_ascent * px_per_unit,
                    hhea_descent * px_per_unit,
                    hhea_line_gap * px_per_unit,
                };
            }

            // Fall back to OS/2 sTypo metrics
            if (os2_ascent != 0 or os2_descent != 0) {
                break :vertical_metrics .{
                    os2_ascent * px_per_unit,
                    os2_descent * px_per_unit,
                    os2_line_gap * px_per_unit,
                };
            }

            // Last resort: OS/2 usWin metrics
            const win_ascent: f64 = @floatFromInt(os2.usWinAscent);
            const win_descent: f64 = @floatFromInt(os2.usWinDescent);
            break :vertical_metrics .{
                win_ascent * px_per_unit,
                -win_descent * px_per_unit, // usWinDescent is positive, flip sign
                0.0,
            };
        };

        // Calculate cell dimensions like Ghostty
        const face_height = ascent - descent + line_gap;
        cell_height = @floatCast(@round(face_height));

        // Split line gap in half for top/bottom padding (like Ghostty)
        const half_line_gap = line_gap / 2.0;

        // Calculate baseline from bottom of cell (like Ghostty)
        // face_baseline = half_line_gap - descent (descent is negative, so this adds)
        const face_baseline = half_line_gap - descent;
        // Center the baseline by accounting for rounding difference
        const baseline_centered = face_baseline - (cell_height - face_height) / 2.0;
        cell_baseline = @floatCast(@round(baseline_centered));

        // Cursor height is the ascender
        cursor_height = @floatCast(@round(ascent));

        // Get underline thickness from post table for box drawing (like Ghostty)
        const underline_thickness: f64 = ul_thick: {
            if (face.getSfntTable(.post)) |post| {
                if (post.underlineThickness != 0) {
                    break :ul_thick @as(f64, @floatFromInt(post.underlineThickness)) * px_per_unit;
                }
            }
            // Fallback: use a reasonable default based on cell height
            break :ul_thick @max(1.0, @round(cell_height / 16.0));
        };
        // Use ceiling like Ghostty
        box_thickness = @max(1, @as(u32, @intFromFloat(@ceil(underline_thickness))));

        std.debug.print("Cell dimensions: {d:.0}x{d:.0} (ascent={d:.1}, descent={d:.1}, line_gap={d:.1}, baseline={d:.0}, box_thick={})\n", .{
            cell_width, cell_height, ascent, descent, line_gap, cell_baseline, box_thickness,
        });
    } else {
        std.debug.print("ERROR: Could not load 'M' glyph!\n", .{});
    }

    // Preload ASCII printable characters (32-126)
    var ascii_loaded: u32 = 0;
    for (32..127) |char| {
        if (loadGlyph(@intCast(char)) != null) {
            ascii_loaded += 1;
        }
    }
    std.debug.print("ASCII glyphs loaded: {}\n", .{ascii_loaded});

    // Preload box drawing characters (U+2500 - U+257F)
    var box_loaded: u32 = 0;
    for (0x2500..0x2580) |char| {
        if (loadGlyph(@intCast(char)) != null) {
            box_loaded += 1;
        }
    }
    std.debug.print("Box drawing glyphs loaded: {}\n", .{box_loaded});

    // Preload block elements (U+2580 - U+259F)
    for (0x2580..0x25A0) |char| {
        _ = loadGlyph(@intCast(char));
    }

    std.debug.print("Total glyphs in cache: {}\n", .{glyph_cache.count()});
}

fn indexToRgb(color_idx: u8) [3]f32 {
    // Basic 16 colors matching Ghostty's default palette
    const basic_colors = [16][3]f32{
        .{ @as(f32, 0x1D) / 255.0, @as(f32, 0x1F) / 255.0, @as(f32, 0x21) / 255.0 }, // 0: black
        .{ @as(f32, 0xCC) / 255.0, @as(f32, 0x66) / 255.0, @as(f32, 0x66) / 255.0 }, // 1: red
        .{ @as(f32, 0xB5) / 255.0, @as(f32, 0xBD) / 255.0, @as(f32, 0x68) / 255.0 }, // 2: green
        .{ @as(f32, 0xF0) / 255.0, @as(f32, 0xC6) / 255.0, @as(f32, 0x74) / 255.0 }, // 3: yellow
        .{ @as(f32, 0x81) / 255.0, @as(f32, 0xA2) / 255.0, @as(f32, 0xBE) / 255.0 }, // 4: blue
        .{ @as(f32, 0xB2) / 255.0, @as(f32, 0x94) / 255.0, @as(f32, 0xBB) / 255.0 }, // 5: magenta
        .{ @as(f32, 0x8A) / 255.0, @as(f32, 0xBE) / 255.0, @as(f32, 0xB7) / 255.0 }, // 6: cyan
        .{ @as(f32, 0xC5) / 255.0, @as(f32, 0xC8) / 255.0, @as(f32, 0xC6) / 255.0 }, // 7: white
        .{ @as(f32, 0x66) / 255.0, @as(f32, 0x66) / 255.0, @as(f32, 0x66) / 255.0 }, // 8: bright black (gray)
        .{ @as(f32, 0xD5) / 255.0, @as(f32, 0x4E) / 255.0, @as(f32, 0x53) / 255.0 }, // 9: bright red
        .{ @as(f32, 0xB9) / 255.0, @as(f32, 0xCA) / 255.0, @as(f32, 0x4A) / 255.0 }, // 10: bright green
        .{ @as(f32, 0xE7) / 255.0, @as(f32, 0xC5) / 255.0, @as(f32, 0x47) / 255.0 }, // 11: bright yellow
        .{ @as(f32, 0x7A) / 255.0, @as(f32, 0xA6) / 255.0, @as(f32, 0xDA) / 255.0 }, // 12: bright blue
        .{ @as(f32, 0xC3) / 255.0, @as(f32, 0x97) / 255.0, @as(f32, 0xD8) / 255.0 }, // 13: bright magenta
        .{ @as(f32, 0x70) / 255.0, @as(f32, 0xC0) / 255.0, @as(f32, 0xB1) / 255.0 }, // 14: bright cyan
        .{ @as(f32, 0xEA) / 255.0, @as(f32, 0xEA) / 255.0, @as(f32, 0xEA) / 255.0 }, // 15: bright white
    };

    if (color_idx < 16) {
        return basic_colors[color_idx];
    } else if (color_idx < 232) {
        // 216 color cube (6x6x6): indices 16-231
        const idx = color_idx - 16;
        const r = idx / 36;
        const g = (idx / 6) % 6;
        const b = idx % 6;
        return .{
            if (r == 0) 0.0 else (@as(f32, @floatFromInt(r)) * 40.0 + 55.0) / 255.0,
            if (g == 0) 0.0 else (@as(f32, @floatFromInt(g)) * 40.0 + 55.0) / 255.0,
            if (b == 0) 0.0 else (@as(f32, @floatFromInt(b)) * 40.0 + 55.0) / 255.0,
        };
    } else {
        // Grayscale: indices 232-255 (24 shades)
        const gray = (@as(f32, @floatFromInt(color_idx - 232)) * 10.0 + 8.0) / 255.0;
        return .{ gray, gray, gray };
    }
}

fn renderChar(codepoint: u32, x: f32, y: f32, color: [3]f32) void {
    // Skip control characters
    if (codepoint < 32) return;

    // Get character from cache (load on-demand if needed)
    const ch: Character = loadGlyph(codepoint) orelse return;

    // Position glyph relative to baseline (like Ghostty)
    // y = cell bottom, cell_baseline = distance from cell bottom to baseline
    // bearing_y (bitmap_top) = distance from baseline to glyph top
    // y0 = glyph bottom = cell_bottom + cell_baseline + bearing_y - glyph_height
    const x0 = x + @as(f32, @floatFromInt(ch.bearing_x));
    const y0 = y + cell_baseline - @as(f32, @floatFromInt(ch.size_y - ch.bearing_y));
    const w = @as(f32, @floatFromInt(ch.size_x));
    const h = @as(f32, @floatFromInt(ch.size_y));

    const vertices = [6][4]f32{
        .{ x0, y0 + h, 0.0, 0.0 },
        .{ x0, y0, 0.0, 1.0 },
        .{ x0 + w, y0, 1.0, 1.0 },
        .{ x0, y0 + h, 0.0, 0.0 },
        .{ x0 + w, y0, 1.0, 1.0 },
        .{ x0 + w, y0 + h, 1.0, 0.0 },
    };

    gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), color[0], color[1], color[2]);
    gl.BindTexture.?(c.GL_TEXTURE_2D, ch.texture_id);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
}

fn renderTerminal(terminal: *ghostty_vt.Terminal, window_height: f32, offset_x: f32, offset_y: f32) void {
    gl.UseProgram.?(shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(vao);

    const screen = terminal.screens.active;

    // Get cursor position - only show cursor when viewport is at the bottom
    const cursor_x = screen.cursor.x;
    const cursor_y = screen.cursor.y;
    const viewport_at_bottom = screen.pages.viewport == .active;

    // Get terminal-controlled cursor style (set by DECSCUSR escape sequence)
    // This is what programs like vim use to change cursor shape
    const terminal_cursor_style: TerminalCursorStyle = switch (screen.cursor.cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };

    // Get terminal-controlled cursor blink mode (also set by DECSCUSR)
    // Steady styles (2, 4, 6) set this to false, blinking styles (1, 3, 5) set it to true
    const terminal_cursor_blink = terminal.modes.get(.cursor_blinking);

    // Use terminal's actual dimensions for rendering (not global vars which may be out of sync)
    const render_rows = terminal.rows;
    const render_cols = terminal.cols;

    for (0..render_rows) |row_idx| {
        // Row 0 is at the top, so we start from (window_height - offset) and go down
        const y = window_height - offset_y - ((@as(f32, @floatFromInt(row_idx)) + 1) * cell_height);

        for (0..render_cols) |col_idx| {
            const x = offset_x + @as(f32, @floatFromInt(col_idx)) * cell_width;

            // Check if this is the cursor position (only when viewport is at bottom)
            const is_cursor = viewport_at_bottom and (col_idx == cursor_x and row_idx == cursor_y);

            // Get cell from the page list
            const cell_data = screen.pages.getCell(.{ .viewport = .{
                .x = @intCast(col_idx),
                .y = @intCast(row_idx),
            } });
            


            // Get foreground color from cell style
            var fg_color: [3]f32 = .{ 0.9, 0.9, 0.9 }; // Default light gray
            var bg_color: ?[3]f32 = null;

            if (cell_data) |cd| {
                const cell = cd.cell;

                // Check for background-only cells (used by erase operations like \e[K)
                // These cells have no text but store a background color directly
                switch (cell.content_tag) {
                    .bg_color_palette => {
                        bg_color = indexToRgb(cell.content.color_palette);
                    },
                    .bg_color_rgb => {
                        const rgb = cell.content.color_rgb;
                        bg_color = .{
                            @as(f32, @floatFromInt(rgb.r)) / 255.0,
                            @as(f32, @floatFromInt(rgb.g)) / 255.0,
                            @as(f32, @floatFromInt(rgb.b)) / 255.0,
                        };
                    },
                    else => {},
                }

                // Get style if available (for text cells with styling)
                if (cell.hasStyling()) {
                    const style = cd.node.data.styles.get(
                        cd.node.data.memory,
                        cell.style_id,
                    );
                    // Foreground color
                    switch (style.fg_color) {
                        .none => {},
                        .palette => |idx| fg_color = indexToRgb(idx),
                        .rgb => |rgb| fg_color = .{
                            @as(f32, @floatFromInt(rgb.r)) / 255.0,
                            @as(f32, @floatFromInt(rgb.g)) / 255.0,
                            @as(f32, @floatFromInt(rgb.b)) / 255.0,
                        },
                    }
                    // Background color from style (overrides bg-only cell color)
                    switch (style.bg_color) {
                        .none => {},
                        .palette => |idx| bg_color = indexToRgb(idx),
                        .rgb => |rgb| bg_color = .{
                            @as(f32, @floatFromInt(rgb.r)) / 255.0,
                            @as(f32, @floatFromInt(rgb.g)) / 255.0,
                            @as(f32, @floatFromInt(rgb.b)) / 255.0,
                        },
                    }
                }
            }

            // Check if cell is selected
            const is_selected = isCellSelected(col_idx, row_idx);

            // Draw cursor (with style and blink support like Ghostty)
            if (is_cursor) {
                const cursor_result = renderCursor(x, y, cell_width, cell_height, terminal_cursor_style, terminal_cursor_blink);
                if (cursor_result.invert_fg) {
                    fg_color = .{ 0.0, 0.0, 0.0 }; // Black text on cursor
                }
            } else if (is_selected) {
                renderQuad(x, y, cell_width, cell_height, .{ 0.3, 0.4, 0.6 }); // Selection blue
                fg_color = .{ 1.0, 1.0, 1.0 }; // White text on selection
            } else if (bg_color) |bg| {
                renderQuad(x, y, cell_width, cell_height, bg);
            }

            // Render character if present
            if (cell_data) |cd| {
                const char = cd.cell.codepoint();
                if (char != 0 and char != ' ') {
                    renderChar(char, x, y, fg_color);
                }
            }
        }
    }

    gl.BindVertexArray.?(0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, 0);
}

// Solid white texture for drawing filled quads
var solid_texture: c.GLuint = 0;

fn initSolidTexture() void {
    const white_pixel = [_]u8{ 255 };
    gl.GenTextures.?(1, &solid_texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, solid_texture);
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RED, 1, 1, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, &white_pixel);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
}

fn renderQuad(x: f32, y: f32, w: f32, h: f32, color: [3]f32) void {
    const vertices = [6][4]f32{
        .{ x, y + h, 0.0, 0.0 },
        .{ x, y, 0.0, 1.0 },
        .{ x + w, y, 1.0, 1.0 },
        .{ x, y + h, 0.0, 0.0 },
        .{ x + w, y, 1.0, 1.0 },
        .{ x + w, y + h, 1.0, 0.0 },
    };

    gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), color[0], color[1], color[2]);
    gl.BindTexture.?(c.GL_TEXTURE_2D, solid_texture);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6);
}

/// Terminal cursor style (matches ghostty's terminal/cursor.zig)
/// Set by DECSCUSR escape sequence from programs like vim
const TerminalCursorStyle = enum {
    bar,
    block,
    underline,
    block_hollow,
};

/// Render the cursor with style and blink support (like Ghostty)
/// Returns whether foreground should be inverted (for block cursor)
/// terminal_style is the style requested by the terminal (via DECSCUSR escape sequence)
/// terminal_blink is the blink mode from the terminal (set by DECSCUSR steady/blinking variants)
fn renderCursor(x: f32, y: f32, w: f32, h: f32, terminal_style: TerminalCursorStyle, terminal_blink: bool) struct { invert_fg: bool } {
    const cursor_color = [3]f32{ 0.7, 0.7, 0.7 };
    // Cursor thickness defaults to 1 pixel like Ghostty (metrics.cursor_thickness = 1)
    const cursor_thickness: f32 = 1.0;

    // Determine effective cursor style (like Ghostty's cursor.zig logic)
    // Priority: unfocused -> blink off -> terminal-controlled style -> configured style
    const effective_style: CursorStyle = blk: {
        // If not focused, always show hollow block
        if (!window_focused) break :blk .block_hollow;

        // Check if cursor should blink:
        // - terminal_blink: controlled by DECSCUSR (steady vs blinking variants)
        // - g_cursor_blink: user's --cursor-style-blink setting
        // Cursor blinks if BOTH are true (terminal wants blink AND user hasn't disabled it)
        const should_blink = terminal_blink and g_cursor_blink;
        if (should_blink and !g_cursor_blink_visible) {
            return .{ .invert_fg = false }; // Don't render cursor (blink off phase)
        }

        // Use terminal-controlled style (from DECSCUSR escape sequence)
        // This allows programs like vim to change cursor shape
        break :blk switch (terminal_style) {
            .block => .block,
            .bar => .bar,
            .underline => .underline,
            .block_hollow => .block_hollow,
        };
    };

    switch (effective_style) {
        .block => {
            // Solid filled block
            renderQuad(x, y, w, h, cursor_color);
            return .{ .invert_fg = true };
        },
        .block_hollow => {
            // Hollow rectangle - fill then hollow out the inside (like Ghostty)
            // Draw outer rect
            renderQuad(x, y, w, h, cursor_color);
            // Hollow out inside with background color
            const bg_color = [3]f32{ 0.05, 0.05, 0.08 }; // Match terminal background
            renderQuad(
                x + cursor_thickness,
                y + cursor_thickness,
                w - cursor_thickness * 2,
                h - cursor_thickness * 2,
                bg_color,
            );
            return .{ .invert_fg = false };
        },
        .bar => {
            // Vertical bar on left side of cell
            // Ghostty places bar cursor half thickness over left edge for centering
            renderQuad(x, y, cursor_thickness, h, cursor_color);
            return .{ .invert_fg = false };
        },
        .underline => {
            // Horizontal line at bottom of cell
            renderQuad(x, y, w, cursor_thickness, cursor_color);
            return .{ .invert_fg = false };
        },
    }
}

/// Update cursor blink state based on time (call once per frame)
fn updateCursorBlink() void {
    if (!g_cursor_blink) {
        g_cursor_blink_visible = true;
        return;
    }

    const now = std.time.milliTimestamp();
    if (now - g_last_blink_time >= CURSOR_BLINK_INTERVAL_MS) {
        g_cursor_blink_visible = !g_cursor_blink_visible;
        g_last_blink_time = now;
    }
}

/// Reset cursor blink to visible state (call on keypress like Ghostty)
fn resetCursorBlink() void {
    g_cursor_blink_visible = true;
    g_last_blink_time = std.time.milliTimestamp();
}

// GLFW character callback - handles regular text input
fn charCallback(_: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    if (g_pty) |pty| {
        // Reset cursor blink on keystroke (like Ghostty)
        resetCursorBlink();

        // Scroll viewport to bottom when typing
        if (g_terminal) |term| {
            term.scrollViewport(.bottom) catch {};
        }
        // Convert unicode codepoint to UTF-8
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return;
        _ = pty.write(buf[0..len]) catch {};
    }
}

// Convert mouse position to terminal cell coordinates
fn mouseToCell(xpos: f64, ypos: f64) struct { col: usize, row: usize } {
    const padding: f64 = 10;
    const col_f = (xpos - padding) / @as(f64, cell_width);
    const row_f = (ypos - padding) / @as(f64, cell_height);
    
    const col = if (col_f < 0) 0 else if (col_f >= @as(f64, @floatFromInt(term_cols))) term_cols - 1 else @as(usize, @intFromFloat(col_f));
    const row = if (row_f < 0) 0 else if (row_f >= @as(f64, @floatFromInt(term_rows))) term_rows - 1 else @as(usize, @intFromFloat(row_f));
    
    return .{ .col = col, .row = row };
}

// GLFW mouse button callback
fn mouseButtonCallback(window: ?*c.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.c) void {
    if (button == c.GLFW_MOUSE_BUTTON_LEFT) {
        var xpos: f64 = 0;
        var ypos: f64 = 0;
        c.glfwGetCursorPos(window, &xpos, &ypos);
        const cell = mouseToCell(xpos, ypos);
        
        if (action == c.GLFW_PRESS) {
            // Start selection - record click position for threshold calculation
            g_selection.start_col = cell.col;
            g_selection.start_row = cell.row;
            g_selection.end_col = cell.col;
            g_selection.end_row = cell.row;
            g_selection.active = false; // Don't activate until we confirm it's a real selection
            g_selecting = true;
            g_click_x = xpos;
            g_click_y = ypos;
        } else if (action == c.GLFW_RELEASE) {
            g_selecting = false;
            // Selection remains active if it was activated during drag
        }
    }
}

// GLFW cursor position callback - update selection while dragging
fn cursorPosCallback(_: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
    if (g_selecting) {
        const cell = mouseToCell(xpos, ypos);
        g_selection.end_col = cell.col;
        g_selection.end_row = cell.row;
        
        // Use threshold-based selection like Ghostty (60% of cell width)
        // This determines if we've dragged enough to create a real selection
        const threshold = cell_width * 0.6;
        const padding: f64 = 10;
        
        // Calculate position within cells
        const click_cell_x = g_click_x - padding - @as(f64, @floatFromInt(g_selection.start_col)) * @as(f64, cell_width);
        const drag_cell_x = xpos - padding - @as(f64, @floatFromInt(cell.col)) * @as(f64, cell_width);
        
        const same_cell = (g_selection.start_col == cell.col and g_selection.start_row == cell.row);
        
        if (same_cell) {
            // Same cell - check if we've crossed the threshold in either direction
            const moved_right = drag_cell_x >= threshold and click_cell_x < threshold;
            const moved_left = drag_cell_x < threshold and click_cell_x >= threshold;
            g_selection.active = moved_right or moved_left;
        } else {
            // Different cells - always activate selection
            g_selection.active = true;
        }
    }
}

// Copy current selection to clipboard
fn copySelectionToClipboard() void {
    const terminal = g_terminal orelse return;
    const window = g_window orelse return;
    const allocator = g_allocator orelse return;
    
    if (!g_selection.active) return;
    
    // Normalize selection (start before end)
    var start_row = g_selection.start_row;
    var start_col = g_selection.start_col;
    var end_row = g_selection.end_row;
    var end_col = g_selection.end_col;
    
    if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
        std.mem.swap(usize, &start_row, &end_row);
        std.mem.swap(usize, &start_col, &end_col);
    }
    
    // Build selection string
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(allocator);
    
    const screen = terminal.screens.active;
    
    var row: usize = start_row;
    while (row <= end_row) : (row += 1) {
        const row_start_col = if (row == start_row) start_col else 0;
        const row_end_col = if (row == end_row) end_col else term_cols - 1;
        
        var col: usize = row_start_col;
        while (col <= row_end_col) : (col += 1) {
            const cell_data = screen.pages.getCell(.{ .viewport = .{
                .x = @intCast(col),
                .y = @intCast(row),
            } }) orelse continue;
            
            const cp = cell_data.cell.codepoint();
            if (cp == 0 or cp == ' ') {
                text.append(allocator, ' ') catch continue;
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
                text.appendSlice(allocator, buf[0..len]) catch continue;
            }
        }
        
        // Add newline between rows (but not after last row)
        if (row < end_row) {
            text.append(allocator, '\n') catch {};
        }
    }
    
    // Set clipboard - need null terminated string
    if (text.items.len > 0) {
        text.append(allocator, 0) catch return;
        const str: [*:0]const u8 = @ptrCast(text.items.ptr);
        c.glfwSetClipboardString(window, str);
        std.debug.print("Copied {} bytes to clipboard\n", .{text.items.len - 1});
    }
}

// Paste from clipboard
fn pasteFromClipboard() void {
    const pty = g_pty orelse return;
    const window = g_window orelse return;
    
    const clipboard = c.glfwGetClipboardString(window);
    if (clipboard) |str| {
        // Find length
        var len: usize = 0;
        while (str[len] != 0) : (len += 1) {}
        std.debug.print("Pasting {} bytes from clipboard\n", .{len});
        if (len > 0) {
            _ = pty.write(str[0..len]) catch {};
        }
    } else {
        std.debug.print("Clipboard is empty or unavailable\n", .{});
    }
}

// Check if a cell is within the current selection
fn isCellSelected(col: usize, row: usize) bool {
    if (!g_selection.active) return false;
    
    var start_row = g_selection.start_row;
    var start_col = g_selection.start_col;
    var end_row = g_selection.end_row;
    var end_col = g_selection.end_col;
    
    // Normalize
    if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
        std.mem.swap(usize, &start_row, &end_row);
        std.mem.swap(usize, &start_col, &end_col);
    }
    
    if (row < start_row or row > end_row) return false;
    if (row == start_row and row == end_row) {
        return col >= start_col and col <= end_col;
    }
    if (row == start_row) return col >= start_col;
    if (row == end_row) return col <= end_col;
    return true;
}

// GLFW window resize callback
fn windowFocusCallback(_: ?*c.GLFWwindow, focused: c_int) callconv(.c) void {
    window_focused = focused != 0;
}

fn framebufferSizeCallback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    const padding: f32 = 10;
    const content_width = @as(f32, @floatFromInt(width)) - padding * 2;
    const content_height = @as(f32, @floatFromInt(height)) - padding * 2;

    const new_cols: u16 = @intFromFloat(@max(1, content_width / cell_width));
    const new_rows: u16 = @intFromFloat(@max(1, content_height / cell_height));

    if (new_cols != term_cols or new_rows != term_rows) {
        // Mark resize as pending - actual resize happens in main loop
        // to avoid PageList integrity issues during callback
        // Coalesce rapid resize events (like Ghostty does with 25ms timer)
        g_pending_resize = true;
        g_pending_cols = new_cols;
        g_pending_rows = new_rows;
        g_last_resize_time = std.time.milliTimestamp();
    }

    // Immediately render a frame during resize to avoid black areas
    // We render with current terminal state (before resize) to show something
    gl.Viewport.?(0, 0, width, height);
    setProjection(@floatFromInt(width), @floatFromInt(height));

    gl.ClearColor.?(0.05, 0.05, 0.08, 1.0);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

    // Render terminal if available and not in the middle of a resize operation
    if (!g_resize_in_progress) {
        if (g_terminal) |terminal| {
            updateCursorBlink();
            renderTerminal(terminal, @floatFromInt(height), padding, padding);
        }
    }

    c.glfwSwapBuffers(window);
}

// GLFW scroll callback - handles mouse wheel scrollback
fn scrollCallback(_: ?*c.GLFWwindow, _: f64, yoffset: f64) callconv(.c) void {
    if (g_terminal) |terminal| {
        const delta: isize = @intFromFloat(-yoffset * 3); // 3 lines per scroll notch
        terminal.scrollViewport(.{ .delta = delta }) catch {};
    }
}

// GLFW key callback - handles special keys
fn keyCallback(_: ?*c.GLFWwindow, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
    if (action != c.GLFW_PRESS and action != c.GLFW_REPEAT) return;

    const ctrl = (mods & c.GLFW_MOD_CONTROL) != 0;
    const shift = (mods & c.GLFW_MOD_SHIFT) != 0;

    // Ctrl+Shift+C = Copy (selection already copied on mouse release, but allow manual too)
    if (ctrl and shift and key == c.GLFW_KEY_C) {
        copySelectionToClipboard();
        return;
    }

    // Ctrl+Shift+V = Paste
    if (ctrl and shift and key == c.GLFW_KEY_V) {
        pasteFromClipboard();
        return;
    }

    if (g_pty) |pty| {
        // Scroll viewport to bottom when typing (except for scroll keys and modifier-only presses)
        // This matches Ghostty's behavior: only scroll for non-modifier keys
        const is_scroll_key = shift and (key == c.GLFW_KEY_PAGE_UP or key == c.GLFW_KEY_PAGE_DOWN);
        const is_modifier = key == c.GLFW_KEY_LEFT_SHIFT or key == c.GLFW_KEY_RIGHT_SHIFT or
            key == c.GLFW_KEY_LEFT_CONTROL or key == c.GLFW_KEY_RIGHT_CONTROL or
            key == c.GLFW_KEY_LEFT_ALT or key == c.GLFW_KEY_RIGHT_ALT or
            key == c.GLFW_KEY_LEFT_SUPER or key == c.GLFW_KEY_RIGHT_SUPER;
        if (!is_scroll_key and !is_modifier) {
            // Reset cursor blink on keystroke (like Ghostty)
            resetCursorBlink();
            if (g_terminal) |term| {
                term.scrollViewport(.bottom) catch {};
            }
        }

        // Handle special keys
        const seq: ?[]const u8 = switch (key) {
            c.GLFW_KEY_ENTER => "\r",
            c.GLFW_KEY_BACKSPACE => "\x7f",
            c.GLFW_KEY_TAB => "\t",
            c.GLFW_KEY_ESCAPE => "\x1b",
            c.GLFW_KEY_UP => "\x1b[A",
            c.GLFW_KEY_DOWN => "\x1b[B",
            c.GLFW_KEY_RIGHT => "\x1b[C",
            c.GLFW_KEY_LEFT => "\x1b[D",
            c.GLFW_KEY_HOME => "\x1b[H",
            c.GLFW_KEY_END => "\x1b[F",
            c.GLFW_KEY_PAGE_UP => blk: {
                if (shift) {
                    // Shift+PageUp = scroll up
                    if (g_terminal) |term| {
                        term.scrollViewport(.{ .delta = -@as(isize, term_rows / 2) }) catch {};
                    }
                    break :blk null;
                }
                break :blk "\x1b[5~";
            },
            c.GLFW_KEY_PAGE_DOWN => blk: {
                if (shift) {
                    // Shift+PageDown = scroll down
                    if (g_terminal) |term| {
                        term.scrollViewport(.{ .delta = @as(isize, term_rows / 2) }) catch {};
                    }
                    break :blk null;
                }
                break :blk "\x1b[6~";
            },
            c.GLFW_KEY_INSERT => "\x1b[2~",
            c.GLFW_KEY_DELETE => "\x1b[3~",
            else => blk: {
                // Handle Ctrl+key combinations
                if (ctrl and key >= c.GLFW_KEY_A and key <= c.GLFW_KEY_Z) {
                    const ctrl_char: u8 = @intCast(key - c.GLFW_KEY_A + 1);
                    _ = pty.write(&[_]u8{ctrl_char}) catch {};
                }
                break :blk null;
            },
        };

        if (seq) |s| {
            _ = pty.write(s) catch {};
        }
    }
}

fn setProjection(width: f32, height: f32) void {
    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };

    gl.UseProgram.?(shader_program);
    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(shader_program, "projection"), 1, c.GL_FALSE, &projection);
}

pub fn main() !void {
    std.debug.print("Phantty starting...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var requested_font: []const u8 = "JetBrains Mono"; // default
    var requested_weight: directwrite.DWRITE_FONT_WEIGHT = .SEMI_BOLD; // default to SemiBold

    var i: usize = 1; // skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--list-fonts")) {
            try listSystemFonts(allocator);
            return;
        }
        if (std.mem.eql(u8, arg, "--test-font-discovery")) {
            try testFontDiscovery(allocator);
            return;
        }
        if (std.mem.eql(u8, arg, "--font") or std.mem.eql(u8, arg, "-f")) {
            i += 1;
            if (i < args.len) {
                requested_font = args[i];
            } else {
                std.debug.print("Error: --font requires a font name argument\n", .{});
                std.debug.print("Usage: phantty --font \"Cascadia Code\"\n", .{});
                return;
            }
        }
        if (std.mem.eql(u8, arg, "--font-style")) {
            i += 1;
            if (i < args.len) {
                const style = args[i];
                if (std.mem.eql(u8, style, "thin")) {
                    requested_weight = .THIN;
                } else if (std.mem.eql(u8, style, "extra-light") or std.mem.eql(u8, style, "extralight")) {
                    requested_weight = .EXTRA_LIGHT;
                } else if (std.mem.eql(u8, style, "light")) {
                    requested_weight = .LIGHT;
                } else if (std.mem.eql(u8, style, "regular") or std.mem.eql(u8, style, "normal")) {
                    requested_weight = .NORMAL;
                } else if (std.mem.eql(u8, style, "medium")) {
                    requested_weight = .MEDIUM;
                } else if (std.mem.eql(u8, style, "semi-bold") or std.mem.eql(u8, style, "semibold")) {
                    requested_weight = .SEMI_BOLD;
                } else if (std.mem.eql(u8, style, "bold")) {
                    requested_weight = .BOLD;
                } else if (std.mem.eql(u8, style, "extra-bold") or std.mem.eql(u8, style, "extrabold")) {
                    requested_weight = .EXTRA_BOLD;
                } else if (std.mem.eql(u8, style, "black") or std.mem.eql(u8, style, "heavy")) {
                    requested_weight = .BLACK;
                } else {
                    std.debug.print("Unknown font style: {s}\n", .{style});
                    std.debug.print("Valid styles: thin, extra-light, light, regular, medium, semi-bold, bold, extra-bold, black\n", .{});
                    return;
                }
            } else {
                std.debug.print("Error: --font-style requires a style argument\n", .{});
                return;
            }
        }
        if (std.mem.eql(u8, arg, "--cursor-style")) {
            i += 1;
            if (i < args.len) {
                const cursor_style = args[i];
                if (std.mem.eql(u8, cursor_style, "block")) {
                    g_cursor_style = .block;
                } else if (std.mem.eql(u8, cursor_style, "bar")) {
                    g_cursor_style = .bar;
                } else if (std.mem.eql(u8, cursor_style, "underline")) {
                    g_cursor_style = .underline;
                } else if (std.mem.eql(u8, cursor_style, "block_hollow")) {
                    g_cursor_style = .block_hollow;
                } else {
                    std.debug.print("Unknown cursor style: {s}\n", .{cursor_style});
                    std.debug.print("Valid styles: block, bar, underline, block_hollow\n", .{});
                    return;
                }
            } else {
                std.debug.print("Error: --cursor-style requires a style argument\n", .{});
                return;
            }
        }
        if (std.mem.eql(u8, arg, "--cursor-style-blink")) {
            i += 1;
            if (i < args.len) {
                const blink_val = args[i];
                if (std.mem.eql(u8, blink_val, "true")) {
                    g_cursor_blink = true;
                } else if (std.mem.eql(u8, blink_val, "false")) {
                    g_cursor_blink = false;
                } else {
                    std.debug.print("Invalid value for --cursor-style-blink: {s}\n", .{blink_val});
                    std.debug.print("Valid values: true, false\n", .{});
                    return;
                }
            } else {
                std.debug.print("Error: --cursor-style-blink requires a value (true/false)\n", .{});
                return;
            }
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Phantty - A terminal emulator
                \\
                \\Usage: phantty [options]
                \\
                \\Options:
                \\  --font, -f <name>       Use specified font (default: "JetBrains Mono")
                \\  --font-style <style>    Font weight/style (default: "semi-bold")
                \\                          Options: thin, extra-light, light, regular, medium,
                \\                                   semi-bold, bold, extra-bold, black
                \\  --cursor-style <style>  Cursor shape (default: "block")
                \\                          Options: block, bar, underline, block_hollow
                \\  --cursor-style-blink <bool>  Enable cursor blinking (default: true)
                \\  --list-fonts            List all available system fonts
                \\  --test-font-discovery   Test font discovery for common fonts
                \\  --help, -h              Show this help message
                \\
                \\Examples:
                \\  phantty --font "Cascadia Code"
                \\  phantty --font "JetBrains Mono" --font-style bold
                \\  phantty --cursor-style bar --cursor-style-blink false
                \\  phantty --list-fonts
                \\
            , .{});
            return;
        }
    }

    // Initialize ghostty-vt terminal
    // max_scrollback is in bytes - use 10MB like Ghostty's default scrollback-limit
    var terminal: ghostty_vt.Terminal = try .init(allocator, .{
        .cols = term_cols,
        .rows = term_rows,
        .max_scrollback = 10_000_000, // 10MB
    });
    defer terminal.deinit(allocator);
    std.debug.print("Terminal initialized: {}x{}\n", .{ term_cols, term_rows });

    // Set initial cursor style from user config (like Ghostty does in Termio.zig)
    terminal.screens.active.cursor.cursor_style = switch (g_cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };

    // Set initial cursor blink mode (Ghostty defaults to true in Termio.zig:219)
    terminal.modes.set(.cursor_blinking, g_cursor_blink);

    // Spawn PTY with wsl.exe
    const wsl_cmd = std.unicode.utf8ToUtf16LeStringLiteral("wsl.exe");
    var pty = Pty.spawn(term_cols, term_rows, wsl_cmd) catch |err| {
        std.debug.print("Failed to spawn PTY: {}\n", .{err});
        return err;
    };
    defer pty.deinit();
    std.debug.print("PTY spawned with wsl.exe\n", .{});

    // Set some global pointers for callbacks (window set later)
    g_pty = &pty;
    g_terminal = &terminal;
    g_allocator = allocator;

    // Initialize GLFW
    if (c.glfwInit() == 0) {
        std.debug.print("Failed to initialize GLFW\n", .{});
        return error.GLFWInitFailed;
    }
    defer c.glfwTerminate();

    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);

    const window = c.glfwCreateWindow(800, 600, "Phantty", null, null);
    if (window == null) {
        std.debug.print("Failed to create GLFW window\n", .{});
        return error.WindowCreationFailed;
    }
    defer c.glfwDestroyWindow(window);

    c.glfwMakeContextCurrent(window);

    // Set up input callbacks
    _ = c.glfwSetCharCallback(window, charCallback);
    _ = c.glfwSetKeyCallback(window, keyCallback);
    _ = c.glfwSetScrollCallback(window, scrollCallback);
    _ = c.glfwSetMouseButtonCallback(window, mouseButtonCallback);
    _ = c.glfwSetCursorPosCallback(window, cursorPosCallback);
    _ = c.glfwSetFramebufferSizeCallback(window, framebufferSizeCallback);
    _ = c.glfwSetWindowFocusCallback(window, windowFocusCallback);

    // Set window pointer for clipboard access
    g_window = window;

    const version = c.gladLoadGLContext(&gl, @ptrCast(&c.glfwGetProcAddress));
    if (version == 0) {
        std.debug.print("Failed to initialize GLAD\n", .{});
        return error.GLADInitFailed;
    }
    std.debug.print("OpenGL {}.{}\n", .{ c.GLAD_VERSION_MAJOR(version), c.GLAD_VERSION_MINOR(version) });

    // Initialize FreeType
    const ft_lib = freetype.Library.init() catch |err| {
        std.debug.print("Failed to initialize FreeType: {}\n", .{err});
        return err;
    };
    defer ft_lib.deinit();

    // Store globally for fallback font loading
    g_ft_lib = ft_lib;
    defer g_ft_lib = null;

    std.debug.print("Requested font: {s} (weight: {})\n", .{ requested_font, @intFromEnum(requested_weight) });
    std.debug.print("Cursor style: {s}, blink: {}\n", .{ @tagName(g_cursor_style), g_cursor_blink });

    // Initialize DirectWrite for font discovery (keep alive for fallback lookups)
    var dw_discovery: ?directwrite.FontDiscovery = directwrite.FontDiscovery.init() catch |err| blk: {
        std.debug.print("DirectWrite init failed: {}\n", .{err});
        break :blk null;
    };
    defer if (dw_discovery) |*dw| dw.deinit();

    // Store globally for fallback font lookups
    g_font_discovery = if (dw_discovery) |*dw| dw else null;
    defer g_font_discovery = null;

    // Clean up fallback faces on exit
    defer {
        var it = g_fallback_faces.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        g_fallback_faces.deinit(allocator);
    }

    // Try to find the requested font via DirectWrite
    var font_result: ?directwrite.FontDiscovery.FontResult = null;

    if (dw_discovery) |*dw| {
        if (dw.findFontFilePath(allocator, requested_font, requested_weight, .NORMAL) catch null) |result| {
            font_result = result;
            std.debug.print("Found system font: {s}\n", .{result.path});
        } else {
            std.debug.print("Font '{s}' not found, will use embedded fallback\n", .{requested_font});
        }
    }

    defer if (font_result) |*fr| fr.deinit();

    // Load the font with FreeType
    const face: freetype.Face = blk: {
        // Try system font first
        if (font_result) |fr| {
            if (ft_lib.initFace(fr.path, @intCast(fr.face_index))) |f| {
                break :blk f;
            } else |err| {
                std.debug.print("Failed to load system font: {}, using embedded fallback\n", .{err});
            }
        }
        
        // Fall back to embedded JetBrains Mono
        std.debug.print("Using embedded JetBrains Mono as fallback\n", .{});
        break :blk ft_lib.initMemoryFace(embedded.regular, 0) catch |err| {
            std.debug.print("Failed to load embedded font: {}\n", .{err});
            return err;
        };
    };
    defer face.deinit();

    face.setCharSize(0, FONT_SIZE * 64, 96, 96) catch |err| {
        std.debug.print("Failed to set font size: {}\n", .{err});
        return err;
    };

    // Store font size globally for fallback fonts
    g_font_size = FONT_SIZE;

    if (!initShaders()) {
        std.debug.print("Failed to initialize shaders\n", .{});
        return error.ShaderInitFailed;
    }
    initBuffers();
    preloadCharacters(face);
    defer {
        // Clean up glyph cache textures
        var it = glyph_cache.iterator();
        while (it.next()) |entry| {
            gl.DeleteTextures.?(1, &entry.value_ptr.texture_id);
        }
        glyph_cache.deinit(allocator);
    }
    initSolidTexture();

    // Calculate window size based on cell dimensions (small padding for aesthetics)
    const padding: f32 = 10;
    const content_width: f32 = cell_width * @as(f32, @floatFromInt(term_cols));
    const content_height: f32 = cell_height * @as(f32, @floatFromInt(term_rows));
    const window_width: c_int = @intFromFloat(content_width + padding * 2);
    const window_height: c_int = @intFromFloat(content_height + padding * 2);
    c.glfwSetWindowSize(window, window_width, window_height);

    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    std.debug.print("Ready! Cell size: {d:.1}x{d:.1}\n", .{ cell_width, cell_height });

    // Buffer for reading PTY output
    var pty_buffer: [4096]u8 = undefined;
    var stream = terminal.vtStream();

    // Main loop
    while (c.glfwWindowShouldClose(window) == 0) {
        // Process pending resize (coalesced, like Ghostty)
        // We wait for RESIZE_COALESCE_MS after last resize event before applying
        if (g_pending_resize) {
            const now = std.time.milliTimestamp();
            if (now - g_last_resize_time >= RESIZE_COALESCE_MS) {
                g_pending_resize = false;

                if (g_pending_cols != term_cols or g_pending_rows != term_rows) {
                    // Mark resize in progress to prevent rendering with inconsistent state
                    g_resize_in_progress = true;
                    defer g_resize_in_progress = false;

                    term_cols = g_pending_cols;
                    term_rows = g_pending_rows;

                    // Resize terminal
                    terminal.resize(allocator, term_cols, term_rows) catch |err| {
                        std.debug.print("Terminal resize error: {}\n", .{err});
                    };

                    // Resize PTY
                    // TODO: ConPTY sends a full screen redraw on resize which overwrites
                    // our scrollback content when growing. See GitHub issue #2.
                    pty.resize(term_cols, term_rows);

                    // Scroll to bottom after resize to ensure we see the active area
                    terminal.scrollViewport(.{ .bottom = {} }) catch {};
                }
            }
        }

        // Read from PTY (non-blocking check first)
        while (pty.dataAvailable() > 0) {
            const bytes_read = pty.read(&pty_buffer) catch break;
            if (bytes_read == 0) break;
            // Feed data to terminal
            stream.nextSlice(pty_buffer[0..bytes_read]) catch {};
        }

        // Get actual framebuffer size (handles DPI scaling too)
        var fb_width: c_int = 0;
        var fb_height: c_int = 0;
        c.glfwGetFramebufferSize(window, &fb_width, &fb_height);

        gl.Viewport.?(0, 0, fb_width, fb_height);
        setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));

        gl.ClearColor.?(0.05, 0.05, 0.08, 1.0);
        gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

        // Update cursor blink state
        updateCursorBlink();

        // Render with padding from edges
        renderTerminal(&terminal, @floatFromInt(fb_height), padding, padding);

        c.glfwSwapBuffers(window);
        c.glfwPollEvents();
    }

    std.debug.print("Phantty exiting...\n", .{});
}
