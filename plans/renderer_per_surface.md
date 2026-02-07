# Renderer Per Surface Architecture

## Overview

Following Ghostty's architecture, each Surface needs its own renderer with its own:
- Cell buffers (bg_cells, fg_cells, color_fg_cells)
- Render state (cached cursor, viewport info, dirty flags)
- Renderer thread that independently processes frames

## Ghostty Architecture Reference

From `src/Surface.zig`:
```zig
renderer: Renderer,                    // owns cell buffers, shaders, GL state
renderer_state: rendererpkg.State,     // shared state with mutex
renderer_thread: rendererpkg.Thread,   // thread controller (event loop)
renderer_thr: std.Thread,              // actual OS thread
```

From `src/renderer/generic.zig`:
```zig
cells: cellpkg.Contents,               // per-renderer cell buffers
uniforms: shaderpkg.Uniforms,          // per-renderer uniform values
```

From `src/renderer/Thread.zig`:
```zig
// Event loop with:
- wakeup async (force render from any thread)
- stop async (terminate thread)
- render_h timer (main render timer)
- draw_h timer (animation draw timer)
- cursor_h timer (cursor blink)
```

## Current Phantty Architecture

**Problem:** Global state in `AppWindow.zig`:
- `threadlocal var bg_cells: [MAX_CELLS]CellBg`
- `threadlocal var fg_cells: [MAX_CELLS]CellFg`
- `threadlocal var color_fg_cells: [MAX_CELLS]CellFg`
- `threadlocal var bg_cell_count: usize`
- `threadlocal var fg_cell_count: usize`
- `threadlocal var g_snap_*` snapshot data
- `threadlocal var g_cached_*` cursor state

Single render loop iterates all surfaces, but they share these buffers.

## Implementation Plan

### Phase 1: Create Renderer Struct

**Create:** `src/Renderer.zig`

Move all per-surface render state into a struct:

```zig
const Renderer = @This();

const MAX_CELLS = 65536;

/// Cell buffer types
pub const CellBg = extern struct {
    grid_col: f32,
    grid_row: f32,
    r: f32,
    g: f32,
    b: f32,
};

pub const CellFg = extern struct {
    grid_col: f32,
    grid_row: f32,
    glyph_x: f32,
    glyph_y: f32,
    glyph_w: f32,
    glyph_h: f32,
    uv_left: f32,
    uv_top: f32,
    uv_right: f32,
    uv_bottom: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// Per-renderer cell buffers
bg_cells: [MAX_CELLS]CellBg,
fg_cells: [MAX_CELLS]CellFg,
color_fg_cells: [MAX_CELLS]CellFg,
bg_cell_count: usize,
fg_cell_count: usize,
color_fg_cell_count: usize,

/// Snapshot data (from terminal under lock)
snap_cells: []u8,  // allocated buffer for cell snapshot
snap_rows: usize,
snap_cols: usize,

/// Cached cursor state
cached_cursor_col: usize,
cached_cursor_row: usize,
cached_cursor_style: CursorStyle,
cached_cursor_visible: bool,
cached_viewport_at_bottom: bool,

/// Dirty/rebuild flags
cells_valid: bool,
force_rebuild: bool,

/// Reference to owning surface
surface: *Surface,

/// Mutex for render state
mutex: std.Thread.Mutex,

pub fn init(alloc: Allocator, surface: *Surface) !*Renderer { ... }
pub fn deinit(self: *Renderer, alloc: Allocator) void { ... }

/// Update from terminal state (called with terminal mutex held)
pub fn updateFromTerminal(self: *Renderer, terminal: *Terminal, is_focused: bool) bool { ... }

/// Rebuild cell buffers from snapshot
pub fn rebuildCells(self: *Renderer) void { ... }

/// Draw cells to current GL context at given offset
pub fn drawCells(self: *Renderer, window_height: f32, offset_x: f32, offset_y: f32) void { ... }
```

### Phase 2: Update Surface to Own Renderer

**Modify:** `src/Surface.zig`

```zig
const Surface = struct {
    // ... existing fields ...
    
    renderer: *Renderer,
    renderer_thread: ?*RendererThread,  // Phase 3
    
    pub fn init(...) !*Surface {
        // ... existing init ...
        self.renderer = try Renderer.init(alloc, self);
    }
    
    pub fn deinit(self: *Surface, alloc: Allocator) void {
        if (self.renderer_thread) |rt| rt.stop();
        self.renderer.deinit(alloc);
        // ... existing deinit ...
    }
};
```

### Phase 3: Create Renderer Thread

**Create:** `src/RendererThread.zig`

```zig
const RendererThread = @This();

const RENDER_INTERVAL_MS = 8;  // ~120 FPS
const CURSOR_BLINK_INTERVAL_MS = 600;

renderer: *Renderer,
surface: *Surface,
thread: std.Thread,

/// Signals
should_stop: std.atomic.Value(bool),
wakeup_event: std.Thread.ResetEvent,

/// Timing
last_render_time: i64,
cursor_blink_visible: bool,
last_cursor_blink_time: i64,

pub fn init(renderer: *Renderer, surface: *Surface) !*RendererThread { ... }
pub fn deinit(self: *RendererThread) void { ... }

/// Start the render thread
pub fn start(self: *RendererThread) !void {
    self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
}

/// Signal thread to stop and wait for it
pub fn stop(self: *RendererThread) void {
    self.should_stop.store(true, .release);
    self.wakeup_event.set();
    self.thread.join();
}

/// Wake up the render thread to force a render
pub fn wakeup(self: *RendererThread) void {
    self.wakeup_event.set();
}

fn threadMain(self: *RendererThread) void {
    while (!self.should_stop.load(.acquire)) {
        // Wait for wakeup or timeout
        self.wakeup_event.timedWait(RENDER_INTERVAL_MS * std.time.ns_per_ms) catch {};
        self.wakeup_event.reset();
        
        if (self.should_stop.load(.acquire)) break;
        
        // Update cursor blink
        self.updateCursorBlink();
        
        // Update cells from terminal
        {
            self.surface.render_state.mutex.lock();
            defer self.surface.render_state.mutex.unlock();
            _ = self.renderer.updateFromTerminal(&self.surface.terminal, true);
        }
        
        // Rebuild cells
        self.renderer.rebuildCells();
        
        // Signal main thread that this surface needs redraw
        self.surface.needs_redraw.store(true, .release);
    }
}

fn updateCursorBlink(self: *RendererThread) void {
    const now = std.time.milliTimestamp();
    if (now - self.last_cursor_blink_time >= CURSOR_BLINK_INTERVAL_MS) {
        self.cursor_blink_visible = !self.cursor_blink_visible;
        self.last_cursor_blink_time = now;
    }
}
```

### Phase 4: Update AppWindow Render Loop

**Modify:** `src/AppWindow.zig`

The main render loop changes from rebuilding cells to just drawing:

```zig
// In render loop for multi-split:
for (split_rects) |rect| {
    const surface = rect.surface;
    const renderer = surface.renderer;
    
    // Check if surface needs redraw (set by renderer thread)
    if (!surface.needs_redraw.load(.acquire)) continue;
    surface.needs_redraw.store(false, .release);
    
    // Set scissor for this surface
    const scissor_y = fb_height - rect.y - rect.height;
    gl.Scissor(rect.x, scissor_y, rect.width, rect.height);
    
    // Draw this surface's cells at its offset
    renderer.drawCells(@floatFromInt(fb_height), @floatFromInt(rect.x), @floatFromInt(rect.y));
    
    // Draw unfocused overlay if needed
    if (!is_focused) {
        renderUnfocusedOverlay(rect, @floatFromInt(fb_height));
    }
}
```

### Phase 5: OpenGL Context Management

Since all surfaces share the same GLFW window and OpenGL context, we need to ensure:

1. **Shared resources** (shaders, VAOs, VBOs, atlas texture) are initialized once
2. **Per-surface VBOs** for instance data - each Renderer has its own VBO for cell instance data
3. **Main thread draws** - all GL calls happen on main thread, renderer threads just prepare data

**Modify:** `src/Renderer.zig` to have per-renderer VBOs:

```zig
/// Per-renderer OpenGL objects (instance VBOs only)
bg_instance_vbo: c.GLuint,
fg_instance_vbo: c.GLuint,
color_fg_instance_vbo: c.GLuint,

pub fn initGL(self: *Renderer) void {
    // Create instance VBOs for this renderer
    gl.GenBuffers(1, &self.bg_instance_vbo);
    gl.GenBuffers(1, &self.fg_instance_vbo);
    gl.GenBuffers(1, &self.color_fg_instance_vbo);
    
    // Setup buffer storage
    gl.BindBuffer(GL_ARRAY_BUFFER, self.bg_instance_vbo);
    gl.BufferData(GL_ARRAY_BUFFER, @sizeOf(CellBg) * MAX_CELLS, null, GL_DYNAMIC_DRAW);
    // ... same for fg and color_fg ...
}

pub fn deinitGL(self: *Renderer) void {
    gl.DeleteBuffers(1, &self.bg_instance_vbo);
    gl.DeleteBuffers(1, &self.fg_instance_vbo);
    gl.DeleteBuffers(1, &self.color_fg_instance_vbo);
}
```

### Phase 6: Thread Synchronization

Key synchronization points:

1. **Terminal mutex** - held when reading terminal state in renderer thread
2. **needs_redraw atomic** - renderer thread sets, main thread clears
3. **GL calls only on main thread** - renderer threads prepare data, main thread draws

```zig
// In Surface:
needs_redraw: std.atomic.Value(bool),

// In Renderer thread:
// Prepare cells (no GL)
self.renderer.updateFromTerminal(...);
self.renderer.rebuildCells();
self.surface.needs_redraw.store(true, .release);

// In main thread render loop:
if (surface.needs_redraw.load(.acquire)) {
    surface.needs_redraw.store(false, .release);
    // Upload to GPU and draw
    renderer.uploadAndDraw(...);
}
```

## Files Summary

| File | Action | Description |
|------|--------|-------------|
| `src/Renderer.zig` | Create | Per-surface renderer with cell buffers |
| `src/RendererThread.zig` | Create | Per-surface render thread |
| `src/Surface.zig` | Modify | Add renderer, renderer_thread fields |
| `src/AppWindow.zig` | Modify | Change render loop to use per-surface renderers |

## Migration Strategy

1. Create `Renderer.zig` with all cell buffer types and functions moved from `AppWindow.zig`
2. Keep global state temporarily for single-surface fast path
3. Add `Renderer` to `Surface` struct
4. Create `RendererThread.zig`
5. Update multi-split render loop to use per-surface renderers
6. Once working, remove global state from `AppWindow.zig`
7. Make single-surface path also use the Renderer struct for consistency

## Testing

1. Single tab, no splits - should work identically
2. Create split - both surfaces should render their content
3. Type in both splits - content updates independently
4. Close split - remaining surface continues working
5. Multiple tabs with splits - each maintains its state
6. Resize window - all surfaces resize correctly
