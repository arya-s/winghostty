# Phantty: GLFW Frontend for Ghostty on Windows

A minimal Windows frontend for Ghostty using GLFW+OpenGL, following the approach recommended in the Ghostty Windows tracking discussion.

## Research Notes

From investigation of the Ghostty codebase and discussions:

- **libghostty-vt**: This is the platform-agnostic VT library we should use. It provides Terminal, Screen, Parser, Stream, and related types without pulling in platform-specific dependencies. Located at `src/lib_vt.zig`.
- **Font discovery**: Ghostty has font discovery backends (fontconfig, coretext) but none for Windows yet. We are implementing DirectWrite-based font discovery following Alacritty's crossfont approach. See `src/directwrite.zig`.
- **Font fallback**: For glyphs not in the primary font, we use DirectWrite's system font collection to find fallback fonts (similar to how crossfont/dwrote does it).
- **Built-in glyphs**: For box drawing (U+2500-U+259F), powerline symbols (U+E0B0-U+E0B3), and other special characters, we can draw them programmatically like Ghostty and Alacritty do.
- **PTY handling**: Ghostty has `WindowsPty` in `src/pty.zig` that uses Windows ConPTY API (CreatePseudoConsole). We need to implement our own since we're not using full libghostty. Confirmed: ConPTY works fine with `wsl.exe` - Windows Terminal uses exactly this approach. Reference: `microsoft/terminal/samples/ConPTY/EchoCon/`.
- **Renderer**: OpenGL renderer exists in `src/renderer/OpenGL.zig` but is tightly coupled to Ghostty. We'll write our own minimal OpenGL renderer.
- **Shell**: Start with `wsl.exe` as the shell, defer cmd/powershell for later.
- **Font**: Embed JetBrains Mono directly in the binary using `@embedFile`. Simpler than runtime file loading.

## Environment

- Build: WSL2 (cross-compile to Windows)
- Run: Windows (native .exe)
- Target: x86_64-windows-gnu

## Architecture

```
phantty.exe
    |
    +-- GLFW (window, input, OpenGL context)
    +-- OpenGL (rendering)
    +-- FreeType/HarfBuzz (font rasterization/shaping)
    +-- ghostty-vt (terminal emulation via Zig module)
    +-- ConPTY (Windows pseudo-terminal)
    +-- wsl.exe (shell process)
```

## Tasks

### Phase 1: Project Setup ✅
- [x] Create Zig project structure with build.zig
- [x] Add ghostty as dependency for ghostty-vt module
- [x] Configure cross-compilation for x86_64-windows-gnu
- [x] Verify build produces .exe
- Note: Had to disable SIMD for cross-compilation (`.simd = false`)

### Phase 2: Window and OpenGL ✅
- [x] Initialize GLFW window
- [x] Create OpenGL context (basic, will enhance later)
- [x] Implement basic render loop (buffer swap)
- [x] Handle window resize

### Phase 3: Font Rendering ✅
- [x] Embed JetBrains Mono Regular via @embedFile
- [x] Initialize FreeType library
- [x] Load font from memory buffer
- [x] Create glyph textures (per-character, not atlas yet)
- [x] Render basic text with OpenGL + shaders
- [x] Use light hinting (matches Ghostty default)
- [x] Proper baseline positioning using FreeType metrics

### Phase 3.5: Font Discovery & Sprites ✅
- [x] DirectWrite bindings for Windows (`src/directwrite.zig`)
- [x] Glyph cache with on-demand loading (hashmap-based)
- [x] z2d-based sprite canvas with anti-aliasing support
- [x] Built-in sprite drawing for box characters (U+2500-U+257F):
  - All line types (light, heavy, double)
  - Corners, T-junctions, crosses
  - Dashed lines (proper tiling)
  - Rounded corners with bezier curves
  - Diagonals with anti-aliasing
- [x] Built-in sprite drawing for block elements (U+2580-U+259F):
  - Fractional blocks (1/8 to 7/8)
  - Half blocks and quadrants
  - Shades (light/medium/dark with alpha)
- [x] Built-in sprite drawing for powerline symbols (U+E0B0-U+E0B3)
- [x] Proper sprite positioning (aligned with cell, not baseline)
- [ ] Font discovery by name (find system fonts) 
- [ ] Font fallback for missing glyphs

### Phase 4: Terminal Emulation ✅
- [x] Initialize ghostty-vt Terminal
- [x] Create VT stream for parsing
- [x] Render terminal grid (cells to quads)
- [x] Handle terminal colors and attributes

### Phase 5: PTY and Shell ✅
- [x] Implement ConPTY wrapper
- [x] Spawn wsl.exe process
- [x] Connect PTY pipes to terminal I/O
- [x] Handle async read (non-blocking with PeekNamedPipe)

### Phase 6: Input Handling ✅
- [x] Keyboard input via GLFW (char + key callbacks)
- [x] Handle special keys (arrows, Enter, Backspace, etc.)
- [x] Handle Ctrl+key combinations
- [x] Send encoded keys to PTY
- [x] Paste (Ctrl+Shift+V)
- [x] Copy (Ctrl+Shift+C)

### Phase 7: Polish ✅
- [x] Cursor rendering (solid block when focused)
- [x] Hollow cursor when window unfocused (like Ghostty)
- [x] ANSI colors (16 + 216 cube + 24 grayscale)
- [x] Scrollback with viewport tracking
- [x] Mouse wheel scrolling
- [x] Shift+PageUp/Down scrolling
- [x] Scroll to bottom on keystroke (like Ghostty)
- [x] Selection with mouse drag
- [x] Terminal resize on window resize

### Phase 8: Future Enhancements
- [ ] Font atlas for better performance
- [ ] Text shaping with HarfBuzz
- [ ] Cursor blinking
- [ ] URL detection/clicking
- [ ] Configuration file
- [ ] Multiple font support (bold, italic)
- [ ] Ligatures

## Configuration

Follows Ghostty's `key = value` format. Config file locations:
- **Windows:** `%APPDATA%\phantty\config`
- **Linux/WSL:** `$XDG_CONFIG_HOME/phantty/config` or `~/.config/phantty/config`

Supported keys (all also available as `--key value` CLI flags):
- `font-family` — Font name (default: "JetBrains Mono")
- `font-style` — Font weight (default: semi-bold)
- `font-size` — Font size in points (default: 14)
- `cursor-style` — Cursor shape: block, bar, underline, block_hollow (default: block)
- `cursor-style-blink` — Cursor blinking: true/false (default: true)
- `theme` — Theme name or file path
- `custom-shader` — GLSL post-processing shader path
- `window-height` — Initial height in cells (default: 28)
- `window-width` — Initial width in cells (default: 110)
- `scrollback-limit` — Scrollback buffer in bytes (default: 10000000)
- `config-file` — Load additional config file (prefix `?` for optional)

Theme resolution order: file path → `%APPDATA%\phantty\themes\<name>` → XDG themes dir.

## Dependencies

Zig packages (via build.zig.zon):
- ghostty (for ghostty-vt module)
- z2d (for anti-aliased sprite drawing)

Zig will fetch these transitively from ghostty:
- GLFW
- FreeType
- HarfBuzz
- libpng
- zlib

## Files

```
phantty/
  build.zig
  build.zig.zon
  src/
    main.zig              # Entry point, GLFW setup, rendering
    config.zig            # Configuration system (file + CLI parsing)
    directwrite.zig       # DirectWrite font discovery
    pty.zig               # ConPTY wrapper
    font/
      sprite.zig          # Sprite rendering entry point
      sprite/
        canvas.zig        # z2d-based drawing canvas
        draw/
          box.zig         # Box drawing characters
          common.zig      # Shared drawing utilities
    fonts/
      JetBrainsMono-Regular.ttf  # Embedded via @embedFile
      JetBrainsMono-Bold.ttf     # Available for future use
  themes/                 # Built-in themes
  test-sprites.sh         # Test script for sprite rendering
```

## Build Commands

```bash
# Build
zig build -Dtarget=x86_64-windows-gnu

# Output will be in zig-out/bin/phantty.exe
```

## Key Implementation Details

### Font Metrics (aligned with Ghostty)
- `cell_width`: From FreeType 'M' glyph advance
- `cell_height`: From FreeType `size_metrics.height` (includes line gap)
- `cell_baseline`: From FreeType `-descender` (distance from cell bottom to baseline)
- Light hinting enabled (`FT_LOAD_TARGET_LIGHT`)

### Glyph Positioning
- Text glyphs: `y0 = y + cell_baseline - (size_y - bearing_y)`
- Sprite glyphs: `bearing_y` calculated to cancel baseline offset

### Cursor Rendering
- Focused: Solid block filling entire cell
- Unfocused: Hollow rectangle (2px+ thick border)

### Scrolling Behavior
- Viewport tracks scroll position via `screen.pages.viewport`
- Cursor only shown when `viewport == .active` (at bottom)
- Typing/keys scroll to bottom automatically (except Shift+PageUp/Down)

## Session Checkpoints

### Session 1
- Created initial plan
- Researched ghostty codebase structure
- Identified key components needed

### Session 2
- Researched font discovery approaches
- Created DirectWrite bindings
- Implemented initial sprite rendering

### Session 3 (current)
- Ported Ghostty's z2d-based sprite canvas
- Implemented proper box drawing with:
  - Edge-to-edge line rendering for seamless tiling
  - Bezier curves for rounded corners
  - Proper dash patterns with tiling support
- Fixed cell height calculation using FreeType metrics
- Fixed glyph positioning with proper baseline handling
- Fixed sprite positioning (separate from text baseline)
- Added hollow cursor for unfocused window
- Switched to JetBrains Mono Regular with light hinting
- Aligned scrolling behavior with Ghostty
