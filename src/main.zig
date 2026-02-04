const std = @import("std");
const build_options = @import("build_options");
const ghostty_vt = @import("ghostty-vt");
const freetype = @import("freetype");
const Pty = @import("pty.zig").Pty;
const sprite = @import("font/sprite.zig");
const directwrite = @import("directwrite.zig");
const Config = @import("config.zig");
const Surface = @import("Surface.zig");
const renderer = @import("renderer.zig");
const win32_backend = if (build_options.use_win32) @import("win32.zig") else struct {};

const c = @cImport({
    @cInclude("glad/gl.h");
    if (!build_options.use_win32) {
        @cInclude("GLFW/glfw3.h");
    }
});

// Type aliases from config module
const Color = Config.Color;
const Theme = Config.Theme;
const CursorStyle = Config.CursorStyle;
const hexToColor = Config.hexToColor;
const parseColor = Config.parseColor;

// Global theme (set at startup via config)
var g_theme: Theme = Theme.default();

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

// Global pointers for callbacks
var g_window: if (build_options.use_win32) ?*win32_backend.Window else ?*c.GLFWwindow = null;
var g_allocator: ?std.mem.Allocator = null;

// Selection is defined in Surface.zig
const Selection = Surface.Selection;

var g_should_close: bool = false; // Set by Ctrl+W with 1 tab
var g_selecting: bool = false; // True while mouse button is held
var g_click_x: f64 = 0; // X position of initial click (for threshold calculation)
var g_click_y: f64 = 0; // Y position of initial click

// ============================================================================
// Tab model — each tab owns a Surface (PTY + terminal + OSC state)
// ============================================================================

const TabState = struct {
    surface: *Surface,

    /// Get the display title for this tab (delegates to Surface)
    fn getTitle(self: *const TabState) []const u8 {
        return self.surface.getTitle();
    }

    fn deinit(self: *TabState, allocator: std.mem.Allocator) void {
        self.surface.deinit(allocator);
    }
};

const MAX_TABS = 16;
var g_tabs: [MAX_TABS]?*TabState = .{null} ** MAX_TABS;
var g_tab_count: usize = 0;
var g_active_tab: usize = 0;

// Global shell command for spawning new tabs (set once at startup from config)
var g_shell_cmd_buf: [256]u16 = undefined;
var g_shell_cmd_len: usize = 0;
var g_scrollback_limit: u32 = 10_000_000;

fn getShellCmd() [:0]const u16 {
    return g_shell_cmd_buf[0..g_shell_cmd_len :0];
}

/// Get the active tab's selection
fn activeSelection() *Selection {
    if (g_tab_count > 0) {
        if (g_tabs[g_active_tab]) |tab| {
            return &tab.surface.selection;
        }
    }
    // Fallback — should never happen in practice
    const S = struct {
        var dummy: Selection = .{};
    };
    return &S.dummy;
}

/// Get the active Surface, or null
fn activeSurface() ?*Surface {
    if (g_tab_count == 0) return null;
    const tab = g_tabs[g_active_tab] orelse return null;
    return tab.surface;
}

// OSC scanning and title management moved to Surface.zig

/// Spawn a new tab with its own Surface (PTY + terminal).
/// Called for both the initial tab and Ctrl+Shift+T.
fn spawnTab(allocator: std.mem.Allocator) bool {
    if (g_tab_count >= MAX_TABS) return false;

    // Create Surface (owns PTY + terminal + OSC state)
    const surface = Surface.init(
        allocator,
        term_cols,
        term_rows,
        getShellCmd(),
        g_scrollback_limit,
        g_cursor_style,
        g_cursor_blink,
    ) catch {
        std.debug.print("Failed to create Surface for new tab\n", .{});
        return false;
    };

    // Allocate TabState on the heap so pointers stay stable when tabs shift
    const tab = allocator.create(TabState) catch {
        std.debug.print("Failed to allocate TabState\n", .{});
        surface.deinit(allocator);
        return false;
    };
    tab.surface = surface;

    g_tabs[g_tab_count] = tab;
    g_active_tab = g_tab_count;
    g_tab_count += 1;

    // Clear selection state when switching to new tab
    g_selecting = false;
    g_force_rebuild = true;
    g_cells_valid = false;

    std.debug.print("New tab spawned (count={}), active: {}\n", .{ g_tab_count, g_active_tab });
    return true;
}

fn closeTab(idx: usize) void {
    if (g_tab_count <= 1) return; // last tab closed via g_should_close instead
    if (idx >= g_tab_count) return;

    const allocator = g_allocator orelse return;

    // Deinit and free the tab
    if (g_tabs[idx]) |tab| {
        tab.deinit(allocator);
        allocator.destroy(tab);
    }

    // Shift tabs down
    var i = idx;
    while (i + 1 < g_tab_count) : (i += 1) {
        g_tabs[i] = g_tabs[i + 1];
    }
    g_tabs[g_tab_count - 1] = null;
    g_tab_count -= 1;

    // Adjust active tab index
    if (g_active_tab == idx) {
        if (g_active_tab >= g_tab_count) {
            g_active_tab = g_tab_count - 1;
        }
    } else if (g_active_tab > idx) {
        g_active_tab -= 1;
    }

    // Clear selection state when tab changes
    g_selecting = false;
    g_force_rebuild = true;
    g_cells_valid = false;
}

fn switchTab(idx: usize) void {
    if (idx < g_tab_count) {
        g_active_tab = idx;
        // Clear selection state when switching tabs
        g_selecting = false;
        g_force_rebuild = true;
        g_cells_valid = false;
    }
}

fn isActiveTabTerminal() bool {
    if (g_tab_count == 0) return false;
    return g_tabs[g_active_tab] != null;
}

/// Get the active tab, or null
fn activeTab() ?*TabState {
    if (g_tab_count == 0) return null;
    return g_tabs[g_active_tab];
}

// Embed the font
// Embedded fallback font (JetBrains Mono, like Ghostty)
const embedded = @import("font/embedded.zig");

// Terminal dimensions (initial, will be updated on resize)
// Defaults match Ghostty's default of 0 (auto-size), but we set
// reasonable defaults since we don't auto-detect screen size.
var term_cols: u16 = 80;
var term_rows: u16 = 24;
const DEFAULT_FONT_SIZE: u32 = 14;

// OpenGL context from glad
var gl: c.GladGLContext = undefined;

const FontAtlas = @import("font/Atlas.zig");

const Character = struct {
    // Atlas region (UV coordinates derived from this + atlas size)
    region: FontAtlas.Region,
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
var icon_face: ?freetype.Face = null; // Segoe MDL2 Assets for caption button icons
var icon_cache: std.AutoHashMapUnmanaged(u32, Character) = .empty;

// Font atlas — single texture for all glyphs (replaces per-glyph textures)
var g_atlas: ?FontAtlas = null;
var g_atlas_texture: c.GLuint = 0;
var g_atlas_modified: usize = 0; // Last synced modified counter

// Icon atlas — separate atlas for caption button icons (Segoe MDL2)
var g_icon_atlas: ?FontAtlas = null;
var g_icon_atlas_texture: c.GLuint = 0;
var g_icon_atlas_modified: usize = 0;

// Titlebar font — separate face/cache/atlas at fixed 14pt for crisp titlebar text.
// Avoids scaling artifacts from rendering terminal-size glyphs at a smaller size.
var g_titlebar_face: ?freetype.Face = null;
var g_titlebar_cache: std.AutoHashMapUnmanaged(u32, Character) = .empty;
var g_titlebar_atlas: ?FontAtlas = null;
var g_titlebar_atlas_texture: c.GLuint = 0;
var g_titlebar_atlas_modified: usize = 0;
var g_titlebar_cell_width: f32 = 8;
var g_titlebar_cell_height: f32 = 14;
var g_titlebar_baseline: f32 = 3;
var vao: c.GLuint = 0;
var vbo: c.GLuint = 0;
var shader_program: c.GLuint = 0;

// ============================================================================
// Instanced rendering — BG + FG cell buffers
// ============================================================================

/// Per-instance data for background cells (one per grid cell with non-default bg).
const CellBg = extern struct {
    grid_col: f32,
    grid_row: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// Per-instance data for foreground cells (one per visible glyph).
const CellFg = extern struct {
    grid_col: f32,
    grid_row: f32,
    glyph_x: f32, // offset from cell left to glyph left
    glyph_y: f32, // offset from cell bottom to glyph bottom
    glyph_w: f32, // glyph width in pixels
    glyph_h: f32, // glyph height in pixels
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
    r: f32,
    g: f32,
    b: f32,
};

// Max cells = 300 cols x 100 rows = 30000 (generous)
const MAX_CELLS = 30000;
var bg_cells: [MAX_CELLS]CellBg = undefined;
var fg_cells: [MAX_CELLS]CellFg = undefined;
var bg_cell_count: usize = 0;
var fg_cell_count: usize = 0;

// Snapshot buffer: resolved cell data copied under the lock so that
// rebuildCells can run outside the lock (like Ghostty's RenderState).
const SnapCell = struct {
    codepoint: u21,
    fg: [3]f32,
    bg: ?[3]f32,
};
const MAX_SNAP = MAX_CELLS;
var g_snap: [MAX_SNAP]SnapCell = undefined;
var g_snap_rows: usize = 0;
var g_snap_cols: usize = 0;

// Dirty tracking — skip rebuildCells when nothing changed
var g_cells_valid: bool = false; // true if bg_cells/fg_cells have valid data from a previous rebuild
var g_force_rebuild: bool = true; // set on resize, scroll, selection, theme change
var g_last_cursor_blink_visible: bool = true; // track cursor blink transitions
// Cached cursor state for lock-free rendering (used when tryLock fails)
var g_cached_cursor_x: usize = 0;
var g_cached_cursor_y: usize = 0;
var g_cached_cursor_style: CursorStyle = .block;
var g_cached_cursor_effective: ?CursorStyle = .block;
var g_cached_viewport_at_bottom: bool = true;

var g_last_viewport_active: bool = true; // track viewport position changes (scroll)
// Viewport pin tracking — detects scroll position changes (like Ghostty's RenderState.viewport_pin)
var g_last_viewport_node: ?*anyopaque = null;
var g_last_viewport_y: usize = 0;
var g_last_cols: usize = 0; // detect resize
var g_last_rows: usize = 0; // detect resize
var g_last_selection_active: bool = false; // detect selection changes

// GL objects for instanced rendering
var bg_shader: c.GLuint = 0;
var fg_shader: c.GLuint = 0;
var bg_vao: c.GLuint = 0;
var fg_vao: c.GLuint = 0;
var bg_instance_vbo: c.GLuint = 0;
var fg_instance_vbo: c.GLuint = 0;
var quad_vbo: c.GLuint = 0; // shared unit quad for instanced draws

// --- Instanced shader sources ---

const bg_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\// Unit quad (0,0)-(1,1)
    \\layout (location = 0) in vec2 aQuad;
    \\// Per-instance
    \\layout (location = 1) in vec2 aGridPos;
    \\layout (location = 2) in vec3 aColor;
    \\uniform mat4 projection;
    \\uniform vec2 cellSize;
    \\uniform vec2 gridOffset;
    \\uniform float windowHeight;
    \\flat out vec3 vColor;
    \\void main() {
    \\    // Cell top-left in screen coords
    \\    float cx = gridOffset.x + aGridPos.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (aGridPos.y + 1.0) * cellSize.y;
    \\    vec2 pos = vec2(cx, cy) + aQuad * cellSize;
    \\    gl_Position = projection * vec4(pos, 0.0, 1.0);
    \\    vColor = aColor;
    \\}
;

const bg_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\flat in vec3 vColor;
    \\out vec4 fragColor;
    \\void main() {
    \\    fragColor = vec4(vColor, 1.0);
    \\}
;

const fg_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec2 aQuad;
    \\// Per-instance
    \\layout (location = 1) in vec2 aGridPos;
    \\layout (location = 2) in vec4 aGlyphRect;  // x, y, w, h in pixels
    \\layout (location = 3) in vec4 aUV;          // left, top, right, bottom
    \\layout (location = 4) in vec3 aColor;
    \\uniform mat4 projection;
    \\uniform vec2 cellSize;
    \\uniform vec2 gridOffset;
    \\uniform float windowHeight;
    \\out vec2 vTexCoord;
    \\flat out vec3 vColor;
    \\void main() {
    \\    float cx = gridOffset.x + aGridPos.x * cellSize.x;
    \\    float cy = windowHeight - gridOffset.y - (aGridPos.y + 1.0) * cellSize.y;
    \\    // Glyph quad within cell
    \\    vec2 pos = vec2(cx + aGlyphRect.x, cy + aGlyphRect.y) + aQuad * aGlyphRect.zw;
    \\    gl_Position = projection * vec4(pos, 0.0, 1.0);
    \\    // UV interpolation — V is flipped because atlas Y=0 is top but GL quad Y=0 is bottom
    \\    vTexCoord = vec2(mix(aUV.x, aUV.z, aQuad.x), mix(aUV.w, aUV.y, aQuad.y));
    \\    vColor = aColor;
    \\}
;

const fg_fragment_source: [*c]const u8 =
    \\#version 330 core
    \\in vec2 vTexCoord;
    \\flat in vec3 vColor;
    \\uniform sampler2D atlas;
    \\out vec4 fragColor;
    \\void main() {
    \\    float a = texture(atlas, vTexCoord).r;
    \\    fragColor = vec4(vColor, 1.0) * vec4(1.0, 1.0, 1.0, a);
    \\}
;
var cell_width: f32 = 10;
var cell_height: f32 = 20;
var cell_baseline: f32 = 4; // Distance from bottom of cell to baseline
var cursor_height: f32 = 16; // Height of cursor (ascender portion)
var box_thickness: u32 = 1; // Thickness for box drawing characters
var window_focused: bool = true; // Track window focus state

// Fullscreen state (Alt+Enter to toggle)
var g_is_fullscreen: bool = false;
var g_windowed_x: c_int = 0; // Saved windowed position/size for restore
var g_windowed_y: c_int = 0;
var g_windowed_width: c_int = 800;
var g_windowed_height: c_int = 600;

// Post-processing custom shader (Ghostty-compatible)
var g_post_fbo: c.GLuint = 0; // Framebuffer object for off-screen render
var g_post_texture: c.GLuint = 0; // Color attachment texture
var g_post_program: c.GLuint = 0; // Post-processing shader program
var g_post_vao: c.GLuint = 0; // Fullscreen quad VAO
var g_post_vbo: c.GLuint = 0; // Fullscreen quad VBO
var g_post_enabled: bool = false; // Whether custom shader is active
var g_post_fb_width: c_int = 0; // Current FBO texture dimensions
var g_post_fb_height: c_int = 0;
var g_frame_count: u32 = 0; // Frame counter for iFrame
var g_start_time: i64 = 0; // Start time for iTime

// Pending resize state (resize is deferred to main loop to avoid PageList integrity issues)
// Ghostty coalesces resize events with a 25ms timer to batch rapid resizes
var g_pending_resize: bool = false;
var g_pending_cols: u16 = 0;
var g_pending_rows: u16 = 0;
var g_last_resize_time: i64 = 0;
var g_resize_in_progress: bool = false; // Prevent rendering during resize
const RESIZE_COALESCE_MS: i64 = 25; // Same as Ghostty

var g_cursor_style: CursorStyle = .block; // Default cursor style
var g_cursor_blink: bool = true; // Whether cursor should blink (default: true like Ghostty)
var g_cursor_blink_visible: bool = true; // Current blink state (toggled by timer)
var g_last_blink_time: i64 = 0; // Timestamp of last blink toggle
const CURSOR_BLINK_INTERVAL_MS: i64 = 600; // Blink interval in ms (same as Ghostty)

const ConfigWatcher = @import("config_watcher.zig");

// FPS debug overlay state
var g_debug_fps: bool = false; // Whether to show FPS overlay
var g_debug_draw_calls: bool = false; // Whether to show draw call count overlay
var g_draw_call_count: u32 = 0; // Reset each frame, incremented on each glDraw* call
var g_fps_frame_count: u32 = 0; // Frames since last FPS update
var g_fps_last_time: i64 = 0; // Timestamp of last FPS calculation
var g_fps_value: f32 = 0; // Current FPS value to display

// Font fallback system
var g_ft_lib: ?freetype.Library = null;
var g_font_discovery: ?*directwrite.FontDiscovery = null;
var g_fallback_faces: std.AutoHashMapUnmanaged(u32, freetype.Face) = .empty; // codepoint -> fallback face
var g_font_size: u32 = DEFAULT_FONT_SIZE;

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
    if (shader == 0) {
        const gl_err = if (gl.GetError) |getErr| getErr() else 0;
        std.debug.print("Shader error: glCreateShader returned 0, type=0x{X}, glError=0x{X}\n", .{ shader_type, gl_err });
        return null;
    }

    gl.ShaderSource.?(shader, 1, &source, null);
    gl.CompileShader.?(shader);

    var success: c.GLint = 0;
    gl.GetShaderiv.?(shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetShaderInfoLog.?(shader, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) {
            std.debug.print("Shader compilation failed: {s}\n", .{info_log[0..len]});
        } else {
            std.debug.print("Shader compilation failed (no error log, shader={})\n", .{shader});
        }
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
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetProgramInfoLog.?(shader_program, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) {
            std.debug.print("Shader linking failed: {s}\n", .{info_log[0..len]});
        } else {
            std.debug.print("Shader linking failed (no error log available)\n", .{});
        }
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

fn linkProgram(vs_src: [*c]const u8, fs_src: [*c]const u8) c.GLuint {
    const vs = compileShader(c.GL_VERTEX_SHADER, vs_src) orelse return 0;
    defer gl.DeleteShader.?(vs);
    const fs = compileShader(c.GL_FRAGMENT_SHADER, fs_src) orelse return 0;
    defer gl.DeleteShader.?(fs);
    const prog = gl.CreateProgram.?();
    gl.AttachShader.?(prog, vs);
    gl.AttachShader.?(prog, fs);
    gl.LinkProgram.?(prog);
    var success: c.GLint = 0;
    gl.GetProgramiv.?(prog, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = @splat(0);
        var log_len: c.GLsizei = 0;
        gl.GetProgramInfoLog.?(prog, 512, &log_len, &info_log);
        const len: usize = if (log_len > 0) @intCast(log_len) else 0;
        if (len > 0) std.debug.print("Shader link failed: {s}\n", .{info_log[0..len]});
        return 0;
    }
    return prog;
}

fn initInstancedBuffers() void {
    // Shared unit quad (triangle strip: 4 verts)
    const quad_verts = [4][2]f32{
        .{ 0.0, 0.0 }, // bottom-left
        .{ 1.0, 0.0 }, // bottom-right
        .{ 0.0, 1.0 }, // top-left
        .{ 1.0, 1.0 }, // top-right
    };
    gl.GenBuffers.?(1, &quad_vbo);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, quad_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad_verts)), &quad_verts, c.GL_STATIC_DRAW);

    // --- BG VAO ---
    gl.GenVertexArrays.?(1, &bg_vao);
    gl.GenBuffers.?(1, &bg_instance_vbo);
    gl.BindVertexArray.?(bg_vao);

    // Attr 0: unit quad (per-vertex)
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, quad_vbo);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);

    // Attrs 1-2: per-instance BG data
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, bg_instance_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(CellBg) * MAX_CELLS, null, c.GL_STREAM_DRAW);
    const bg_stride: c.GLsizei = @sizeOf(CellBg);
    // Attr 1: grid_col, grid_row
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    // Attr 2: r, g, b
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 3, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);

    gl.BindVertexArray.?(0);

    // --- FG VAO ---
    gl.GenVertexArrays.?(1, &fg_vao);
    gl.GenBuffers.?(1, &fg_instance_vbo);
    gl.BindVertexArray.?(fg_vao);

    // Attr 0: unit quad (per-vertex)
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, quad_vbo);
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);

    // Attrs 1-4: per-instance FG data
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, fg_instance_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(CellFg) * MAX_CELLS, null, c.GL_STREAM_DRAW);
    const fg_stride: c.GLsizei = @sizeOf(CellFg);
    // Attr 1: grid_col, grid_row
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    // Attr 2: glyph_x, glyph_y, glyph_w, glyph_h
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);
    // Attr 3: uv_left, uv_top, uv_right, uv_bottom
    gl.EnableVertexAttribArray.?(3);
    gl.VertexAttribPointer.?(3, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(6 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(3, 1);
    // Attr 4: r, g, b
    gl.EnableVertexAttribArray.?(4);
    gl.VertexAttribPointer.?(4, 3, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(10 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(4, 1);

    gl.BindVertexArray.?(0);

    // --- Compile instanced shaders ---
    bg_shader = linkProgram(bg_vertex_source, bg_fragment_source);
    fg_shader = linkProgram(fg_vertex_source, fg_fragment_source);
    if (bg_shader == 0) std.debug.print("BG instanced shader failed\n", .{});
    if (fg_shader == 0) std.debug.print("FG instanced shader failed\n", .{});
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

    // Pack glyph bitmap into the font atlas
    const region = packBitmapIntoAtlas(
        &g_atlas,
        alloc,
        bitmap.width,
        bitmap.rows,
        bitmap.buffer,
        @intCast(bitmap.pitch),
    ) orelse return null;

    const char_data = Character{
        .region = region,
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

/// Pack a bitmap into an atlas (growing if necessary), returning the region.
/// `src_buffer` may be null for zero-size bitmaps (returns a zero-size region).
/// `src_pitch` is the stride of the source bitmap in bytes (may differ from width).
fn packBitmapIntoAtlas(
    atlas_ptr: *?FontAtlas,
    alloc: std.mem.Allocator,
    width: u32,
    height: u32,
    src_buffer: ?[*]const u8,
    src_pitch: u32,
) ?FontAtlas.Region {
    // Zero-size glyph (e.g., space) — return a trivial region
    if (width == 0 or height == 0) {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    // Ensure atlas exists
    if (atlas_ptr.* == null) {
        atlas_ptr.* = FontAtlas.init(alloc, 512, .grayscale) catch return null;
    }
    var atlas = &atlas_ptr.*.?;

    // Copy source bitmap to tightly-packed buffer (FreeType pitch may != width)
    const tight = alloc.alloc(u8, width * height) catch return null;
    defer alloc.free(tight);
    const src = src_buffer orelse return null;
    for (0..height) |row| {
        const src_offset = row * src_pitch;
        const dst_offset = row * width;
        @memcpy(tight[dst_offset..][0..width], src[src_offset..][0..width]);
    }

    // Try to reserve space; grow atlas if full (up to reasonable max)
    var region = atlas.reserve(alloc, width, height) catch |err| switch (err) {
        error.AtlasFull => blk: {
            const new_size = atlas.size * 2;
            if (new_size > 8192) return null; // Safety cap
            std.debug.print("Atlas full ({0}x{0}), growing to {1}x{1}\n", .{ atlas.size, new_size });
            atlas.grow(alloc, new_size) catch return null;
            break :blk atlas.reserve(alloc, width, height) catch return null;
        },
        else => return null,
    };

    // Copy pixels into atlas
    atlas.set(region, tight);

    // Ensure region dimensions match what we asked for
    region.width = width;
    region.height = height;

    return region;
}

/// Pack a tightly-packed pixel buffer into an atlas (no pitch conversion needed).
fn packPixelsIntoAtlas(
    atlas_ptr: *?FontAtlas,
    alloc: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []const u8,
) ?FontAtlas.Region {
    if (width == 0 or height == 0) {
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    if (atlas_ptr.* == null) {
        atlas_ptr.* = FontAtlas.init(alloc, 512, .grayscale) catch return null;
    }
    var atlas = &atlas_ptr.*.?;

    var region = atlas.reserve(alloc, width, height) catch |err| switch (err) {
        error.AtlasFull => blk: {
            const new_size = atlas.size * 2;
            if (new_size > 8192) return null;
            std.debug.print("Atlas full ({0}x{0}), growing to {1}x{1}\n", .{ atlas.size, new_size });
            atlas.grow(alloc, new_size) catch return null;
            break :blk atlas.reserve(alloc, width, height) catch return null;
        },
        else => return null,
    };

    atlas.set(region, pixels);
    region.width = width;
    region.height = height;

    return region;
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

    // Pack into font atlas
    const region = packPixelsIntoAtlas(&g_atlas, alloc, @intCast(r.width), @intCast(r.height), trimmed_data) orelse return null;

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
        .region = region,
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
    // Use theme palette for colors 0-15
    if (color_idx < 16) {
        return g_theme.palette[color_idx];
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

/// Sync the font atlas CPU data to the GPU texture.
/// Called once per frame before rendering. Only uploads if the atlas was modified.
fn syncAtlasTexture(atlas_ptr: *?FontAtlas, texture_ptr: *c.GLuint, modified_ptr: *usize) void {
    const atlas = atlas_ptr.*.?;
    const modified = atlas.modified.load(.monotonic);
    if (modified <= modified_ptr.*) return;

    const size: c_int = @intCast(atlas.size);

    if (texture_ptr.* == 0) {
        // First time — create the texture
        gl.GenTextures.?(1, texture_ptr);
        gl.BindTexture.?(c.GL_TEXTURE_2D, texture_ptr.*);
        gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RED, size, size, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, atlas.data.ptr);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    } else {
        gl.BindTexture.?(c.GL_TEXTURE_2D, texture_ptr.*);
        // Check if atlas grew beyond current GPU texture size
        var current_size: c.GLint = 0;
        gl.GetTexLevelParameteriv.?(c.GL_TEXTURE_2D, 0, c.GL_TEXTURE_WIDTH, &current_size);
        if (current_size < size) {
            // Atlas grew — need a new texture
            gl.DeleteTextures.?(1, texture_ptr);
            gl.GenTextures.?(1, texture_ptr);
            gl.BindTexture.?(c.GL_TEXTURE_2D, texture_ptr.*);
            gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RED, size, size, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, atlas.data.ptr);
            gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        } else {
            // Same size — sub-image upload
            gl.TexSubImage2D.?(c.GL_TEXTURE_2D, 0, 0, 0, size, size, c.GL_RED, c.GL_UNSIGNED_BYTE, atlas.data.ptr);
        }
    }

    modified_ptr.* = modified;
}

/// Load a glyph for the titlebar (14pt, separate cache/atlas).
fn loadTitlebarGlyph(codepoint: u32) ?Character {
    if (g_titlebar_cache.get(codepoint)) |ch| return ch;

    const alloc = g_allocator orelse return null;
    const face = g_titlebar_face orelse return null;

    var glyph_index = face.getCharIndex(codepoint) orelse 0;
    var face_to_use = face;

    // Try fallback for missing glyphs
    if (glyph_index == 0) {
        if (findOrLoadFallbackFace(codepoint, alloc)) |fallback| {
            const fi = fallback.getCharIndex(codepoint) orelse 0;
            if (fi != 0) {
                glyph_index = fi;
                face_to_use = fallback;
            }
        }
    }

    face_to_use.loadGlyph(@intCast(glyph_index), .{ .target = .light }) catch return null;
    face_to_use.renderGlyph(.light) catch return null;

    const glyph = face_to_use.handle.*.glyph;
    const bitmap = glyph.*.bitmap;

    const region = packBitmapIntoAtlas(
        &g_titlebar_atlas,
        alloc,
        bitmap.width,
        bitmap.rows,
        bitmap.buffer,
        @intCast(bitmap.pitch),
    ) orelse return null;

    const ch = Character{
        .region = region,
        .size_x = @intCast(bitmap.width),
        .size_y = @intCast(bitmap.rows),
        .bearing_x = glyph.*.bitmap_left,
        .bearing_y = glyph.*.bitmap_top,
        .advance = glyph.*.advance.x,
        .valid = true,
    };

    g_titlebar_cache.put(alloc, codepoint, ch) catch return null;
    return ch;
}

/// Render a titlebar glyph at 1:1 atlas size (no scaling).
fn renderTitlebarChar(codepoint: u32, x: f32, y: f32, color: [3]f32) void {
    if (codepoint < 32) return;
    const ch: Character = loadTitlebarGlyph(codepoint) orelse return;
    if (ch.region.width == 0 or ch.region.height == 0) return;

    const x0 = x + @as(f32, @floatFromInt(ch.bearing_x));
    const y0 = y + g_titlebar_baseline - @as(f32, @floatFromInt(ch.size_y - ch.bearing_y));
    const w = @as(f32, @floatFromInt(ch.size_x));
    const h = @as(f32, @floatFromInt(ch.size_y));

    const atlas_size = if (g_titlebar_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const uv = glyphUV(ch.region, atlas_size);

    const vertices = [6][4]f32{
        .{ x0, y0 + h, uv.u0, uv.v0 },
        .{ x0, y0, uv.u0, uv.v1 },
        .{ x0 + w, y0, uv.u1, uv.v1 },
        .{ x0, y0 + h, uv.u0, uv.v0 },
        .{ x0 + w, y0, uv.u1, uv.v1 },
        .{ x0 + w, y0 + h, uv.u1, uv.v0 },
    };

    gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), color[0], color[1], color[2]);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_titlebar_atlas_texture);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); g_draw_call_count += 1;
}

/// Get the advance width of a titlebar glyph.
fn titlebarGlyphAdvance(codepoint: u32) f32 {
    if (loadTitlebarGlyph(codepoint)) |g| {
        return @as(f32, @floatFromInt(g.advance >> 6));
    }
    return g_titlebar_cell_width;
}

/// Render an icon glyph centered within a button rect, using the icon atlas.
fn renderIconGlyph(ch: Character, btn_x: f32, btn_y: f32, btn_w: f32, btn_h: f32, color: [3]f32, scale: f32) void {
    if (ch.region.width == 0 or ch.region.height == 0) return;

    const gw = @as(f32, @floatFromInt(ch.size_x)) * scale;
    const gh = @as(f32, @floatFromInt(ch.size_y)) * scale;
    const gx = btn_x + (btn_w - gw) / 2;
    const gy = btn_y + (btn_h - gh) / 2;

    const icon_atlas_size = if (g_icon_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const uv = glyphUV(ch.region, icon_atlas_size);

    const vertices = [6][4]f32{
        .{ gx, gy + gh, uv.u0, uv.v0 },
        .{ gx, gy, uv.u0, uv.v1 },
        .{ gx + gw, gy, uv.u1, uv.v1 },
        .{ gx, gy + gh, uv.u0, uv.v0 },
        .{ gx + gw, gy, uv.u1, uv.v1 },
        .{ gx + gw, gy + gh, uv.u1, uv.v0 },
    };

    gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), color[0], color[1], color[2]);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_icon_atlas_texture);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); g_draw_call_count += 1;
}

/// Compute UV coordinates from an atlas region and atlas size.
const GlyphUV = struct { u0: f32, v0: f32, u1: f32, v1: f32 };
fn glyphUV(region: FontAtlas.Region, atlas_size: f32) GlyphUV {
    return .{
        .u0 = @as(f32, @floatFromInt(region.x)) / atlas_size,
        .v0 = @as(f32, @floatFromInt(region.y)) / atlas_size,
        .u1 = @as(f32, @floatFromInt(region.x + region.width)) / atlas_size,
        .v1 = @as(f32, @floatFromInt(region.y + region.height)) / atlas_size,
    };
}

fn renderChar(codepoint: u32, x: f32, y: f32, color: [3]f32) void {
    // Skip control characters
    if (codepoint < 32) return;

    // Get character from cache (load on-demand if needed)
    const ch: Character = loadGlyph(codepoint) orelse return;
    if (ch.region.width == 0 or ch.region.height == 0) return;

    // Position glyph relative to baseline (like Ghostty)
    const x0 = x + @as(f32, @floatFromInt(ch.bearing_x));
    const y0 = y + cell_baseline - @as(f32, @floatFromInt(ch.size_y - ch.bearing_y));
    const w = @as(f32, @floatFromInt(ch.size_x));
    const h = @as(f32, @floatFromInt(ch.size_y));

    // Compute atlas UVs from region
    const atlas_size = if (g_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;
    const uv = glyphUV(ch.region, atlas_size);

    const vertices = [6][4]f32{
        .{ x0, y0 + h, uv.u0, uv.v0 },
        .{ x0, y0, uv.u0, uv.v1 },
        .{ x0 + w, y0, uv.u1, uv.v1 },
        .{ x0, y0 + h, uv.u0, uv.v0 },
        .{ x0 + w, y0, uv.u1, uv.v1 },
        .{ x0 + w, y0 + h, uv.u1, uv.v0 },
    };

    gl.Uniform3f.?(gl.GetUniformLocation.?(shader_program, "textColor"), color[0], color[1], color[2]);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_atlas_texture);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, vbo);
    gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @sizeOf(@TypeOf(vertices)), &vertices);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, 0);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); g_draw_call_count += 1;
}


/// Render the Ghostty-style tab bar.
/// Single row: [tabs...][+][  ][min][max][close]
///
/// Design (from Ghostty macOS screenshot):
/// - Tabs fill available width equally (left of + and caption buttons)
/// - Active tab: same color as terminal background (merges with content)
/// - Inactive tabs: slightly lighter shade
/// - Thin vertical separators between tabs
/// - No rounded corners, no accent lines — purely shade-based
/// - + button right of last tab
/// - Caption buttons on far right
///
/// OpenGL Y=0 is BOTTOM, so titlebar top = window_height - titlebar_h.
fn renderTitlebar(window_width: f32, window_height: f32, titlebar_h: f32) void {
    if (titlebar_h <= 0) return;

    gl.UseProgram.?(shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(vao);

    const tb_top = window_height - titlebar_h; // top of titlebar in GL coords
    const bg = g_theme.background;

    // Colors — Ghostty style:
    // - Active tab: same as terminal bg, no border (merges with content)
    // - Inactive tabs & + button: slightly lighter bg with 1px darker inset border
    const inactive_tab_bg = [3]f32{
        @min(1.0, bg[0] + 0.05),
        @min(1.0, bg[1] + 0.05),
        @min(1.0, bg[2] + 0.05),
    };
    const border_color = [3]f32{
        @max(0.0, bg[0] - 0.02),
        @max(0.0, bg[1] - 0.02),
        @max(0.0, bg[2] - 0.02),
    };
    const text_active = [3]f32{ 0.9, 0.9, 0.9 };
    const text_inactive = [3]f32{ 0.55, 0.55, 0.55 };

    // Layout constants
    const caption_btn_w: f32 = 46;
    const caption_area_w: f32 = caption_btn_w * 3; // min + max + close
    const plus_btn_w: f32 = 46; // + button width (same as caption buttons)
    const gap_w: f32 = 42; // breathing room between + and caption buttons
    const show_plus = g_tab_count > 1;
    const num_tabs = g_tab_count;

    // Calculate space: tabs fill remaining width after + button, gap, and caption buttons
    const plus_total: f32 = if (show_plus) plus_btn_w else 0;
    const right_reserved: f32 = caption_area_w + gap_w + plus_total;
    const tab_area_w: f32 = window_width - right_reserved;
    const tab_w: f32 = if (num_tabs > 0) tab_area_w / @as(f32, @floatFromInt(num_tabs)) else tab_area_w;

    // --- Tab bar background (same as terminal bg) ---
    renderQuad(0, tb_top, window_width, titlebar_h, bg);

    // --- Tabs ---
    var cursor_x: f32 = 0;
    const bdr: f32 = 1; // border thickness

    for (0..num_tabs) |tab_idx| {
        const is_active = (tab_idx == g_active_tab);

        // Inactive tabs: slightly lighter bg with 1px darker inset border
        // Active tab: no border, same as terminal bg (merges with content)
        if (!is_active) {
            // Check hover
            const tab_hovered = blk: {
                if (!build_options.use_win32) break :blk false;
                const win = g_window orelse break :blk false;
                if (win.mouse_y < 0 or win.mouse_y >= @as(i32, @intFromFloat(titlebar_h))) break :blk false;
                const fx: f32 = @floatFromInt(win.mouse_x);
                break :blk fx >= cursor_x and fx < cursor_x + tab_w;
            };

            // Fill — slightly lighter on hover
            const tab_bg = if (tab_hovered) [3]f32{
                @min(1.0, inactive_tab_bg[0] + 0.04),
                @min(1.0, inactive_tab_bg[1] + 0.04),
                @min(1.0, inactive_tab_bg[2] + 0.04),
            } else inactive_tab_bg;
            renderQuad(cursor_x, tb_top, tab_w, titlebar_h, tab_bg);

            // 1px inset border — left border only (skip on first tab), bottom
            renderQuad(cursor_x, tb_top, tab_w, bdr, border_color); // bottom
            if (tab_idx > 0) {
                renderQuad(cursor_x, tb_top, bdr, titlebar_h, border_color); // left
            }
        }

        // Tab title text — rendered at native 14pt via titlebar font (no scaling)
        // Shortcut label (^1 through ^0) rendered right-aligned, only for tabs 1–10 in multi-tab
        const title = if (g_tabs[tab_idx]) |t| t.getTitle() else "New Tab";
        if (title.len > 0) {
            const text_color = if (is_active) text_active else text_inactive;
            const shortcut_color = [3]f32{ 0.45, 0.45, 0.45 };
            const tab_pad: f32 = 18;

            // Shortcut label: "^1" through "^9", "^0" for tab 10
            const has_shortcut = num_tabs > 1 and tab_idx < 10;
            const shortcut_digit: u8 = if (has_shortcut)
                (if (tab_idx == 9) '0' else @as(u8, @intCast('1' + tab_idx)))
            else
                0;

            // Measure shortcut width
            var shortcut_w: f32 = 0;
            if (has_shortcut) {
                shortcut_w += titlebarGlyphAdvance('^');
                shortcut_w += titlebarGlyphAdvance(@intCast(shortcut_digit));
            }

            const shortcut_gap: f32 = if (has_shortcut) 6 else 0;
            const shortcut_reserved = if (has_shortcut) shortcut_w + shortcut_gap else 0;

            const center_region = if (num_tabs == 1) window_width else tab_w;
            const center_offset = if (num_tabs == 1) @as(f32, 0) else cursor_x;
            const avail_w = center_region - tab_pad * 2 - shortcut_reserved;

            // Decode title into codepoints for proper UTF-8 handling
            var codepoints: [256]u32 = undefined;
            var cp_count: usize = 0;
            var text_width: f32 = 0;
            {
                const view = std.unicode.Utf8View.initUnchecked(title);
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| {
                    if (cp_count >= 256) break;
                    codepoints[cp_count] = cp;
                    text_width += titlebarGlyphAdvance(cp);
                    cp_count += 1;
                }
            }

            const text_y = tb_top + (titlebar_h - g_titlebar_cell_height) / 2;

            if (text_width <= avail_w) {
                // Fits — center it
                const text_area = center_region - shortcut_reserved;
                var text_x = center_offset + (text_area - text_width) / 2;
                for (codepoints[0..cp_count]) |cp| {
                    renderTitlebarChar(cp, text_x, text_y, text_color);
                    text_x += titlebarGlyphAdvance(cp);
                }
            } else {
                // Middle truncation
                const ellipsis_char: u32 = 0x2026;
                const ellipsis_w = titlebarGlyphAdvance(ellipsis_char);
                const text_budget = avail_w - ellipsis_w;
                const half_budget = text_budget / 2;

                // Measure codepoints from start
                var start_w: f32 = 0;
                var start_end: usize = 0;
                for (codepoints[0..cp_count], 0..) |cp, idx| {
                    const char_w = titlebarGlyphAdvance(cp);
                    if (start_w + char_w > half_budget) break;
                    start_w += char_w;
                    start_end = idx + 1;
                }

                // Measure codepoints from end
                var end_w: f32 = 0;
                var end_start: usize = cp_count;
                var j: usize = cp_count;
                while (j > start_end) {
                    j -= 1;
                    const char_w = titlebarGlyphAdvance(codepoints[j]);
                    if (end_w + char_w > half_budget) break;
                    end_w += char_w;
                    end_start = j;
                }

                var text_x = center_offset + tab_pad;
                for (codepoints[0..start_end]) |cp| {
                    renderTitlebarChar(cp, text_x, text_y, text_color);
                    text_x += titlebarGlyphAdvance(cp);
                }
                renderTitlebarChar(ellipsis_char, text_x, text_y, text_color);
                text_x += ellipsis_w;
                for (codepoints[end_start..cp_count]) |cp| {
                    renderTitlebarChar(cp, text_x, text_y, text_color);
                    text_x += titlebarGlyphAdvance(cp);
                }
            }

            // Render shortcut label right-aligned
            if (has_shortcut) {
                const sc_color = if (is_active) text_active else shortcut_color;
                var sc_x = center_offset + center_region - tab_pad - shortcut_w;
                renderTitlebarChar('^', sc_x, text_y, sc_color);
                sc_x += titlebarGlyphAdvance('^');
                renderTitlebarChar(@intCast(shortcut_digit), sc_x, text_y, sc_color);
            }
        }

        cursor_x += tab_w;
    }

    // --- + (new tab) button — transparent bg, inactive_tab_bg on hover ---
    if (show_plus) {
        // Check if mouse is hovering the + button
        const plus_hovered = blk: {
            if (!build_options.use_win32) break :blk false;
            const win = g_window orelse break :blk false;
            const mouse_x = win.mouse_x;
            const mouse_y = win.mouse_y;
            if (mouse_y < 0 or mouse_y >= @as(i32, @intFromFloat(titlebar_h))) break :blk false;
            const fx: f32 = @floatFromInt(mouse_x);
            break :blk fx >= cursor_x and fx < cursor_x + plus_btn_w;
        };

        if (plus_hovered) {
            renderQuad(cursor_x, tb_top, plus_btn_w, titlebar_h, inactive_tab_bg);
            renderQuad(cursor_x, tb_top, plus_btn_w, bdr, border_color); // bottom
        }

        // Left border — skip when last tab is active (no visual break needed)
        if (g_active_tab != num_tabs - 1) {
            renderQuad(cursor_x, tb_top, bdr, titlebar_h, border_color);
        }

        // + icon — same font/color as caption buttons, scaled up 15% to match stroke weight
        const plus_icon_color = [3]f32{ 0.75, 0.75, 0.75 };
        const plus_scale: f32 = 1.15;
        if (icon_face != null) {
            if (loadIconGlyph(0xE948)) |ch| {
                renderIconGlyph(ch, cursor_x, tb_top, plus_btn_w, titlebar_h, plus_icon_color, plus_scale);
            }
        } else {
            const plus_cx = cursor_x + plus_btn_w / 2;
            const plus_cy = tb_top + titlebar_h / 2;
            const arm: f32 = 5;
            const t: f32 = 1.0;
            renderQuad(plus_cx - arm, plus_cy - t / 2, arm * 2, t, plus_icon_color);
            renderQuad(plus_cx - t / 2, plus_cy - arm, t, arm * 2, plus_icon_color);
        }
        // Sync plus button position for double-click suppression in WndProc
        if (build_options.use_win32) {
            if (g_window) |w| {
                w.plus_btn_x_start = @intFromFloat(cursor_x);
                w.plus_btn_x_end = @intFromFloat(cursor_x + plus_btn_w);
            }
        }
        cursor_x += plus_btn_w;
    }

    // --- Caption buttons (minimize, maximize, close) ---
    const btn_h: f32 = titlebar_h;
    const hovered: win32_backend.CaptionButton = if (build_options.use_win32)
        (if (g_window) |w| w.hovered_button else .none)
    else
        .none;

    const caption_start = window_width - caption_area_w;
    renderCaptionButton(caption_start, tb_top, caption_btn_w, btn_h, .minimize, hovered == .minimize);
    renderCaptionButton(caption_start + caption_btn_w, tb_top, caption_btn_w, btn_h, .maximize, hovered == .maximize);
    renderCaptionButton(caption_start + caption_btn_w * 2, tb_top, caption_btn_w, btn_h, .close, hovered == .close);

    // --- Focus border: 1px accent border when window is focused (matches Explorer/DWM) ---
    if (build_options.use_win32) {
        const is_focused = if (g_window) |w| w.focused else false;
        const is_maximized = if (g_window) |w| win32_backend.IsZoomed(w.hwnd) != 0 else false;
        if (is_focused and !is_maximized) {
            // Same color as active tab (terminal background)
            const accent = bg;
            const b: f32 = 1; // 1px border
            renderQuad(0, 0, window_width, b, accent); // bottom
            renderQuad(0, window_height - b, window_width, b, accent); // top
            renderQuad(0, 0, b, window_height, accent); // left
            renderQuad(window_width - b, 0, b, window_height, accent); // right
        }
    }
}

const CaptionButtonType = enum { minimize, maximize, close };

/// Draw a Windows Terminal-style caption button with hover support.
/// Each button is 46×40px with a 10×10 icon centered inside.
/// Matches Windows Terminal's visual style:
///   - Normal: transparent bg, light gray icon
///   - Hover (min/max): subtle light fill bg, white icon
///   - Hover (close): red #C42B1C bg, white icon
fn renderCaptionButton(x: f32, y: f32, w: f32, h: f32, btn_type: CaptionButtonType, hovered: bool) void {
    // Draw hover background, respecting the 1px focus border on edges
    if (hovered) {
        const hover_bg = switch (btn_type) {
            .close => [3]f32{ 0.77, 0.17, 0.11 }, // #C42B1C
            else => [3]f32{
                @min(1.0, g_theme.background[0] + 0.05),
                @min(1.0, g_theme.background[1] + 0.05),
                @min(1.0, g_theme.background[2] + 0.05),
            },
        };
        // Close button is at the window edge — inset by 1px on top/right
        // to respect the focus border (matches Explorer behavior)
        if (btn_type == .close) {
            const is_focused = if (build_options.use_win32)
                (if (g_window) |win| win.focused else false)
            else
                false;
            const is_maximized = if (build_options.use_win32)
                (if (g_window) |win| win32_backend.IsZoomed(win.hwnd) != 0 else false)
            else
                false;
            const b: f32 = if (is_focused and !is_maximized) 1 else 0;
            renderQuad(x, y + b, w - b, h - b, hover_bg);
        } else {
            renderQuad(x, y, w, h, hover_bg);
        }
    }

    // Icon color: white when hovered, light gray otherwise
    const icon_color: [3]f32 = if (hovered) .{ 1.0, 1.0, 1.0 } else .{ 0.75, 0.75, 0.75 };

    // Check if window is maximized or fullscreen (for restore icon)
    const is_maximized = if (build_options.use_win32)
        (if (g_window) |win| win32_backend.IsZoomed(win.hwnd) != 0 else false)
    else
        false;
    const is_fullscreen = if (build_options.use_win32)
        (if (g_window) |win| win.is_fullscreen else false)
    else
        false;

    // Segoe MDL2 Assets glyph codepoints (same as Windows Terminal)
    const icon_codepoint: u32 = switch (btn_type) {
        .close => 0xE8BB,
        .maximize => if (is_maximized or is_fullscreen) @as(u32, 0xE923) else @as(u32, 0xE922),
        .minimize => 0xE921,
    };

    // Try rendering from Segoe MDL2 Assets icon font
    if (icon_face != null) {
        if (loadIconGlyph(icon_codepoint)) |ch| {
            renderIconGlyph(ch, x, y, w, h, icon_color, 1.0);
            return;
        }
    }

    // Fallback: quad-based icons
    const cx = x + w / 2;
    const cy = y + h / 2;

    switch (btn_type) {
        .close => {
            const size: f32 = 5;
            const steps: usize = 32;
            const t: f32 = 1.5;
            for (0..steps) |i| {
                const frac = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps - 1));
                const px = cx - size + frac * size * 2;
                const py1 = cy + size - frac * size * 2;
                renderQuad(px - t / 2, py1 - t / 2, t, t, icon_color);
                const py2 = cy - size + frac * size * 2;
                renderQuad(px - t / 2, py2 - t / 2, t, t, icon_color);
            }
        },
        .maximize => {
            const size: f32 = 5;
            const t: f32 = 1;
            renderQuad(cx - size, cy + size - t, size * 2, t, icon_color); // top
            renderQuad(cx - size, cy - size, size * 2, t, icon_color); // bottom
            renderQuad(cx - size, cy - size, t, size * 2, icon_color); // left
            renderQuad(cx + size - t, cy - size, t, size * 2, icon_color); // right
        },
        .minimize => {
            const size: f32 = 5;
            const t: f32 = 1;
            renderQuad(cx - size, cy - t / 2, size * 2, t, icon_color);
        },
    }
}

fn getGlyphInfo(codepoint: u32) ?Character {
    return glyph_cache.get(codepoint);
}

/// Load a glyph from the Segoe MDL2 Assets icon font.
fn loadIconGlyph(codepoint: u32) ?Character {
    if (icon_cache.get(codepoint)) |ch| return ch;

    const face = icon_face orelse return null;
    const alloc = g_allocator orelse return null;

    const glyph_index = face.getCharIndex(codepoint) orelse return null;
    if (glyph_index == 0) return null;

    // Use mono hinting for crisp icon rendering (snaps to pixel grid)
    face.loadGlyph(@intCast(glyph_index), .{ .target = .normal }) catch return null;
    face.renderGlyph(.normal) catch return null;

    const glyph = face.handle.*.glyph;
    const bitmap = glyph.*.bitmap;

    // Pack into icon atlas
    const region = packBitmapIntoAtlas(
        &g_icon_atlas,
        alloc,
        bitmap.width,
        bitmap.rows,
        bitmap.buffer,
        @intCast(bitmap.pitch),
    ) orelse return null;

    const ch = Character{
        .region = region,
        .size_x = @intCast(bitmap.width),
        .size_y = @intCast(bitmap.rows),
        .bearing_x = @intCast(glyph.*.bitmap_left),
        .bearing_y = @intCast(glyph.*.bitmap_top),
        .advance = @intCast(glyph.*.advance.x),
    };

    icon_cache.put(alloc, codepoint, ch) catch return null;
    return ch;
}

/// Render placeholder content for tabs that don't have a terminal yet.
fn renderPlaceholderTab(window_width: f32, window_height: f32, top_pad: f32) void {
    gl.UseProgram.?(shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(vao);

    const msg = "Tabs not yet implemented";
    const hint = "Press Ctrl+Shift+T to open, Ctrl+W to close";
    const text_color = [3]f32{ 0.4, 0.4, 0.4 };

    // Center the message vertically and horizontally
    const content_h = window_height - top_pad;
    const center_y = content_h / 2;

    // Measure and draw main message
    var msg_width: f32 = 0;
    for (msg) |ch| {
        if (getGlyphInfo(@intCast(ch))) |g| {
            msg_width += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            msg_width += cell_width;
        }
    }
    var x = (window_width - msg_width) / 2;
    var y = center_y + cell_height / 2;
    for (msg) |ch| {
        renderChar(@intCast(ch), x, y, text_color);
        if (getGlyphInfo(@intCast(ch))) |g| {
            x += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            x += cell_width;
        }
    }

    // Measure and draw hint below
    var hint_width: f32 = 0;
    for (hint) |ch| {
        if (getGlyphInfo(@intCast(ch))) |g| {
            hint_width += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            hint_width += cell_width;
        }
    }
    x = (window_width - hint_width) / 2;
    y = center_y - cell_height;
    const hint_color = [3]f32{ 0.3, 0.3, 0.3 };
    for (hint) |ch| {
        renderChar(@intCast(ch), x, y, hint_color);
        if (getGlyphInfo(@intCast(ch))) |g| {
            x += @as(f32, @floatFromInt(g.advance >> 6));
        } else {
            x += cell_width;
        }
    }
}

/// Build CPU cell buffers from terminal state.
/// Uses the efficient rowIterator to walk viewport rows via direct page
/// pointers (like Ghostty), instead of getCell() which does an O(pages)
/// pin lookup per cell.
/// Snapshot terminal cell data under the lock. Resolves colors and codepoints
/// into a flat buffer so rebuildCells can run outside the lock.
/// Modeled after Ghostty's RenderState.update() which copies row data via
/// fastmem.copy under the lock, then releases it for the renderer.
fn snapshotCells(terminal: *ghostty_vt.Terminal) void {
    const screen = terminal.screens.active;
    const render_cols = terminal.cols;

    g_snap_rows = terminal.rows;
    g_snap_cols = render_cols;

    var row_it = screen.pages.rowIterator(
        .right_down,
        .{ .viewport = .{} },
        null,
    );
    var row_idx: usize = 0;
    while (row_it.next()) |row_pin| {
        const p = &row_pin.node.data;
        const rac = row_pin.rowAndCell();
        const page_cells = p.getCells(rac.row);
        const num_cols = @min(page_cells.len, render_cols);
        const row_base = row_idx * render_cols;

        for (0..num_cols) |col_idx| {
            const cell = &page_cells[col_idx];
            var fg_color: [3]f32 = g_theme.foreground;
            var bg_color: ?[3]f32 = null;

            switch (cell.content_tag) {
                .bg_color_palette => bg_color = indexToRgb(cell.content.color_palette),
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

            if (cell.hasStyling()) {
                const style = p.styles.get(p.memory, cell.style_id);
                switch (style.fg_color) {
                    .none => {},
                    .palette => |idx| fg_color = indexToRgb(idx),
                    .rgb => |rgb| fg_color = .{
                        @as(f32, @floatFromInt(rgb.r)) / 255.0,
                        @as(f32, @floatFromInt(rgb.g)) / 255.0,
                        @as(f32, @floatFromInt(rgb.b)) / 255.0,
                    },
                }
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

            if (row_base + col_idx < MAX_SNAP) {
                g_snap[row_base + col_idx] = .{
                    .codepoint = cell.codepoint(),
                    .fg = fg_color,
                    .bg = bg_color,
                };
            }
        }
        row_idx += 1;
    }
}

/// Build GPU cell buffers from the snapshot. Does NOT require the terminal
/// mutex — reads from g_snap which was filled by snapshotCells.
fn rebuildCells() void {
    const render_rows = g_snap_rows;
    const render_cols = g_snap_cols;
    const atlas_size = if (g_atlas) |a| @as(f32, @floatFromInt(a.size)) else 512.0;

    bg_cell_count = 0;
    fg_cell_count = 0;

    for (0..render_rows) |row_idx| {
        const row_f: f32 = @floatFromInt(row_idx);
        const row_base = row_idx * render_cols;

        for (0..render_cols) |col_idx| {
            const snap_idx = row_base + col_idx;
            if (snap_idx >= MAX_SNAP) break;
            const sc = g_snap[snap_idx];

            const is_cursor = g_cached_viewport_at_bottom and (col_idx == g_cached_cursor_x and row_idx == g_cached_cursor_y);
            const is_selected = isCellSelected(col_idx, row_idx);
            const col_f: f32 = @floatFromInt(col_idx);

            var fg_color = sc.fg;

            if (is_cursor) {
                if (g_cached_cursor_effective) |effective_style| {
                    switch (effective_style) {
                        .block => {
                            if (bg_cell_count < MAX_CELLS) {
                                bg_cells[bg_cell_count] = .{ .grid_col = col_f, .grid_row = row_f, .r = g_theme.cursor_color[0], .g = g_theme.cursor_color[1], .b = g_theme.cursor_color[2] };
                                bg_cell_count += 1;
                            }
                            fg_color = g_theme.cursor_text orelse g_theme.background;
                        },
                        else => {
                            if (sc.bg) |bg| {
                                if (bg_cell_count < MAX_CELLS) {
                                    bg_cells[bg_cell_count] = .{ .grid_col = col_f, .grid_row = row_f, .r = bg[0], .g = bg[1], .b = bg[2] };
                                    bg_cell_count += 1;
                                }
                            }
                        },
                    }
                }
            } else if (is_selected) {
                if (bg_cell_count < MAX_CELLS) {
                    bg_cells[bg_cell_count] = .{ .grid_col = col_f, .grid_row = row_f, .r = g_theme.selection_background[0], .g = g_theme.selection_background[1], .b = g_theme.selection_background[2] };
                    bg_cell_count += 1;
                }
                fg_color = g_theme.selection_foreground orelse g_theme.foreground;
            } else if (sc.bg) |bg| {
                if (bg_cell_count < MAX_CELLS) {
                    bg_cells[bg_cell_count] = .{ .grid_col = col_f, .grid_row = row_f, .r = bg[0], .g = bg[1], .b = bg[2] };
                    bg_cell_count += 1;
                }
            }

            const char = sc.codepoint;
            if (char != 0 and char != ' ') {
                if (loadGlyph(char)) |ch| {
                    if (ch.region.width > 0 and ch.region.height > 0) {
                        const uv = glyphUV(ch.region, atlas_size);
                        const gx = @as(f32, @floatFromInt(ch.bearing_x));
                        const gy = cell_baseline - @as(f32, @floatFromInt(@as(i32, @intCast(ch.size_y)) - ch.bearing_y));
                        const gw = @as(f32, @floatFromInt(ch.size_x));
                        const gh = @as(f32, @floatFromInt(ch.size_y));
                        if (fg_cell_count < MAX_CELLS) {
                            fg_cells[fg_cell_count] = .{
                                .grid_col = col_f,
                                .grid_row = row_f,
                                .glyph_x = gx,
                                .glyph_y = gy,
                                .glyph_w = gw,
                                .glyph_h = gh,
                                .uv_left = uv.u0,
                                .uv_top = uv.v0,
                                .uv_right = uv.u1,
                                .uv_bottom = uv.v1,
                                .r = fg_color[0],
                                .g = fg_color[1],
                                .b = fg_color[2],
                            };
                            fg_cell_count += 1;
                        }
                    }
                }
            }
        }
    }
}

/// Determine effective cursor style (factoring in blink and focus).
/// Returns null during blink-off phase (cursor hidden).
fn cursorEffectiveStyle(terminal_style: TerminalCursorStyle, terminal_blink: bool) ?CursorStyle {
    if (!window_focused) return .block_hollow;
    const should_blink = terminal_blink and g_cursor_blink;
    if (should_blink and !g_cursor_blink_visible) return null;
    return switch (terminal_style) {
        .block => .block,
        .bar => .bar,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
}

/// Update terminal cell buffers from terminal state. Must be called with
/// the terminal mutex held. This is the only part that reads terminal state.
/// Modeled after Ghostty's critical section: lock → update state → unlock,
/// then draw outside the lock.
/// Read terminal state under the lock: dirty check, snapshot cells, cache cursor.
/// Returns true if cells need rebuilding (caller should call rebuildCells()
/// after releasing the lock). Modeled after Ghostty's split:
///   lock → RenderState.update() (snapshot) → unlock → rebuildCells()
fn updateTerminalCells(terminal: *ghostty_vt.Terminal) bool {
    const screen = terminal.screens.active;
    const viewport_active = screen.pages.viewport == .active;
    const selection_active = activeSelection().active;
    const viewport_pin = screen.pages.getTopLeft(.viewport);

    const needs_rebuild = blk: {
        if (g_force_rebuild) {
            g_force_rebuild = false;
            break :blk true;
        }
        if (!g_cells_valid) break :blk true;
        if (g_cursor_blink_visible != g_last_cursor_blink_visible) break :blk true;
        if (viewport_active != g_last_viewport_active) break :blk true;
        if (terminal.rows != g_last_rows or terminal.cols != g_last_cols) break :blk true;
        if (selection_active != g_last_selection_active) break :blk true;
        if (g_selecting) break :blk true;
        // Viewport pin changed — scroll happened (matches Ghostty's RenderState viewport_pin comparison)
        if (@as(?*anyopaque, viewport_pin.node) != g_last_viewport_node or
            viewport_pin.y != g_last_viewport_y) break :blk true;
        // Terminal-level dirty flags (eraseDisplay, fullReset, palette change, etc.)
        {
            const DirtyInt = @typeInfo(@TypeOf(terminal.flags.dirty)).@"struct".backing_integer.?;
            if (@as(DirtyInt, @bitCast(terminal.flags.dirty)) > 0) break :blk true;
        }
        // Screen-level dirty flags (selection, hyperlink hover)
        {
            const ScreenDirtyInt = @typeInfo(@TypeOf(screen.dirty)).@"struct".backing_integer.?;
            if (@as(ScreenDirtyInt, @bitCast(screen.dirty)) > 0) break :blk true;
        }
        // Per-row/page dirty flags (set by VT parser on cell changes)
        var dirty_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        while (dirty_it.next()) |row_pin| {
            const rac = row_pin.rowAndCell();
            if (rac.row.dirty or row_pin.node.data.dirty) break :blk true;
        }
        break :blk false;
    };

    // Always cache cursor state for drawing outside the lock
    g_cached_cursor_x = screen.cursor.x;
    g_cached_cursor_y = screen.cursor.y;
    g_cached_viewport_at_bottom = screen.pages.viewport == .active;
    const tcs: TerminalCursorStyle = switch (screen.cursor.cursor_style) {
        .bar => .bar,
        .block => .block,
        .underline => .underline,
        .block_hollow => .block_hollow,
    };
    g_cached_cursor_effective = cursorEffectiveStyle(tcs, terminal.modes.get(.cursor_blinking));
    if (g_cached_cursor_effective) |eff| {
        g_cached_cursor_style = eff;
    }

    if (needs_rebuild) {
        // Snapshot cell data under the lock — fast memcpy of resolved colors
        // and codepoints. Like Ghostty's RenderState.update() fastmem.copy.
        snapshotCells(terminal);

        g_cells_valid = true;
        g_last_cursor_blink_visible = g_cursor_blink_visible;
        g_last_viewport_active = viewport_active;
        g_last_viewport_node = viewport_pin.node;
        g_last_viewport_y = viewport_pin.y;
        g_last_rows = terminal.rows;
        g_last_cols = terminal.cols;
        g_last_selection_active = selection_active;

        // Clear dirty flags after snapshot
        terminal.flags.dirty = .{};
        screen.dirty = .{};
        var clear_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        while (clear_it.next()) |row_pin| {
            row_pin.rowAndCell().row.dirty = false;
        }
    }

    return needs_rebuild;
}

/// Draw terminal grid from CPU cell buffers. Does NOT require the terminal
/// mutex — all terminal state was already read by updateTerminalCells().
fn drawCells(window_height: f32, offset_x: f32, offset_y: f32) void {
    // --- Draw BG cells ---
    if (bg_cell_count > 0 and bg_shader != 0) {
        gl.UseProgram.?(bg_shader);
        gl.Uniform2f.?(gl.GetUniformLocation.?(bg_shader, "cellSize"), cell_width, cell_height);
        gl.Uniform2f.?(gl.GetUniformLocation.?(bg_shader, "gridOffset"), offset_x, offset_y);
        gl.Uniform1f.?(gl.GetUniformLocation.?(bg_shader, "windowHeight"), window_height);
        setProjectionForProgram(bg_shader, window_height);

        gl.BindVertexArray.?(bg_vao);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, bg_instance_vbo);
        gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @intCast(@sizeOf(CellBg) * bg_cell_count), &bg_cells);
        gl.DrawArraysInstanced.?(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(bg_cell_count)); g_draw_call_count += 1;
    }

    // --- Draw FG cells ---
    if (fg_cell_count > 0 and fg_shader != 0) {
        gl.UseProgram.?(fg_shader);
        gl.Uniform2f.?(gl.GetUniformLocation.?(fg_shader, "cellSize"), cell_width, cell_height);
        gl.Uniform2f.?(gl.GetUniformLocation.?(fg_shader, "gridOffset"), offset_x, offset_y);
        gl.Uniform1f.?(gl.GetUniformLocation.?(fg_shader, "windowHeight"), window_height);
        setProjectionForProgram(fg_shader, window_height);

        gl.ActiveTexture.?(c.GL_TEXTURE0);
        gl.BindTexture.?(c.GL_TEXTURE_2D, g_atlas_texture);
        gl.Uniform1i.?(gl.GetUniformLocation.?(fg_shader, "atlas"), 0);

        gl.BindVertexArray.?(fg_vao);
        gl.BindBuffer.?(c.GL_ARRAY_BUFFER, fg_instance_vbo);
        gl.BufferSubData.?(c.GL_ARRAY_BUFFER, 0, @intCast(@sizeOf(CellFg) * fg_cell_count), &fg_cells);
        gl.DrawArraysInstanced.?(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(fg_cell_count)); g_draw_call_count += 1;
    }

    // --- Cursor overlay from cached state ---
    if (g_cached_viewport_at_bottom) {
        const effective = if (!window_focused)
            CursorStyle.block_hollow
        else if (g_cursor_blink and !g_cursor_blink_visible)
            null
        else
            g_cached_cursor_style;

        if (effective) |style| {
            const px = offset_x + @as(f32, @floatFromInt(g_cached_cursor_x)) * cell_width;
            const py = window_height - offset_y - ((@as(f32, @floatFromInt(g_cached_cursor_y)) + 1) * cell_height);

            gl.UseProgram.?(shader_program);
            gl.BindVertexArray.?(vao);

            const cursor_color = g_theme.cursor_color;
            const cursor_thickness: f32 = 1.0;

            switch (style) {
                .bar => renderQuad(px, py, cursor_thickness, cell_height, cursor_color),
                .underline => renderQuad(px, py, cell_width, cursor_thickness, cursor_color),
                .block_hollow => {
                    renderQuad(px, py, cell_width, cell_height, cursor_color);
                    renderQuad(
                        px + cursor_thickness,
                        py + cursor_thickness,
                        cell_width - cursor_thickness * 2,
                        cell_height - cursor_thickness * 2,
                        g_theme.background,
                    );
                },
                .block => {},
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

// ============================================================================
// Post-Processing Custom Shader System (Ghostty-compatible)
// ============================================================================
//
// Ghostty custom shaders use Shadertoy-style conventions:
//   - iResolution: vec3 (viewport resolution in pixels, z=1.0)
//   - iTime: float (elapsed time in seconds)
//   - iTimeDelta: float (time since last frame)
//   - iFrame: int (frame counter)
//   - iChannel0: sampler2D (the terminal framebuffer)
//   - iChannelResolution[0]: vec3 (texture resolution)
//
// The shader must define: void mainImage(out vec4 fragColor, in vec2 fragCoord)

/// Vertex shader for the fullscreen post-processing quad
const post_vertex_source: [*c]const u8 =
    \\#version 330 core
    \\layout (location = 0) in vec2 aPos;
    \\layout (location = 1) in vec2 aTexCoord;
    \\out vec2 vTexCoord;
    \\void main() {
    \\    gl_Position = vec4(aPos, 0.0, 1.0);
    \\    vTexCoord = aTexCoord;
    \\}
;

/// Build the post-processing fragment shader by wrapping a Ghostty/Shadertoy-style
/// mainImage shader with our uniform declarations and main() entry point.
fn buildPostFragmentSource(allocator: std.mem.Allocator, user_shader: []const u8) ![:0]const u8 {
    const preamble =
        \\#version 330 core
        \\out vec4 _fragColor;
        \\in vec2 vTexCoord;
        \\
        \\uniform vec3 iResolution;
        \\uniform float iTime;
        \\uniform float iTimeDelta;
        \\uniform int iFrame;
        \\uniform sampler2D iChannel0;
        \\uniform vec3 iChannelResolution[1];
        \\
        \\// Provide textureLod via extension or fallback
        \\
    ;
    const epilogue =
        \\
        \\void main() {
        \\    vec2 fragCoord = vTexCoord * iResolution.xy;
        \\    mainImage(_fragColor, fragCoord);
        \\}
    ;

    const total_len = preamble.len + user_shader.len + epilogue.len;
    const buf = try allocator.alloc(u8, total_len + 1); // +1 for sentinel
    @memcpy(buf[0..preamble.len], preamble);
    @memcpy(buf[preamble.len..][0..user_shader.len], user_shader);
    @memcpy(buf[preamble.len + user_shader.len ..][0..epilogue.len], epilogue);
    buf[total_len] = 0; // null-terminate

    return buf[0..total_len :0];
}

/// Load and compile a custom post-processing shader from a file
fn initPostShader(allocator: std.mem.Allocator, shader_path: []const u8) bool {
    // Read shader source file
    const file = std.fs.cwd().openFile(shader_path, .{}) catch |err| {
        std.debug.print("Failed to open shader file '{s}': {}\n", .{ shader_path, err });
        return false;
    };
    defer file.close();

    const user_source = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read shader file: {}\n", .{err});
        return false;
    };
    defer allocator.free(user_source);

    // Build complete fragment shader
    const frag_source = buildPostFragmentSource(allocator, user_source) catch |err| {
        std.debug.print("Failed to build shader source: {}\n", .{err});
        return false;
    };
    defer allocator.free(frag_source);

    // Compile vertex shader
    const vert = compileShader(c.GL_VERTEX_SHADER, post_vertex_source) orelse return false;
    defer gl.DeleteShader.?(vert);

    // Compile fragment shader
    const frag = compileShader(c.GL_FRAGMENT_SHADER, frag_source.ptr) orelse return false;
    defer gl.DeleteShader.?(frag);

    // Link program
    g_post_program = gl.CreateProgram.?();
    gl.AttachShader.?(g_post_program, vert);
    gl.AttachShader.?(g_post_program, frag);
    gl.LinkProgram.?(g_post_program);

    var success: c.GLint = 0;
    gl.GetProgramiv.?(g_post_program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        gl.GetProgramInfoLog.?(g_post_program, 512, null, &info_log);
        std.debug.print("Post shader linking failed: {s}\n", .{&info_log});
        return false;
    }

    // Set up fullscreen quad VAO/VBO
    // Two triangles covering [-1,1] NDC with tex coords [0,1]
    const quad_verts = [_]f32{
        // pos      // tex
        -1.0, -1.0, 0.0, 0.0,
        1.0,  -1.0, 1.0, 0.0,
        -1.0, 1.0,  0.0, 1.0,

        1.0,  -1.0, 1.0, 0.0,
        1.0,  1.0,  1.0, 1.0,
        -1.0, 1.0,  0.0, 1.0,
    };

    gl.GenVertexArrays.?(1, &g_post_vao);
    gl.GenBuffers.?(1, &g_post_vbo);
    gl.BindVertexArray.?(g_post_vao);
    gl.BindBuffer.?(c.GL_ARRAY_BUFFER, g_post_vbo);
    gl.BufferData.?(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad_verts)), &quad_verts, c.GL_STATIC_DRAW);
    // position (location 0)
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), null);
    // texcoord (location 1)
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
    gl.BindVertexArray.?(0);

    std.debug.print("Custom shader loaded: {s}\n", .{shader_path});
    return true;
}

/// Create or resize the off-screen framebuffer for post-processing
fn ensurePostFBO(width: c_int, height: c_int) void {
    if (width == g_post_fb_width and height == g_post_fb_height and g_post_fbo != 0) return;

    // Delete old FBO/texture if resizing
    if (g_post_fbo != 0) {
        gl.DeleteFramebuffers.?(1, &g_post_fbo);
        gl.DeleteTextures.?(1, &g_post_texture);
    }

    // Create FBO
    gl.GenFramebuffers.?(1, &g_post_fbo);
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, g_post_fbo);

    // Create color texture
    gl.GenTextures.?(1, &g_post_texture);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_post_texture);
    gl.TexImage2D.?(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    gl.TexParameteri.?(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

    // Attach to FBO
    gl.FramebufferTexture2D.?(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, g_post_texture, 0);

    if (gl.CheckFramebufferStatus.?(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
        std.debug.print("Post-processing FBO is incomplete!\n", .{});
    }

    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    g_post_fb_width = width;
    g_post_fb_height = height;
}

/// Render the fullscreen quad with post-processing shader applied
fn renderPostProcess(width: c_int, height: c_int) void {
    // Bind default framebuffer (screen)
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    gl.Viewport.?(0, 0, width, height);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

    // Disable blending for the fullscreen quad - shader output is final color
    gl.Disable.?(c.GL_BLEND);

    gl.UseProgram.?(g_post_program);

    // Set uniforms (Ghostty/Shadertoy conventions)
    const w_f: f32 = @floatFromInt(width);
    const h_f: f32 = @floatFromInt(height);
    const now_ms = std.time.milliTimestamp();
    const elapsed: f32 = @floatCast(@as(f64, @floatFromInt(now_ms - g_start_time)) / 1000.0);

    // iResolution
    gl.Uniform3f.?(gl.GetUniformLocation.?(g_post_program, "iResolution"), w_f, h_f, 1.0);
    // iTime
    gl.Uniform1f.?(gl.GetUniformLocation.?(g_post_program, "iTime"), elapsed);
    // iTimeDelta (approximate ~16ms)
    gl.Uniform1f.?(gl.GetUniformLocation.?(g_post_program, "iTimeDelta"), 0.016);
    // iFrame
    gl.Uniform1i.?(gl.GetUniformLocation.?(g_post_program, "iFrame"), @intCast(g_frame_count));
    // iChannel0 = texture unit 0
    gl.Uniform1i.?(gl.GetUniformLocation.?(g_post_program, "iChannel0"), 0);
    // iChannelResolution[0]
    gl.Uniform3f.?(gl.GetUniformLocation.?(g_post_program, "iChannelResolution[0]"), w_f, h_f, 1.0);

    // Bind the terminal framebuffer texture
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindTexture.?(c.GL_TEXTURE_2D, g_post_texture);

    // Draw fullscreen quad
    gl.BindVertexArray.?(g_post_vao);
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); g_draw_call_count += 1;
    gl.BindVertexArray.?(0);

    // Re-enable blending for next terminal render pass
    gl.Enable.?(c.GL_BLEND);

    g_frame_count +%= 1;
}

/// Helper: render a frame to FBO, then apply post-processing to screen
/// Render with post-processing. Called after updateTerminalCells() has
/// already been called under the lock — this only does GL work.
fn renderFrameWithPostFromCells(width: c_int, height: c_int, padding: f32) void {
    ensurePostFBO(width, height);

    // 1. Render terminal to FBO
    gl.BindFramebuffer.?(c.GL_FRAMEBUFFER, g_post_fbo);
    gl.Viewport.?(0, 0, width, height);
    setProjection(@floatFromInt(width), @floatFromInt(height));
    gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
    drawCells(@floatFromInt(height), padding, padding);

    // 2. Apply post-processing shader to screen
    renderPostProcess(width, height);
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
    gl.DrawArrays.?(c.GL_TRIANGLES, 0, 6); g_draw_call_count += 1;
}

// Terminal cursor style defined in renderer/cursor.zig
const TerminalCursorStyle = renderer.cursor.TerminalCursorStyle;


/// Update the FPS counter. Call once per frame.
fn updateFps() void {
    g_fps_frame_count += 1;
    const now = std.time.milliTimestamp();
    const elapsed = now - g_fps_last_time;
    if (elapsed >= 1000) {
        g_fps_value = @as(f32, @floatFromInt(g_fps_frame_count)) * 1000.0 / @as(f32, @floatFromInt(elapsed));
        g_fps_frame_count = 0;
        g_fps_last_time = now;
    }
}

/// Render the FPS debug overlay in the bottom-right corner.
fn renderDebugOverlay(window_width: f32) void {
    const margin: f32 = 8;
    const pad_h: f32 = 4;
    const pad_v: f32 = 2;
    const line_h = g_titlebar_cell_height + pad_v * 2;
    var overlay_y: f32 = margin;

    if (g_debug_fps) {
        renderDebugLine(window_width, &overlay_y, margin, pad_h, pad_v, line_h, blk: {
            var buf: [32]u8 = undefined;
            const fps_int: u32 = @intFromFloat(@round(g_fps_value));
            break :blk std.fmt.bufPrint(&buf, "{d} fps", .{fps_int}) catch break :blk "";
        }, .{ 0.0, 1.0, 0.0 });
    }

    if (g_debug_draw_calls) {
        renderDebugLine(window_width, &overlay_y, margin, pad_h, pad_v, line_h, blk: {
            var buf: [32]u8 = undefined;
            break :blk std.fmt.bufPrint(&buf, "{d} draws", .{g_draw_call_count}) catch break :blk "";
        }, .{ 1.0, 1.0, 0.0 });

    }
}

fn renderDebugLine(window_width: f32, y_pos: *f32, margin: f32, pad_h: f32, pad_v: f32, line_h: f32, text: []const u8, text_color: [3]f32) void {
    if (text.len == 0) return;

    gl.UseProgram.?(shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(vao);

    var text_width: f32 = 0;
    for (text) |ch| {
        text_width += titlebarGlyphAdvance(@intCast(ch));
    }

    const bg_w = text_width + pad_h * 2;
    const bg_x = window_width - bg_w - margin;
    const bg_y = y_pos.*;

    renderQuad(bg_x, bg_y, bg_w, line_h, .{ 0.0, 0.0, 0.0 });

    var x = bg_x + pad_h;
    const y = bg_y + pad_v;
    for (text) |ch| {
        renderTitlebarChar(@intCast(ch), x, y, text_color);
        x += titlebarGlyphAdvance(@intCast(ch));
    }

    y_pos.* += line_h + 2; // spacing between lines
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

/// Clear all GL textures from the glyph cache and reset it.
fn clearGlyphCache(allocator: std.mem.Allocator) void {
    glyph_cache.deinit(allocator);
    glyph_cache = .empty;

    // Reset atlas — destroy GPU texture and CPU data, recreate fresh
    if (g_atlas) |*a| {
        a.deinit(allocator);
        g_atlas = null;
    }
    if (g_atlas_texture != 0) {
        gl.DeleteTextures.?(1, &g_atlas_texture);
        g_atlas_texture = 0;
        g_atlas_modified = 0;
    }
}

/// Clear fallback font faces.
fn clearFallbackFaces(allocator: std.mem.Allocator) void {
    var it = g_fallback_faces.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit();
    }
    g_fallback_faces.deinit(allocator);
    g_fallback_faces = .empty;
}

/// Try to load a font face from config, returning the face or null on failure.
fn loadFontFromConfig(
    allocator: std.mem.Allocator,
    font_family: []const u8,
    weight: directwrite.DWRITE_FONT_WEIGHT,
    font_size: u32,
    ft_lib: freetype.Library,
) ?freetype.Face {
    // Try system font via DirectWrite
    if (font_family.len > 0) {
        if (g_font_discovery) |dw| {
            if (dw.findFontFilePath(allocator, font_family, weight, .NORMAL) catch null) |result| {
                var r = result;
                defer r.deinit();
                if (ft_lib.initFace(r.path, @intCast(r.face_index))) |face| {
                    face.setCharSize(0, @as(i32, @intCast(font_size)) * 64, 96, 96) catch {
                        face.deinit();
                        return null;
                    };
                    std.debug.print("Reload: loaded system font '{s}'\n", .{font_family});
                    return face;
                } else |_| {}
            }
        }
        std.debug.print("Reload: font '{s}' not found, using embedded fallback\n", .{font_family});
    }

    // Fall back to embedded font
    const face = ft_lib.initMemoryFace(embedded.regular, 0) catch return null;
    face.setCharSize(0, @as(i32, @intCast(font_size)) * 64, 96, 96) catch {
        face.deinit();
        return null;
    };
    return face;
}

/// Resize the window to fit the current terminal grid and cell dimensions.
fn resizeWindowToGrid() void {
    const padding: f32 = 10;
    const tb: f32 = if (build_options.use_win32) @floatFromInt(win32_backend.TITLEBAR_HEIGHT) else 0;
    const content_w: f32 = cell_width * @as(f32, @floatFromInt(term_cols));
    const content_h: f32 = cell_height * @as(f32, @floatFromInt(term_rows));
    const win_w: i32 = @intFromFloat(content_w + padding * 2);
    const win_h: i32 = @intFromFloat(content_h + padding + (padding + tb));
    if (build_options.use_win32) {
        if (g_window) |w| w.setSize(win_w, win_h);
    } else {
        c.glfwSetWindowSize(g_window, win_w, win_h);
    }
}

/// Check if the config file has changed (via ReadDirectoryChangesW) and reload if so.
fn checkConfigReload(allocator: std.mem.Allocator, watcher: *ConfigWatcher) void {
    if (!watcher.hasChanged()) return;

    std.debug.print("Config file changed, reloading...\n", .{});

    const cfg = Config.load(allocator) catch |err| {
        std.debug.print("Failed to reload config: {}\n", .{err});
        return;
    };
    defer cfg.deinit(allocator);

    if (g_window == null) return;
    const ft_lib = g_ft_lib orelse return;

    // --- Theme, cursor, debug ---
    g_theme = cfg.resolved_theme;
    g_force_rebuild = true;
    g_cursor_style = cfg.@"cursor-style";
    g_cursor_blink = cfg.@"cursor-style-blink";
    g_debug_fps = cfg.@"phantty-debug-fps";
    g_debug_draw_calls = cfg.@"phantty-debug-draw-calls";

    // Sync cursor style to all tabs' terminals (rendering reads from terminal state)
    for (0..g_tab_count) |ti| {
        if (g_tabs[ti]) |tab| {
            tab.surface.render_state.mutex.lock();
            tab.surface.terminal.screens.active.cursor.cursor_style = switch (g_cursor_style) {
                .bar => .bar,
                .block => .block,
                .underline => .underline,
                .block_hollow => .block_hollow,
            };
            tab.surface.render_state.mutex.unlock();
        }
    }

    // --- Font ---
    const new_font_size = cfg.@"font-size";
    const new_weight = cfg.@"font-style".toDwriteWeight();
    const new_family = cfg.@"font-family";

    // Reload font: clear caches, load new face, recalculate metrics
    if (loadFontFromConfig(allocator, new_family, new_weight, new_font_size, ft_lib)) |new_face| {
        // Clean up old font state
        if (glyph_face) |old| old.deinit();
        clearGlyphCache(allocator);
        clearFallbackFaces(allocator);

        g_font_size = new_font_size;
        preloadCharacters(new_face);
        // glyph_face is set inside preloadCharacters

        // Rebuild titlebar font at 14pt with the new family
        if (g_titlebar_face) |old_tb| old_tb.deinit();
        g_titlebar_face = null;
        g_titlebar_cache.deinit(allocator);
        g_titlebar_cache = .empty;
        if (g_titlebar_atlas) |*a| {
            a.deinit(allocator);
            g_titlebar_atlas = null;
        }
        if (g_titlebar_atlas_texture != 0) {
            gl.DeleteTextures.?(1, &g_titlebar_atlas_texture);
            g_titlebar_atlas_texture = 0;
            g_titlebar_atlas_modified = 0;
        }
        if (loadFontFromConfig(allocator, new_family, new_weight, 10, ft_lib)) |tb_face| {
            g_titlebar_face = tb_face;
            const sm = tb_face.handle.*.size.*.metrics;
            g_titlebar_cell_height = @round(@as(f32, @floatFromInt(sm.height)) / 64.0);
            g_titlebar_baseline = @round(-@as(f32, @floatFromInt(sm.descender)) / 64.0);
        }

        // --- Window size ---
        // If window size is configured, apply it; then resize window to match new cell dims
        if (cfg.@"window-width" > 0) term_cols = cfg.@"window-width";
        if (cfg.@"window-height" > 0) term_rows = cfg.@"window-height";
        resizeWindowToGrid();

        // Resize ALL tabs' terminals and PTYs to match
        for (0..g_tab_count) |ti| {
            if (g_tabs[ti]) |tab| {
                tab.surface.render_state.mutex.lock();
                tab.surface.terminal.resize(allocator, term_cols, term_rows) catch {};
                tab.surface.render_state.mutex.unlock();
                tab.surface.pty.resize(term_cols, term_rows);
            }
        }
    } else {
        std.debug.print("Reload: failed to load font, keeping current font\n", .{});
    }

    std.debug.print("Config reloaded successfully\n", .{});
}

/// Reset cursor blink to visible state (call on keypress like Ghostty)
fn resetCursorBlink() void {
    g_cursor_blink_visible = true;
    g_last_blink_time = std.time.milliTimestamp();
}

// ============================================================================
// Shared helpers (used by both backends)
// ============================================================================

// Convert mouse position to terminal cell coordinates
fn mouseToCell(xpos: f64, ypos: f64) struct { col: usize, row: usize } {
    const padding_d: f64 = 10;
    const tb_d: f64 = if (build_options.use_win32) @floatFromInt(win32_backend.TITLEBAR_HEIGHT) else 0;
    const col_f = (xpos - padding_d) / @as(f64, cell_width);
    const row_f = (ypos - padding_d - tb_d) / @as(f64, cell_height);

    const col = if (col_f < 0) 0 else if (col_f >= @as(f64, @floatFromInt(term_cols))) term_cols - 1 else @as(usize, @intFromFloat(col_f));
    const row = if (row_f < 0) 0 else if (row_f >= @as(f64, @floatFromInt(term_rows))) term_rows - 1 else @as(usize, @intFromFloat(row_f));

    return .{ .col = col, .row = row };
}

// Check if a cell is within the current selection
fn isCellSelected(col: usize, row: usize) bool {
    if (!activeSelection().active) return false;

    var start_row = activeSelection().start_row;
    var start_col = activeSelection().start_col;
    var end_row = activeSelection().end_row;
    var end_col = activeSelection().end_col;

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

// ============================================================================
// GLFW-specific callbacks (only compiled for GLFW backend)
// ============================================================================

const glfw_callbacks = if (!build_options.use_win32) struct {
    pub fn charCallback(_: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
        if (activeSurface()) |surface| {
            resetCursorBlink();
            {
                surface.render_state.mutex.lock();
                defer surface.render_state.mutex.unlock();
                surface.terminal.scrollViewport(.bottom) catch {};
            }
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return;
            _ = surface.pty.write(buf[0..len]) catch {};
        }
    }

    pub fn mouseButtonCallback(window: ?*c.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.c) void {
        if (button == c.GLFW_MOUSE_BUTTON_LEFT) {
            var xpos: f64 = 0;
            var ypos: f64 = 0;
            c.glfwGetCursorPos(window, &xpos, &ypos);
            const cell = mouseToCell(xpos, ypos);

            if (action == c.GLFW_PRESS) {
                activeSelection().start_col = cell.col;
                activeSelection().start_row = cell.row;
                activeSelection().end_col = cell.col;
                activeSelection().end_row = cell.row;
                activeSelection().active = false;
                g_selecting = true;
                g_click_x = xpos;
                g_click_y = ypos;
            } else if (action == c.GLFW_RELEASE) {
                g_selecting = false;
            }
        }
    }

    pub fn cursorPosCallback(_: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
        if (g_selecting) {
            const cell = mouseToCell(xpos, ypos);
            activeSelection().end_col = cell.col;
            activeSelection().end_row = cell.row;

            const threshold = cell_width * 0.6;
            const padding_d: f64 = 10;
            const click_cell_x = g_click_x - padding_d - @as(f64, @floatFromInt(activeSelection().start_col)) * @as(f64, cell_width);
            const drag_cell_x = xpos - padding_d - @as(f64, @floatFromInt(cell.col)) * @as(f64, cell_width);

            const same_cell = (activeSelection().start_col == cell.col and activeSelection().start_row == cell.row);
            if (same_cell) {
                const moved_right = drag_cell_x >= threshold and click_cell_x < threshold;
                const moved_left = drag_cell_x < threshold and click_cell_x >= threshold;
                activeSelection().active = moved_right or moved_left;
            } else {
                activeSelection().active = true;
            }
        }
    }

    pub fn copySelectionToClipboard() void {
        const surface = activeSurface() orelse return;
        const window = g_window orelse return;
        const allocator = g_allocator orelse return;

        if (!activeSelection().active) return;

        var start_row = activeSelection().start_row;
        var start_col = activeSelection().start_col;
        var end_row = activeSelection().end_row;
        var end_col = activeSelection().end_col;

        if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
            std.mem.swap(usize, &start_row, &end_row);
            std.mem.swap(usize, &start_col, &end_col);
        }

        var text: std.ArrayListUnmanaged(u8) = .empty;
        defer text.deinit(allocator);

        // Lock while reading terminal cells
        surface.render_state.mutex.lock();
        const screen = surface.terminal.screens.active;
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
            if (row < end_row) {
                text.append(allocator, '\n') catch {};
            }
        }
        surface.render_state.mutex.unlock();

        if (text.items.len > 0) {
            text.append(allocator, 0) catch return;
            const str: [*:0]const u8 = @ptrCast(text.items.ptr);
            c.glfwSetClipboardString(window, str);
            std.debug.print("Copied {} bytes to clipboard\n", .{text.items.len - 1});
        }
    }

    pub fn pasteFromClipboard() void {
        const surface = activeSurface() orelse return;
        const window = g_window orelse return;

        const clipboard = c.glfwGetClipboardString(window);
        if (clipboard) |str| {
            var len: usize = 0;
            while (str[len] != 0) : (len += 1) {}
            std.debug.print("Pasting {} bytes from clipboard\n", .{len});
            if (len > 0) {
                _ = surface.pty.write(str[0..len]) catch {};
            }
        } else {
            std.debug.print("Clipboard is empty or unavailable\n", .{});
        }
    }

    pub fn windowFocusCallback(_: ?*c.GLFWwindow, focused: c_int) callconv(.c) void {
        window_focused = focused != 0;
        g_force_rebuild = true;
    }

    pub fn framebufferSizeCallback(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
        const padding_f: f32 = 10;
        const content_width = @as(f32, @floatFromInt(width)) - padding_f * 2;
        const content_height = @as(f32, @floatFromInt(height)) - padding_f * 2;

        const new_cols: u16 = @intFromFloat(@max(1, content_width / cell_width));
        const new_rows: u16 = @intFromFloat(@max(1, content_height / cell_height));

        if (new_cols != term_cols or new_rows != term_rows) {
            g_pending_resize = true;
            g_pending_cols = new_cols;
            g_pending_rows = new_rows;
            g_last_resize_time = std.time.milliTimestamp();
        }

        if (!g_resize_in_progress) {
            // Sync atlas before rendering
            if (g_atlas != null) syncAtlasTexture(&g_atlas, &g_atlas_texture, &g_atlas_modified);
            if (g_icon_atlas != null) syncAtlasTexture(&g_icon_atlas, &g_icon_atlas_texture, &g_icon_atlas_modified);
            if (g_titlebar_atlas != null) syncAtlasTexture(&g_titlebar_atlas, &g_titlebar_atlas_texture, &g_titlebar_atlas_modified);

            if (activeSurface()) |surface| {
                // Like Ghostty: hold the terminal mutex only for the
                // snapshot (reading terminal state). All GPU cell building
                // and GL work happens outside the lock.
                var needs_rebuild: bool = false;
                {
                    surface.render_state.mutex.lock();
                    defer surface.render_state.mutex.unlock();
                    updateCursorBlink();
                    needs_rebuild = updateTerminalCells(&surface.terminal);
                }

                // Build GPU cell buffers from snapshot — outside the lock.
                // IO thread can continue parsing while we build + draw.
                if (needs_rebuild) rebuildCells();
                if (g_post_enabled) {
                    renderFrameWithPostFromCells(width, height, padding_f);
                } else {
                    gl.Viewport.?(0, 0, width, height);
                    setProjection(@floatFromInt(width), @floatFromInt(height));
                    gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
                    drawCells(@floatFromInt(height), padding_f, padding_f);
                }
            } else {
                gl.Viewport.?(0, 0, width, height);
                gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
            }
        }

        c.glfwSwapBuffers(window);
    }

    pub fn scrollCallback(_: ?*c.GLFWwindow, _: f64, yoffset: f64) callconv(.c) void {
        if (activeSurface()) |surface| {
            surface.render_state.mutex.lock();
            defer surface.render_state.mutex.unlock();
            const delta: isize = @intFromFloat(-yoffset * 3);
            surface.terminal.scrollViewport(.{ .delta = delta }) catch {};
        }
    }

    pub fn toggleFullscreen() void {
        const window = g_window orelse return;

        if (g_is_fullscreen) {
            c.glfwSetWindowMonitor(window, null, g_windowed_x, g_windowed_y, g_windowed_width, g_windowed_height, c.GLFW_DONT_CARE);
            g_is_fullscreen = false;
            std.debug.print("Exited fullscreen (restored {}x{} at {},{})\n", .{ g_windowed_width, g_windowed_height, g_windowed_x, g_windowed_y });
        } else {
            c.glfwGetWindowPos(window, &g_windowed_x, &g_windowed_y);
            c.glfwGetWindowSize(window, &g_windowed_width, &g_windowed_height);
            const monitor = c.glfwGetPrimaryMonitor() orelse return;
            const mode = c.glfwGetVideoMode(monitor) orelse return;
            c.glfwSetWindowMonitor(window, monitor, 0, 0, mode.*.width, mode.*.height, mode.*.refreshRate);
            g_is_fullscreen = true;
            std.debug.print("Entered fullscreen ({}x{} @{}Hz)\n", .{ mode.*.width, mode.*.height, mode.*.refreshRate });
        }
    }

    pub fn keyCallback(_: ?*c.GLFWwindow, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
        if (action != c.GLFW_PRESS and action != c.GLFW_REPEAT) return;

        const ctrl = (mods & c.GLFW_MOD_CONTROL) != 0;
        const shift = (mods & c.GLFW_MOD_SHIFT) != 0;

        if (ctrl and shift and key == c.GLFW_KEY_C) { copySelectionToClipboard(); return; }
        if (ctrl and shift and key == c.GLFW_KEY_V) { pasteFromClipboard(); return; }
        if (ctrl and shift and key == c.GLFW_KEY_T) { _ = spawnTab(g_allocator orelse return); return; }
        if (ctrl and key == c.GLFW_KEY_W) {
            if (g_tab_count <= 1) {
                g_should_close = true;
            } else {
                closeTab(g_active_tab);
            }
            return;
        }
        if (ctrl and key == c.GLFW_KEY_TAB) {
            if (shift) {
                if (g_active_tab > 0) switchTab(g_active_tab - 1) else switchTab(g_tab_count - 1);
            } else {
                switchTab((g_active_tab + 1) % g_tab_count);
            }
            return;
        }
        if (ctrl and key == c.GLFW_KEY_COMMA) {
            std.debug.print("[keybind] Ctrl+, pressed\n", .{});
            if (g_allocator) |alloc| Config.openConfigInEditor(alloc);
            return;
        }

        const alt = (mods & c.GLFW_MOD_ALT) != 0;
        if (alt and key == c.GLFW_KEY_ENTER) { toggleFullscreen(); return; }

        if (activeSurface()) |surface| {
            const is_scroll_key = shift and (key == c.GLFW_KEY_PAGE_UP or key == c.GLFW_KEY_PAGE_DOWN);
            const is_modifier = key == c.GLFW_KEY_LEFT_SHIFT or key == c.GLFW_KEY_RIGHT_SHIFT or
                key == c.GLFW_KEY_LEFT_CONTROL or key == c.GLFW_KEY_RIGHT_CONTROL or
                key == c.GLFW_KEY_LEFT_ALT or key == c.GLFW_KEY_RIGHT_ALT or
                key == c.GLFW_KEY_LEFT_SUPER or key == c.GLFW_KEY_RIGHT_SUPER;
            if (!is_scroll_key and !is_modifier) {
                resetCursorBlink();
                surface.render_state.mutex.lock();
                surface.terminal.scrollViewport(.bottom) catch {};
                surface.render_state.mutex.unlock();
            }

            const pty = &surface.pty;
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
                        surface.render_state.mutex.lock();
                        surface.terminal.scrollViewport(.{ .delta = -@as(isize, term_rows / 2) }) catch {};
                        surface.render_state.mutex.unlock();
                        break :blk null;
                    }
                    break :blk "\x1b[5~";
                },
                c.GLFW_KEY_PAGE_DOWN => blk: {
                    if (shift) {
                        surface.render_state.mutex.lock();
                        surface.terminal.scrollViewport(.{ .delta = @as(isize, term_rows / 2) }) catch {};
                        surface.render_state.mutex.unlock();
                        break :blk null;
                    }
                    break :blk "\x1b[6~";
                },
                c.GLFW_KEY_INSERT => "\x1b[2~",
                c.GLFW_KEY_DELETE => "\x1b[3~",
                else => blk: {
                    if (ctrl and key >= c.GLFW_KEY_A and key <= c.GLFW_KEY_Z) {
                        const ctrl_char: u8 = @intCast(key - c.GLFW_KEY_A + 1);
                        _ = pty.write(&[_]u8{ctrl_char}) catch {};
                    }
                    break :blk null;
                },
            };

            if (seq) |s| _ = pty.write(s) catch {};
        }
    }
} else struct {};

// ============================================================================
// Win32-specific input processing (only compiled for Win32 backend)
// ============================================================================

const win32_input = if (build_options.use_win32) struct {

    /// Process all queued Win32 input events. Called once per frame from the main loop.
    pub fn processEvents(win: *win32_backend.Window) void {
        processKeyEvents(win);
        processCharEvents(win);
        processMouseButtonEvents(win);
        processMouseMoveEvents(win);
        processMouseWheelEvents(win);
        processSizeChange(win);
    }

    fn processKeyEvents(win: *win32_backend.Window) void {
        while (win.key_events.pop()) |ev| {
            handleKey(ev);
        }
    }

    fn processCharEvents(win: *win32_backend.Window) void {
        while (win.char_events.pop()) |ev| {
            handleChar(ev);
        }
    }

    fn processMouseButtonEvents(win: *win32_backend.Window) void {
        while (win.mouse_button_events.pop()) |ev| {
            handleMouseButton(ev);
        }
    }

    fn processMouseMoveEvents(win: *win32_backend.Window) void {
        // Only process the latest move event (coalesce)
        var latest: ?win32_backend.MouseMoveEvent = null;
        while (win.mouse_move_events.pop()) |ev| {
            latest = ev;
        }
        if (latest) |ev| {
            handleMouseMove(ev);
        }
    }

    fn processMouseWheelEvents(win: *win32_backend.Window) void {
        while (win.mouse_wheel_events.pop()) |ev| {
            handleMouseWheel(ev);
        }
    }

    fn processSizeChange(win: *win32_backend.Window) void {
        if (!win.size_changed) return;
        win.size_changed = false;

        const width = win.width;
        const height = win.height;
        const padding_f: f32 = 10;
        const tb_offset: f32 = @floatFromInt(win32_backend.TITLEBAR_HEIGHT);
        const content_width = @as(f32, @floatFromInt(width)) - padding_f * 2;
        const content_height = @as(f32, @floatFromInt(height)) - padding_f - (padding_f + tb_offset);

        const new_cols: u16 = @intFromFloat(@max(1, content_width / cell_width));
        const new_rows: u16 = @intFromFloat(@max(1, content_height / cell_height));

        if (new_cols != term_cols or new_rows != term_rows) {
            g_pending_resize = true;
            g_pending_cols = new_cols;
            g_pending_rows = new_rows;
            g_last_resize_time = std.time.milliTimestamp();
        }
    }

    fn handleChar(ev: win32_backend.CharEvent) void {
        if (!isActiveTabTerminal()) return;
        const surface = activeSurface() orelse return;
        resetCursorBlink();
        {
            surface.render_state.mutex.lock();
            defer surface.render_state.mutex.unlock();
            surface.terminal.scrollViewport(.bottom) catch {};
        }
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(ev.codepoint, &buf) catch return;
        _ = surface.pty.write(buf[0..len]) catch {};
    }

    fn handleKey(ev: win32_backend.KeyEvent) void {
        // Ctrl+Shift+C = copy
        if (ev.ctrl and ev.shift and ev.vk == 0x43) { // 'C'
            copySelectionToClipboard();
            return;
        }
        // Ctrl+Shift+V = paste
        if (ev.ctrl and ev.shift and ev.vk == 0x56) { // 'V'
            pasteFromClipboard();
            return;
        }
        // Ctrl+Shift+T = new tab
        if (ev.ctrl and ev.shift and ev.vk == 0x54) { // 'T'
            _ = spawnTab(g_allocator orelse return);
            return;
        }
        // Ctrl+W = close tab, or close app if only 1 tab
        if (ev.ctrl and ev.vk == 0x57) { // 'W'
            if (g_tab_count <= 1) {
                g_should_close = true;
            } else {
                closeTab(g_active_tab);
            }
            return;
        }
        // Ctrl+Tab = next tab
        if (ev.ctrl and ev.vk == win32_backend.VK_TAB) {
            if (ev.shift) {
                // Ctrl+Shift+Tab = previous tab
                if (g_active_tab > 0) switchTab(g_active_tab - 1) else switchTab(g_tab_count - 1);
            } else {
                switchTab((g_active_tab + 1) % g_tab_count);
            }
            return;
        }
        // Ctrl+1-9 = switch to tab N
        if (ev.ctrl and !ev.shift and ev.vk >= 0x31 and ev.vk <= 0x39) { // '1'-'9'
            const tab_idx = @as(usize, @intCast(ev.vk - 0x31));
            if (tab_idx < g_tab_count) switchTab(tab_idx);
            return;
        }
        // Ctrl+, = open config
        if (ev.ctrl and ev.vk == win32_backend.VK_OEM_COMMA) {
            std.debug.print("[keybind] Ctrl+, pressed\n", .{});
            if (g_allocator) |alloc| Config.openConfigInEditor(alloc);
            return;
        }
        // Alt+Enter = toggle fullscreen
        if (ev.alt and ev.vk == win32_backend.VK_RETURN) {
            toggleFullscreen();
            return;
        }

        // Don't send input to PTY if active tab isn't the terminal
        if (!isActiveTabTerminal()) return;

        const surface = activeSurface() orelse return;
        const pty = &surface.pty;

        // Don't reset blink / scroll-to-bottom for scroll keys or pure modifiers
        const is_scroll_key = ev.shift and (ev.vk == win32_backend.VK_PRIOR or ev.vk == win32_backend.VK_NEXT);
        const is_modifier = ev.vk == win32_backend.VK_SHIFT or ev.vk == win32_backend.VK_CONTROL or ev.vk == win32_backend.VK_MENU;
        if (!is_scroll_key and !is_modifier) {
            resetCursorBlink();
            surface.render_state.mutex.lock();
            surface.terminal.scrollViewport(.bottom) catch {};
            surface.render_state.mutex.unlock();
        }

        const seq: ?[]const u8 = switch (ev.vk) {
            win32_backend.VK_RETURN => "\r",
            win32_backend.VK_BACK => "\x7f",
            win32_backend.VK_TAB => "\t",
            win32_backend.VK_ESCAPE => "\x1b",
            win32_backend.VK_UP => "\x1b[A",
            win32_backend.VK_DOWN => "\x1b[B",
            win32_backend.VK_RIGHT => "\x1b[C",
            win32_backend.VK_LEFT => "\x1b[D",
            win32_backend.VK_HOME => "\x1b[H",
            win32_backend.VK_END => "\x1b[F",
            win32_backend.VK_PRIOR => blk: { // Page Up
                if (ev.shift) {
                    surface.render_state.mutex.lock();
                    surface.terminal.scrollViewport(.{ .delta = -@as(isize, term_rows / 2) }) catch {};
                    surface.render_state.mutex.unlock();
                    break :blk null;
                }
                break :blk "\x1b[5~";
            },
            win32_backend.VK_NEXT => blk: { // Page Down
                if (ev.shift) {
                    surface.render_state.mutex.lock();
                    surface.terminal.scrollViewport(.{ .delta = @as(isize, term_rows / 2) }) catch {};
                    surface.render_state.mutex.unlock();
                    break :blk null;
                }
                break :blk "\x1b[6~";
            },
            win32_backend.VK_INSERT => "\x1b[2~",
            win32_backend.VK_DELETE => "\x1b[3~",
            win32_backend.VK_F11 => blk: {
                toggleFullscreen();
                break :blk null;
            },
            else => blk: {
                // Ctrl+A through Ctrl+Z
                if (ev.ctrl and ev.vk >= 0x41 and ev.vk <= 0x5A) {
                    // Don't send Ctrl+C/V when shift is held (those are copy/paste)
                    if (!ev.shift) {
                        const ctrl_char: u8 = @intCast(ev.vk - 0x41 + 1);
                        _ = pty.write(&[_]u8{ctrl_char}) catch {};
                    }
                }
                break :blk null;
            },
        };

        if (seq) |s| _ = pty.write(s) catch {};
    }

    var plus_btn_pressed: bool = false;

    fn handleMouseButton(ev: win32_backend.MouseButtonEvent) void {
        // Middle-click on tab to close it
        if (ev.button == .middle and ev.action == .release) {
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            const titlebar_h: f64 = if (g_window) |w| @floatFromInt(w.titlebar_height) else 40;
            if (ypos < titlebar_h) {
                if (hitTestTab(xpos)) |tab_idx| {
                    if (g_tab_count <= 1) {
                        g_should_close = true;
                    } else {
                        closeTab(tab_idx);
                    }
                }
            }
            return;
        }

        if (ev.button == .left) {
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            const titlebar_h: f64 = if (g_window) |w| @floatFromInt(w.titlebar_height) else 40;

            if (ev.action == .press) {
                // Check if click is in the titlebar (tab bar area)
                if (ypos < titlebar_h) {
                    handleTabBarPress(xpos);
                    return;
                }

                const cell_pos = mouseToCell(xpos, ypos);
                activeSelection().start_col = cell_pos.col;
                activeSelection().start_row = cell_pos.row;
                activeSelection().end_col = cell_pos.col;
                activeSelection().end_row = cell_pos.row;
                activeSelection().active = false;
                g_selecting = true;
                g_click_x = xpos;
                g_click_y = ypos;
            } else {
                // Mouse up
                if (plus_btn_pressed) {
                    plus_btn_pressed = false;
                    // Only fire if still in the + button area
                    if (ypos < titlebar_h and hitTestPlusButton(xpos)) {
                        _ = spawnTab(g_allocator orelse return);
                    }
                    return;
                }
                g_selecting = false;
            }
        }
    }

    fn handleTabBarPress(xpos: f64) void {
        const win = g_window orelse return;
        const window_width: f64 = blk: {
            var rect: win32_backend.RECT = undefined;
            _ = win32_backend.GetClientRect(win.hwnd, &rect);
            break :blk @floatFromInt(rect.right);
        };

        const caption_area_w: f64 = 46 * 3;
        const gap_w: f64 = 42;
        const plus_btn_w: f64 = 46;
        const show_plus = g_tab_count > 1;
        const num_tabs = g_tab_count;

        const plus_total: f64 = if (show_plus) plus_btn_w else 0;
        const right_reserved: f64 = caption_area_w + gap_w + plus_total;
        const tab_area_w: f64 = window_width - right_reserved;
        const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

        // Check which tab was clicked
        var cursor: f64 = 0;
        for (0..num_tabs) |tab_idx| {
            if (xpos >= cursor and xpos < cursor + tab_w) {
                switchTab(tab_idx);
                return;
            }
            cursor += tab_w;
        }

        // Check if + button was pressed
        if (show_plus and xpos >= cursor and xpos < cursor + plus_btn_w) {
            plus_btn_pressed = true;
        }
    }

    fn hitTestTab(xpos: f64) ?usize {
        const win = g_window orelse return null;
        const window_width: f64 = blk: {
            var rect: win32_backend.RECT = undefined;
            _ = win32_backend.GetClientRect(win.hwnd, &rect);
            break :blk @floatFromInt(rect.right);
        };

        const caption_area_w: f64 = 46 * 3;
        const gap_w: f64 = 42;
        const plus_btn_w: f64 = 46;
        const show_plus = g_tab_count > 1;
        const num_tabs = g_tab_count;

        const plus_total: f64 = if (show_plus) plus_btn_w else 0;
        const right_reserved: f64 = caption_area_w + gap_w + plus_total;
        const tab_area_w: f64 = window_width - right_reserved;
        const tab_w: f64 = if (num_tabs > 0) tab_area_w / @as(f64, @floatFromInt(num_tabs)) else tab_area_w;

        var cursor: f64 = 0;
        for (0..num_tabs) |tab_idx| {
            if (xpos >= cursor and xpos < cursor + tab_w) {
                return tab_idx;
            }
            cursor += tab_w;
        }
        return null;
    }

    fn hitTestPlusButton(xpos: f64) bool {
        const win = g_window orelse return false;
        const window_width: f64 = blk: {
            var rect: win32_backend.RECT = undefined;
            _ = win32_backend.GetClientRect(win.hwnd, &rect);
            break :blk @floatFromInt(rect.right);
        };

        const caption_area_w: f64 = 46 * 3;
        const gap_w: f64 = 42;
        const plus_btn_w: f64 = 46;
        if (g_tab_count <= 1) return false;

        const right_reserved: f64 = caption_area_w + gap_w + plus_btn_w;
        const tab_area_w: f64 = window_width - right_reserved;
        const tab_w: f64 = tab_area_w / @as(f64, @floatFromInt(g_tab_count));
        const plus_x = tab_w * @as(f64, @floatFromInt(g_tab_count));

        return xpos >= plus_x and xpos < plus_x + plus_btn_w;
    }

    fn handleMouseMove(ev: win32_backend.MouseMoveEvent) void {
        if (!g_selecting) return;

        const xpos: f64 = @floatFromInt(ev.x);
        const ypos: f64 = @floatFromInt(ev.y);
        const cell_pos = mouseToCell(xpos, ypos);
        activeSelection().end_col = cell_pos.col;
        activeSelection().end_row = cell_pos.row;

        const threshold = cell_width * 0.6;
        const padding_d: f64 = 10;
        const click_cell_x = g_click_x - padding_d - @as(f64, @floatFromInt(activeSelection().start_col)) * @as(f64, cell_width);
        const drag_cell_x = xpos - padding_d - @as(f64, @floatFromInt(cell_pos.col)) * @as(f64, cell_width);

        const same_cell = (activeSelection().start_col == cell_pos.col and activeSelection().start_row == cell_pos.row);
        if (same_cell) {
            const moved_right = drag_cell_x >= threshold and click_cell_x < threshold;
            const moved_left = drag_cell_x < threshold and click_cell_x >= threshold;
            activeSelection().active = moved_right or moved_left;
        } else {
            activeSelection().active = true;
        }
    }

    fn handleMouseWheel(ev: win32_backend.MouseWheelEvent) void {
        if (activeSurface()) |surface| {
            surface.render_state.mutex.lock();
            defer surface.render_state.mutex.unlock();
            // WHEEL_DELTA is 120 per notch. Convert to lines (3 lines per notch, like GLFW).
            const notches = @as(f64, @floatFromInt(ev.delta)) / 120.0;
            const delta: isize = @intFromFloat(-notches * 3);
            surface.terminal.scrollViewport(.{ .delta = delta }) catch {};
        }
    }

    // --- Clipboard (Win32 native) ---

    fn copySelectionToClipboard() void {
        const surface = activeSurface() orelse return;
        const allocator = g_allocator orelse return;
        const win = g_window orelse return;

        if (!activeSelection().active) return;

        var start_row = activeSelection().start_row;
        var start_col = activeSelection().start_col;
        var end_row = activeSelection().end_row;
        var end_col = activeSelection().end_col;

        if (start_row > end_row or (start_row == end_row and start_col > end_col)) {
            std.mem.swap(usize, &start_row, &end_row);
            std.mem.swap(usize, &start_col, &end_col);
        }

        var text: std.ArrayListUnmanaged(u8) = .empty;
        defer text.deinit(allocator);

        // Lock while reading terminal cells
        surface.render_state.mutex.lock();
        const screen = surface.terminal.screens.active;
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
            if (row < end_row) {
                text.append(allocator, '\n') catch {};
            }
        }
        surface.render_state.mutex.unlock();

        if (text.items.len == 0) return;

        // Win32 clipboard: OpenClipboard → EmptyClipboard → SetClipboardData → CloseClipboard
        if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
        defer _ = win32_backend.CloseClipboard();
        _ = win32_backend.EmptyClipboard();

        // Clipboard wants a GlobalAlloc'd GMEM_MOVEABLE buffer with null-terminated data
        const size = text.items.len + 1;
        const hmem = win32_backend.GlobalAlloc(0x0002, size) orelse return; // GMEM_MOVEABLE
        const ptr = win32_backend.GlobalLock(hmem) orelse return;
        const dest: [*]u8 = @ptrCast(ptr);
        @memcpy(dest[0..text.items.len], text.items);
        dest[text.items.len] = 0;
        _ = win32_backend.GlobalUnlock(hmem);

        _ = win32_backend.SetClipboardData(1, hmem); // CF_TEXT = 1
        std.debug.print("Copied {} bytes to clipboard\n", .{text.items.len});
    }

    fn pasteFromClipboard() void {
        const surface = activeSurface() orelse return;
        const win = g_window orelse return;

        if (win32_backend.OpenClipboard(win.hwnd) == 0) return;
        defer _ = win32_backend.CloseClipboard();

        const hmem = win32_backend.GetClipboardData(1) orelse return; // CF_TEXT
        const ptr = win32_backend.GlobalLock(hmem) orelse return;
        defer _ = win32_backend.GlobalUnlock(hmem);

        const data: [*]const u8 = @ptrCast(ptr);
        var len: usize = 0;
        while (data[len] != 0) : (len += 1) {}

        if (len > 0) {
            std.debug.print("Pasting {} bytes from clipboard\n", .{len});
            _ = surface.pty.write(data[0..len]) catch {};
        }
    }

    // --- Fullscreen toggle (Win32 native) ---

    var saved_style: win32_backend.DWORD = 0;
    var saved_rect: win32_backend.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var is_fullscreen: bool = false;

    fn toggleFullscreen() void {
        const win = g_window orelse return;

        if (is_fullscreen) {
            // Restore windowed mode
            _ = win32_backend.SetWindowLongW(win.hwnd, -16, @bitCast(saved_style)); // GWL_STYLE
            _ = win32_backend.SetWindowPos(
                win.hwnd, null,
                saved_rect.left, saved_rect.top,
                saved_rect.right - saved_rect.left,
                saved_rect.bottom - saved_rect.top,
                0x0020 | 0x0040, // SWP_FRAMECHANGED | SWP_SHOWWINDOW
            );
            is_fullscreen = false;
            if (g_window) |w| w.is_fullscreen = false;
            std.debug.print("Exited fullscreen\n", .{});
        } else {
            // Save current state
            _ = win32_backend.GetWindowRect(win.hwnd, &saved_rect);
            saved_style = @bitCast(win32_backend.GetWindowLongW(win.hwnd, -16));

            // Set borderless style
            const new_style = saved_style & ~@as(u32, 0x00CF0000); // remove WS_OVERLAPPEDWINDOW
            _ = win32_backend.SetWindowLongW(win.hwnd, -16, @bitCast(new_style));

            // Get monitor info for the monitor containing this window
            const monitor = win32_backend.MonitorFromWindow(win.hwnd, 0x00000002) orelse return; // MONITOR_DEFAULTTONEAREST
            var mi = win32_backend.MONITORINFO{ .cbSize = @sizeOf(win32_backend.MONITORINFO) };
            if (win32_backend.GetMonitorInfoW(monitor, &mi) != 0) {
                _ = win32_backend.SetWindowPos(
                    win.hwnd, null,
                    mi.rcMonitor.left, mi.rcMonitor.top,
                    mi.rcMonitor.right - mi.rcMonitor.left,
                    mi.rcMonitor.bottom - mi.rcMonitor.top,
                    0x0020 | 0x0040, // SWP_FRAMECHANGED | SWP_SHOWWINDOW
                );
            }
            is_fullscreen = true;
            if (g_window) |w| w.is_fullscreen = true;
            std.debug.print("Entered fullscreen\n", .{});
        }
    }
} else struct {};

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

/// Set the orthographic projection matrix on a specific shader program.
fn setProjectionForProgram(program: c.GLuint, window_height: f32) void {
    var viewport: [4]c.GLint = undefined;
    gl.GetIntegerv.?(c.GL_VIEWPORT, &viewport);
    const width: f32 = @floatFromInt(viewport[2]);
    const height: f32 = @floatFromInt(viewport[3]);
    _ = window_height;

    const projection = [16]f32{
        2.0 / width, 0.0,          0.0,  0.0,
        0.0,         2.0 / height, 0.0,  0.0,
        0.0,         0.0,          -1.0, 0.0,
        -1.0,        -1.0,         0.0,  1.0,
    };

    gl.UniformMatrix4fv.?(gl.GetUniformLocation.?(program, "projection"), 1, c.GL_FALSE, &projection);
}

pub fn main() !void {
    std.debug.print("Phantty starting...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Handle special commands before loading full config
    if (Config.hasCommand(allocator, "help") or Config.hasCommand(allocator, "h")) {
        Config.printHelp();
        return;
    }
    if (Config.hasCommand(allocator, "list-fonts")) {
        try listSystemFonts(allocator);
        return;
    }
    if (Config.hasCommand(allocator, "list-themes")) {
        Config.listThemes();
        return;
    }
    if (Config.hasCommand(allocator, "test-font-discovery")) {
        try testFontDiscovery(allocator);
        return;
    }
    if (Config.hasCommand(allocator, "show-config-path")) {
        Config.printConfigPath(allocator);
        return;
    }

    // Load configuration: defaults → config file → CLI flags
    const cfg = try Config.load(allocator);
    defer cfg.deinit(allocator);

    // Apply config to globals
    g_theme = cfg.resolved_theme;
    g_force_rebuild = true;
    g_cursor_style = cfg.@"cursor-style";
    g_cursor_blink = cfg.@"cursor-style-blink";
    g_debug_fps = cfg.@"phantty-debug-fps";
    g_debug_draw_calls = cfg.@"phantty-debug-draw-calls";
    // Apply window size from config (0 = auto, use defaults)
    if (cfg.@"window-width" > 0) term_cols = cfg.@"window-width";
    if (cfg.@"window-height" > 0) term_rows = cfg.@"window-height";

    const requested_font = cfg.@"font-family";
    const requested_weight = cfg.@"font-style".toDwriteWeight();
    const font_size = cfg.@"font-size";
    const shader_path = cfg.@"custom-shader";

    if (cfg.config_path) |path| {
        std.debug.print("Config loaded from: {s}\n", .{path});
    } else {
        std.debug.print("No config file found, using defaults\n", .{});
    }

    // Store allocator and config globals (needed by spawnTab, closeTab, etc.)
    g_allocator = allocator;
    g_scrollback_limit = cfg.@"scrollback-limit";

    // Resolve shell command from config and store globally for tab spawning
    {
        const cmd = cfg.shell;
        if (std.mem.eql(u8, cmd, "cmd")) {
            const lit = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe");
            @memcpy(g_shell_cmd_buf[0..lit.len], lit);
            g_shell_cmd_buf[lit.len] = 0;
            g_shell_cmd_len = lit.len;
        } else if (std.mem.eql(u8, cmd, "powershell")) {
            const lit = std.unicode.utf8ToUtf16LeStringLiteral("powershell.exe");
            @memcpy(g_shell_cmd_buf[0..lit.len], lit);
            g_shell_cmd_buf[lit.len] = 0;
            g_shell_cmd_len = lit.len;
        } else if (std.mem.eql(u8, cmd, "pwsh")) {
            const lit = std.unicode.utf8ToUtf16LeStringLiteral("pwsh.exe");
            @memcpy(g_shell_cmd_buf[0..lit.len], lit);
            g_shell_cmd_buf[lit.len] = 0;
            g_shell_cmd_len = lit.len;
        } else if (std.mem.eql(u8, cmd, "wsl")) {
            const lit = std.unicode.utf8ToUtf16LeStringLiteral("wsl.exe");
            @memcpy(g_shell_cmd_buf[0..lit.len], lit);
            g_shell_cmd_buf[lit.len] = 0;
            g_shell_cmd_len = lit.len;
        } else {
            const len = std.unicode.utf8ToUtf16Le(&g_shell_cmd_buf, cmd) catch 0;
            g_shell_cmd_buf[len] = 0;
            g_shell_cmd_len = len;
        }
        std.debug.print("Shell command resolved: '{s}'\n", .{cfg.shell});
    }

    // Spawn the initial tab (PTY + terminal)
    if (!spawnTab(allocator)) {
        std.debug.print("Failed to spawn initial tab\n", .{});
        return error.SpawnFailed;
    }

    // ================================================================
    // Initialize windowing backend
    // Defers MUST be at function scope so the window/GL context
    // stays alive for the rest of main().
    // ================================================================

    // --- Win32 backend state (only used when use_win32=true) ---
    var win32_window: if (build_options.use_win32) win32_backend.Window else void = undefined;
    if (build_options.use_win32) {
        const title = std.unicode.utf8ToUtf16LeStringLiteral("Phantty [win32]");
        win32_window = win32_backend.Window.init(800, 600, title) catch |err| {
            std.debug.print("Failed to create Win32 window: {}\n", .{err});
            return err;
        };
        win32_backend.setGlobalWindow(&win32_window);
        g_window = &win32_window;
    }
    defer if (build_options.use_win32) {
        win32_window.deinit();
    };

    // --- GLFW backend state (only used when use_win32=false) ---
    if (!build_options.use_win32) {
        if (c.glfwInit() == 0) {
            std.debug.print("Failed to initialize GLFW\n", .{});
            return error.GLFWInitFailed;
        }
    }
    defer if (!build_options.use_win32) {
        c.glfwTerminate();
    };

    // GLFW window handle — needs to be at function scope so the defer works
    var glfw_window: if (build_options.use_win32) void else ?*c.GLFWwindow = if (build_options.use_win32) {} else null;
    if (!build_options.use_win32) {
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 3);
        c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);

        glfw_window = c.glfwCreateWindow(800, 600, "Phantty [glfw]", null, null);
        if (glfw_window == null) {
            std.debug.print("Failed to create GLFW window\n", .{});
            return error.WindowCreationFailed;
        }

        c.glfwMakeContextCurrent(glfw_window);

        // Set up input callbacks
        _ = c.glfwSetCharCallback(glfw_window, glfw_callbacks.charCallback);
        _ = c.glfwSetKeyCallback(glfw_window, glfw_callbacks.keyCallback);
        _ = c.glfwSetScrollCallback(glfw_window, glfw_callbacks.scrollCallback);
        _ = c.glfwSetMouseButtonCallback(glfw_window, glfw_callbacks.mouseButtonCallback);
        _ = c.glfwSetCursorPosCallback(glfw_window, glfw_callbacks.cursorPosCallback);
        _ = c.glfwSetFramebufferSizeCallback(glfw_window, glfw_callbacks.framebufferSizeCallback);
        _ = c.glfwSetWindowFocusCallback(glfw_window, glfw_callbacks.windowFocusCallback);

        g_window = glfw_window;
    }
    defer if (!build_options.use_win32) {
        if (glfw_window) |w| c.glfwDestroyWindow(w);
    };

    // --- Load OpenGL via GLAD ---
    {
        const version = if (build_options.use_win32)
            c.gladLoadGLContext(&gl, @ptrCast(&win32_backend.glGetProcAddress))
        else
            c.gladLoadGLContext(&gl, @ptrCast(&c.glfwGetProcAddress));

        if (version == 0) {
            std.debug.print("Failed to initialize GLAD\n", .{});
            return error.GLADInitFailed;
        }
        const backend_tag = if (build_options.use_win32) " (Win32 backend)" else "";
        std.debug.print("OpenGL {}.{}{s}\n", .{ c.GLAD_VERSION_MAJOR(version), c.GLAD_VERSION_MINOR(version), backend_tag });
    }

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

    // Fallback faces are cleaned up in the main defer block (with glyph_face)

    // Try to find the requested font via DirectWrite
    var font_result: ?directwrite.FontDiscovery.FontResult = null;

    if (dw_discovery) |*dw| {
        if (requested_font.len > 0) {
            if (dw.findFontFilePath(allocator, requested_font, requested_weight, .NORMAL) catch null) |result| {
                font_result = result;
                std.debug.print("Found system font: {s}\n", .{result.path});
            } else {
                std.debug.print("Font '{s}' not found, will use embedded fallback\n", .{requested_font});
            }
        } else {
            std.debug.print("No font-family set, will use embedded fallback\n", .{});
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
    // Don't defer face.deinit() here — glyph_face owns it and may be
    // replaced by hot-reload. Cleanup is in the defer block below.

    face.setCharSize(0, @as(i32, @intCast(font_size)) * 64, 96, 96) catch |err| {
        std.debug.print("Failed to set font size: {}\n", .{err});
        return err;
    };

    // Store font size globally for fallback fonts
    g_font_size = font_size;

    if (!initShaders()) {
        std.debug.print("Failed to initialize shaders\n", .{});
        return error.ShaderInitFailed;
    }
    initBuffers();
    initInstancedBuffers();
    preloadCharacters(face);

    // Initialize titlebar font — same family at fixed 14pt for crisp tab titles
    {
        const titlebar_pt: u32 = 10;
        const tb_face = loadFontFromConfig(allocator, requested_font, requested_weight, titlebar_pt, ft_lib);
        if (tb_face) |tf| {
            g_titlebar_face = tf;

            // Calculate titlebar cell metrics from the 14pt face
            const sm = tf.handle.*.size.*.metrics;
            // Simple approach: use FreeType metrics directly
            const tb_ascent = @as(f32, @floatFromInt(sm.ascender)) / 64.0;
            const tb_descent = @as(f32, @floatFromInt(sm.descender)) / 64.0;
            const tb_height = @as(f32, @floatFromInt(sm.height)) / 64.0;
            g_titlebar_cell_height = @round(tb_height);
            g_titlebar_baseline = @round(-tb_descent);
            // Measure max advance across ASCII
            var max_adv: f32 = 0;
            for (32..127) |cp| {
                if (loadTitlebarGlyph(@intCast(cp))) |g| {
                    const adv = @as(f32, @floatFromInt(g.advance >> 6));
                    max_adv = @max(max_adv, adv);
                }
            }
            if (max_adv > 0) g_titlebar_cell_width = max_adv;

            std.debug.print("Titlebar font: {d:.0}x{d:.0} (ascent={d:.1}, descent={d:.1}, baseline={d:.0})\n", .{
                g_titlebar_cell_width, g_titlebar_cell_height, tb_ascent, tb_descent, g_titlebar_baseline,
            });
        } else {
            std.debug.print("Titlebar font init failed, will fall back to scaled terminal font\n", .{});
        }
    }

    // Load Segoe MDL2 Assets for caption button icons (Windows system font)
    // Size is DPI-dependent: 10px at 96 DPI, scales proportionally
    if (ft_lib.initFace("C:\\Windows\\Fonts\\segmdl2.ttf", 0)) |iface| {
        const dpi: u32 = if (build_options.use_win32)
            (if (g_window) |w| win32_backend.GetDpiForWindow(w.hwnd) else 96)
        else
            96;
        // 10px at 96 DPI = 10pt at 72 DPI. Scale for actual DPI.
        const icon_size_26_6: i32 = @intCast(10 * 64 * dpi / 96);
        iface.setCharSize(0, icon_size_26_6, 72, 72) catch {};
        icon_face = iface;
        std.debug.print("Loaded Segoe MDL2 Assets for caption icons (dpi={})\n", .{dpi});
    } else |_| {
        std.debug.print("Segoe MDL2 Assets not found, using quad-based caption icons\n", .{});
    }

    defer {
        // Clean up icon font
        if (icon_face) |f| {
            f.deinit();
            icon_face = null;
        }
        // Clean up the current font face (may have been replaced by hot-reload)
        if (glyph_face) |f| f.deinit();
        glyph_face = null;
        // Clean up glyph cache and atlas
        clearGlyphCache(allocator);
        clearFallbackFaces(allocator);
        // Clean up icon cache and icon atlas
        icon_cache.deinit(allocator);
        if (g_icon_atlas) |*a| {
            a.deinit(allocator);
            g_icon_atlas = null;
        }
        if (g_icon_atlas_texture != 0) {
            gl.DeleteTextures.?(1, &g_icon_atlas_texture);
            g_icon_atlas_texture = 0;
        }
        // Clean up titlebar font
        if (g_titlebar_face) |f| f.deinit();
        g_titlebar_face = null;
        g_titlebar_cache.deinit(allocator);
        if (g_titlebar_atlas) |*a| {
            a.deinit(allocator);
            g_titlebar_atlas = null;
        }
        if (g_titlebar_atlas_texture != 0) {
            gl.DeleteTextures.?(1, &g_titlebar_atlas_texture);
            g_titlebar_atlas_texture = 0;
        }
    }
    initSolidTexture();

    // Initialize custom post-processing shader if requested
    if (shader_path) |sp| {
        if (initPostShader(allocator, sp)) {
            g_post_enabled = true;
            g_start_time = std.time.milliTimestamp();
        } else {
            std.debug.print("Warning: custom shader failed to load, continuing without it\n", .{});
        }
    }
    defer {
        if (g_post_enabled) {
            gl.DeleteProgram.?(g_post_program);
            gl.DeleteVertexArrays.?(1, &g_post_vao);
            gl.DeleteBuffers.?(1, &g_post_vbo);
            if (g_post_fbo != 0) {
                gl.DeleteFramebuffers.?(1, &g_post_fbo);
                gl.DeleteTextures.?(1, &g_post_texture);
            }
        }
        // Clean up instanced rendering resources
        if (bg_shader != 0) gl.DeleteProgram.?(bg_shader);
        if (fg_shader != 0) gl.DeleteProgram.?(fg_shader);
        if (bg_vao != 0) gl.DeleteVertexArrays.?(1, &bg_vao);
        if (fg_vao != 0) gl.DeleteVertexArrays.?(1, &fg_vao);
        if (bg_instance_vbo != 0) gl.DeleteBuffers.?(1, &bg_instance_vbo);
        if (fg_instance_vbo != 0) gl.DeleteBuffers.?(1, &fg_instance_vbo);
        if (quad_vbo != 0) gl.DeleteBuffers.?(1, &quad_vbo);
    }

    // Calculate window size based on cell dimensions (small padding for aesthetics)
    const padding: f32 = 10;
    // Extra top offset for custom title bar (Win32 backend only)
    const titlebar_offset: f32 = if (build_options.use_win32) @floatFromInt(win32_backend.TITLEBAR_HEIGHT) else 0;
    const top_padding: f32 = padding + titlebar_offset;

    const content_width: f32 = cell_width * @as(f32, @floatFromInt(term_cols));
    const content_height: f32 = cell_height * @as(f32, @floatFromInt(term_rows));
    const window_width: i32 = @intFromFloat(content_width + padding * 2);
    const window_height: i32 = @intFromFloat(content_height + padding + top_padding);
    if (build_options.use_win32) {
        if (g_window) |w| w.setSize(window_width, window_height);
    } else {
        c.glfwSetWindowSize(glfw_window, window_width, window_height);
    }

    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    std.debug.print("Ready! Cell size: {d:.1}x{d:.1}\n", .{ cell_width, cell_height });

    // Ensure config directory + file exist so the watcher can observe from startup
    Config.ensureConfigExists(allocator);

    // Set up config file watcher (ReadDirectoryChangesW)
    var config_watcher = ConfigWatcher.init(allocator);
    if (config_watcher == null) {
        std.debug.print("Config watcher not available (config directory may not exist)\n", .{});
    }
    defer if (config_watcher) |*w| w.deinit();

    // Initialize FPS timer
    g_fps_last_time = std.time.milliTimestamp();

    // Main loop — shared logic with backend-specific window management
    var running = true;
    while (running) {
        // Check for config file changes
        if (config_watcher) |*w| checkConfigReload(allocator, w);

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

                    // Resize ALL tabs' terminals and PTYs (lock each surface)
                    for (0..g_tab_count) |ti| {
                        if (g_tabs[ti]) |tab| {
                            tab.surface.render_state.mutex.lock();
                            tab.surface.terminal.resize(allocator, term_cols, term_rows) catch |err| {
                                std.debug.print("Terminal resize error (tab {}): {}\n", .{ ti, err });
                            };
                            tab.surface.render_state.mutex.unlock();
                            // PTY resize doesn't need the mutex (independent Win32 call)
                            tab.surface.pty.resize(term_cols, term_rows);
                        }
                    }

                    // Scroll active tab to bottom after resize
                    if (activeSurface()) |surface| {
                        surface.render_state.mutex.lock();
                        defer surface.render_state.mutex.unlock();
                        surface.terminal.scrollViewport(.{ .bottom = {} }) catch {};
                    }
                }
            }
        }

        // PTY reading is handled by per-surface IO threads (termio.Thread).
        // We just need to render. The IO threads set surface.dirty when
        // new data arrives.

        // Get framebuffer size and render
        if (build_options.use_win32) {
            const win = g_window orelse break;

            // Poll Win32 messages (fills event queues + checks WM_QUIT)
            running = win.pollEvents() and !g_should_close;

            // Sync tab count to win32 for hit-testing
            win.tab_count = g_tab_count;

            // Process all queued input events (keyboard, mouse, resize)
            win32_input.processEvents(win);

            // Update focus state
            if (window_focused != win.focused) g_force_rebuild = true;
            window_focused = win.focused;

            const fb = win.getFramebufferSize();
            const fb_width: c_int = fb.width;
            const fb_height: c_int = fb.height;

            g_draw_call_count = 0;
            updateFps();

            // Sync atlas textures to GPU if modified
            if (g_atlas != null) syncAtlasTexture(&g_atlas, &g_atlas_texture, &g_atlas_modified);
            if (g_icon_atlas != null) syncAtlasTexture(&g_icon_atlas, &g_icon_atlas_texture, &g_icon_atlas_modified);
            if (g_titlebar_atlas != null) syncAtlasTexture(&g_titlebar_atlas, &g_titlebar_atlas_texture, &g_titlebar_atlas_modified);

            if (activeSurface()) |surface| {
                // Hold terminal mutex only for snapshot
                var needs_rebuild2: bool = false;
                {
                    surface.render_state.mutex.lock();
                    defer surface.render_state.mutex.unlock();
                    updateCursorBlink();
                    needs_rebuild2 = updateTerminalCells(&surface.terminal);
                }
                if (needs_rebuild2) rebuildCells();

                // GL rendering outside the lock
                if (g_post_enabled) {
                    renderFrameWithPostFromCells(fb_width, fb_height, padding);
                } else {
                    gl.Viewport.?(0, 0, fb_width, fb_height);
                    setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                    gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);

                    renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);

                    drawCells(@floatFromInt(fb_height), padding, top_padding);
                }
            } else if (!g_post_enabled) {
                gl.Viewport.?(0, 0, fb_width, fb_height);
                setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
                renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
            }

            renderDebugOverlay(@floatFromInt(fb_width));

            win.swapBuffers();
        } else {
            var fb_width: c_int = 0;
            var fb_height: c_int = 0;
            c.glfwGetFramebufferSize(glfw_window, &fb_width, &fb_height);

            g_draw_call_count = 0;
            updateFps();

            // Sync atlas textures to GPU if modified
            if (g_atlas != null) syncAtlasTexture(&g_atlas, &g_atlas_texture, &g_atlas_modified);
            if (g_icon_atlas != null) syncAtlasTexture(&g_icon_atlas, &g_icon_atlas_texture, &g_icon_atlas_modified);
            if (g_titlebar_atlas != null) syncAtlasTexture(&g_titlebar_atlas, &g_titlebar_atlas_texture, &g_titlebar_atlas_modified);

            if (activeSurface()) |surface| {
                var needs_rebuild3: bool = false;
                {
                    surface.render_state.mutex.lock();
                    defer surface.render_state.mutex.unlock();
                    updateCursorBlink();
                    needs_rebuild3 = updateTerminalCells(&surface.terminal);
                }
                if (needs_rebuild3) rebuildCells();
                if (g_post_enabled) {
                    renderFrameWithPostFromCells(fb_width, fb_height, padding);
                } else {
                    gl.Viewport.?(0, 0, fb_width, fb_height);
                    setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                    gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                    gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
                    drawCells(@floatFromInt(fb_height), padding, padding);
                }
            } else {
                gl.Viewport.?(0, 0, fb_width, fb_height);
                setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
                gl.ClearColor.?(g_theme.background[0], g_theme.background[1], g_theme.background[2], 1.0);
                gl.Clear.?(c.GL_COLOR_BUFFER_BIT);
            }

            renderDebugOverlay(@floatFromInt(fb_width));

            c.glfwSwapBuffers(glfw_window);
            c.glfwPollEvents();
            running = c.glfwWindowShouldClose(glfw_window) == 0 and !g_should_close;
        }
    }

    // Clean up all tabs
    for (0..g_tab_count) |ti| {
        if (g_tabs[ti]) |tab| {
            tab.deinit(allocator);
            allocator.destroy(tab);
            g_tabs[ti] = null;
        }
    }
    g_tab_count = 0;

    std.debug.print("Phantty exiting...\n", .{});
}
