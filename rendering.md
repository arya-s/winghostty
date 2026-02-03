# Ghostty Rendering Architecture

An analysis of how Ghostty decouples its rendering system from the terminal
core and achieves high frame rates under heavy data throughput.

---

## 1. High-Level Architecture

Ghostty is organized around three cooperating threads per terminal surface,
communicating through lock-free mailboxes and a single shared mutex:

```
+------------------+       +------------------+       +------------------+
|   IO Thread      |       |  Renderer Thread |       |   Main/App       |
|  (pty read +     | ----> |  (frame build +  | ----> |   Thread         |
|   VT parsing)    |       |   GPU submit)    |       |  (UI events,     |
|                  |       |                  |       |   input)         |
+------------------+       +------------------+       +------------------+
        |                         ^
        |  renderer_wakeup        |  surface mailbox
        +--- async notify --------+
```

**IO Thread** (`src/termio/`): Reads bytes from the PTY, parses the VT
stream, and mutates the `Terminal` state. A separate reader thread does the
raw `read()` calls in a tight non-blocking loop and calls
`Termio.processOutput()` which holds the renderer state mutex.

**Renderer Thread** (`src/renderer/Thread.zig`): Runs its own event loop
(via `xev`). Wakes up on async notifications, extracts terminal state into a
`RenderState` snapshot, builds GPU cell buffers, and submits draw calls.

**App Thread**: Handles platform UI events, keyboard input, and surface
management. Communicates with the other threads via mailboxes.

---

## 2. Decoupling: Terminal Core vs. Renderer

### 2.1 The Terminal Core (`src/terminal/`)

The terminal core is a standalone, renderer-agnostic state machine:

- **`Terminal.zig`**: The VT emulator. Processes escape sequences, manages
  cursor position, modes, scrolling regions, and colors. Has no knowledge of
  any renderer.
- **`Screen.zig` / `ScreenSet.zig`**: The grid of cells. Manages primary and
  alternate screen buffers.
- **`PageList.zig` / `page.zig`**: A linked list of `Page`s, each a single
  contiguous block of page-aligned memory containing rows, cells, styles,
  graphemes, and hyperlinks. Pages are the unit of scrollback and can be
  serialized independently.
- **`Parser.zig`**: The VT stream parser (state machine), completely
  decoupled from both terminal state and rendering.

The terminal core is published as **`libghostty-vt`** (`src/lib_vt.zig`), a
library that re-exports terminal types (`Terminal`, `Screen`, `Parser`,
`RenderState`, etc.) for use by external consumers. This library has zero
renderer dependencies.

### 2.2 The Boundary: `renderer.State` and the Mutex

The only coupling point between the IO thread and the renderer thread is the
`renderer.State` struct (`src/renderer/State.zig`):

```zig
pub struct State {
    mutex: *std.Thread.Mutex,    // THE shared lock
    terminal: *Terminal,          // the live terminal
    inspector: ?*Inspector,
    preedit: ?Preedit,
    mouse: Mouse,
}
```

The IO thread holds `mutex` while mutating `terminal`. The renderer thread
holds `mutex` briefly in `updateFrame()` to snapshot the terminal state into
its own `RenderState`, then releases it. This is the **only lock** shared
between the two hot paths.

### 2.3 `RenderState` -- The Snapshot (`src/terminal/render.zig`)

This is the key abstraction that decouples the renderer from the live
terminal. Instead of cloning the entire screen (which Ghostty did through
v1.2.x and was a bottleneck), `RenderState` is a **persistent, incrementally
updated snapshot**:

```zig
pub const RenderState = struct {
    rows: CellCountInt,
    cols: CellCountInt,
    colors: Colors,
    cursor: Cursor,
    row_data: std.MultiArrayList(Row),  // per-row: pin, cells, dirty flag, selection
    dirty: Dirty,                       // .false | .partial | .full
    screen: ScreenSet.Key,
    viewport_pin: ?PageList.Pin,
};
```

On each frame, `RenderState.update()` is called while the mutex is held.
It only copies rows that have their `dirty` flag set. For clean rows, it
skips entirely. This is what makes the critical section fast:

1. Check terminal-level dirty flags (bitcast to int, compare to 0)
2. Check screen-level dirty flags
3. Check if viewport pin changed (scrolled)
4. If nothing global changed, iterate rows and skip non-dirty ones
5. For dirty rows, `fastmem.copy` the raw cell data and resolve managed
   memory (graphemes, styles) into arena-allocated copies

The dirty state cascades: `Page.dirty` -> `Row.dirty` -> detected by
`RenderState.update()`. After reading, dirty flags are cleared.

### 2.4 The Generic Renderer Pattern (`src/renderer/generic.zig`)

The rendering backend is abstracted through a comptime generic pattern:

```zig
pub fn Renderer(comptime GraphicsAPI: type) type { ... }
```

The `GraphicsAPI` must provide:
- `GraphicsAPI` -- configures the runtime surface, provides `Target`s
- `Target` -- abstract render target (surface or offscreen buffer)
- `Frame` -- context for drawing a frame, provides `RenderPass`es
- `RenderPass` / `Step` -- draw commands with buffers and textures
- `Pipeline` -- vertex + fragment shader pair
- `Buffer` -- GPU buffer abstraction
- `Texture` -- GPU texture abstraction

At compile time, exactly one backend is selected:

```zig
pub const Renderer = switch (build_config.renderer) {
    .metal   => GenericRenderer(Metal),
    .opengl  => GenericRenderer(OpenGL),
    .webgl   => WebGL,
};
```

The `GenericRenderer` wrapper contains **all** the shared logic: cell
rebuilding, font shaping, cursor rendering, preedit, search highlights,
image handling, and custom shaders. The backend-specific code (`Metal.zig`,
`OpenGL.zig`) only handles GPU API specifics.

---

## 3. How Rendering Stays Fast Under Heavy Data

### 3.1 Two-Phase Rendering: `updateFrame` then `drawFrame`

The renderer thread separates frame work into two phases:

**`updateFrame(state, cursor_blink_visible)`** (CPU-heavy):
1. Locks the `renderer.State` mutex
2. Calls `RenderState.update()` to snapshot dirty terminal rows
3. Checks `synchronized_output` mode -- if active, **skips the entire
   frame** (the terminal batches all updates atomically)
4. Unlocks the mutex (critical section ends here)
5. Outside the lock: resolves links, search highlights, and overlays
6. Takes the `draw_mutex` and calls `rebuildCells()` to convert terminal
   state into GPU vertex data (CPU-side buffers only)

**`drawFrame(sync)`** (GPU-heavy):
1. Takes the `draw_mutex`
2. Checks `needs_redraw` -- skips if nothing changed (no cells rebuilt,
   no size change, no animations)
3. Gets the next frame from the swap chain
4. Syncs cell data, uniforms, and font atlas textures to the GPU
5. Issues render passes and presents

This separation means the terminal mutex is held for the **minimum possible
time** -- just the snapshot. GPU work never blocks the IO thread.

### 3.2 Dirty Tracking at Every Level

Dirty tracking is Ghostty's primary optimization. It operates at four levels:

| Level | Flag | Effect |
|-------|------|--------|
| Terminal | `terminal.flags.dirty` (packed struct) | Forces full `RenderState` rebuild |
| Screen | `screen.dirty` (packed struct) | Forces full `RenderState` rebuild |
| Page | `page.dirty: bool` | All rows in page treated as dirty |
| Row | `row.dirty: bool` | Individual row re-copied to `RenderState` |

In `rebuildCells()`, there is another layer:

| Level | Flag | Effect |
|-------|------|--------|
| RenderState | `.dirty = .full` | All GPU cell buffers rebuilt |
| RenderState | `.dirty = .partial` | Only dirty rows' GPU cells rebuilt |
| RenderState | `.dirty = .false` | Cell rebuild skipped entirely |

When a user is simply looking at a static terminal, **nothing happens** --
no cells are rebuilt, no GPU uploads occur, and `drawFrame` bails out early
after checking `needs_redraw`.

### 3.3 Data Flow for Heavy Output (e.g. `cat large_file`)

When the pty produces a burst of data:

1. **Read thread**: tight `read()` loop with non-blocking fd, reads 1KB
   chunks, calls `processOutput()` inline (`@call(.always_inline, ...)`)
2. **`processOutput()`**: locks the renderer state mutex, calls
   `queueRender()` (async wakeup to renderer thread), then feeds bytes
   through `terminal_stream.nextSlice()` which runs the VT parser and
   mutates terminal state directly
3. **Parser/Terminal**: marks rows and pages as dirty as cells change
4. **Renderer thread**: wakes up from async notification, but the actual
   render is **coalesced** -- multiple wakeups between frames result in a
   single `updateFrame` call. The wakeup callback immediately calls
   `renderCallback` which does one `updateFrame` + `drawFrame` cycle

The key insight: **the IO thread processes all available data before the
renderer wakes up**. The read thread runs in a tight non-blocking loop
consuming everything from the pty. By the time the renderer thread's
event loop processes the wakeup, the terminal state already reflects all
the data. The renderer then snapshots whatever is current, skipping all
the intermediate states that were never visible.

### 3.4 Synchronized Output Mode (DEC Mode 2026)

When a program sends `ESC[?2026h` (begin synchronized update), the renderer
detects this in `updateFrame()`:

```zig
if (state.terminal.modes.get(.synchronized_output)) {
    log.debug("synchronized output started, skipping render", .{});
    return;
}
```

The renderer **completely skips** frame building until the program sends
`ESC[?2026l` (end synchronized update). This means a program can write
hundreds of lines of output atomically with zero rendering overhead. There
is also a safety timeout (`sync_reset_ms = 1000`) to prevent a misbehaving
program from freezing the terminal.

### 3.5 Triple Buffering and Swap Chains

On Metal, Ghostty uses **triple buffering** (`swap_chain_count = 3`). On
OpenGL, it uses single buffering (`swap_chain_count = 1`) because OpenGL's
frame completion is synchronous.

The swap chain manages `FrameState` structs that hold per-frame GPU
resources (uniform buffers, cell buffers, textures). A semaphore ensures
the CPU doesn't get too far ahead of the GPU:

```zig
const SwapChain = struct {
    frames: [buf_count]FrameState,
    frame_index: IntFittingRange(0, buf_count),
    frame_sema: std.Thread.Semaphore = .{ .permits = buf_count },
};
```

### 3.6 Font Atlas Diffing

Font atlas textures are only re-uploaded when they've been modified. Each
frame tracks a `grayscale_modified` / `color_modified` counter and compares
it against the atlas's atomic modification counter:

```zig
const modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
if (modified <= frame.grayscale_modified) break :texture;  // skip upload
```

### 3.7 CVDisplayLink (macOS) and Adaptive Frame Rate

On macOS, Ghostty uses a `CVDisplayLink` to drive rendering at the display's
native refresh rate. The display link fires a callback that triggers
`draw_now` on the renderer thread:

```zig
fn displayLinkCallback(_: *DisplayLink, ud: ?*xev.Async) void {
    const draw_now = ud orelse return;
    draw_now.notify() catch {};
}
```

The display link is **stopped** when the window is unfocused or occluded,
and the renderer falls back to change-driven updates (only rendering when
the terminal state actually changes). Thread QoS classes are also adjusted:

| State | QoS Class |
|-------|-----------|
| Focused + Visible | `.user_interactive` |
| Unfocused + Visible | `.user_initiated` |
| Not Visible | `.utility` |

On non-macOS (Linux/OpenGL), the renderer thread uses a timer at
`DRAW_INTERVAL = 8ms` (~120 FPS) for animation-driven draw calls, but
actual frame content updates (`updateFrame`) are only triggered by wakeup
notifications from the IO thread.

### 3.8 The `rebuildCells` Optimization

`rebuildCells` converts `RenderState` rows into GPU vertex data. It uses
a `Contents` structure with:

- **`bg_cells`**: flat array of background colors indexed by `row * cols + col`
- **`fg_rows`**: an `ArrayListCollection` of foreground cell vertices,
  one list per row

When only a few rows are dirty (the common case for interactive use), only
those rows' GPU data is rebuilt. For a full rebuild (resize, screen switch),
all rows are cleared and rebuilt. The per-row structure means clearing a
single row's GPU data is O(1).

---

## 4. Summary: Why Ghostty Renders Fast

| Technique | Impact |
|-----------|--------|
| Separate IO/render threads | IO never blocks on GPU; GPU never blocks on IO |
| Single brief mutex for terminal state | Minimal contention between threads |
| Incremental `RenderState` (not full clone) | Eliminated the #1 bottleneck from pre-1.3 |
| Multi-level dirty tracking | Only changed rows are re-processed |
| Wakeup coalescing | Multiple IO events = single render frame |
| Synchronized output | Atomic updates skip rendering entirely |
| Triple buffering (Metal) | CPU and GPU work overlapped |
| CVDisplayLink + adaptive QoS | Native refresh rate; saves power when idle |
| `fastmem.copy` for cell data | Optimized bulk memory copy for row snapshots |
| Per-row GPU cell buffers | O(1) row clearing, partial GPU updates |
| Font atlas diffing | Texture uploads only when glyphs change |
| `needs_redraw` early-out | Static terminals do zero GPU work |
