# AGENTS.md

## Overview

Phantty is a Windows terminal emulator written in Zig. It uses [libghostty-vt](https://github.com/ghostty-org/ghostty) (Ghostty's VT parser and terminal state machine) for terminal emulation, with its own rendering pipeline (OpenGL + FreeType + DirectWrite on Windows).

This is a **Windows-only** project. It cross-compiles from Linux targeting `x86_64-windows`.

## Hard Rules

When working on implementing a plan from the plans directory:
 * never deviate from the plan without asking for clear consent
 * never deem something too big and choosing not to do it in the name of pragmatism
 * always ask if you have trouble because something is too big, we will break it down together and work on it step by step

## Planning

When planning, always compare what we are planning to do with https://github.com/ghostty-org/ghostty.
This is the gold standard, we want to be as close to their implementation as possible.

Use the github cli gh to browse https://github.com/ghostty-org/ghostty and always add descriptions on how ghostty does things. 

## Build Commands

```bash
make release   # Default — always use this for builds.
make clean     # Remove zig-out/ and .zig-cache/
```

**Always use `make release`** for all builds. This produces a `ReleaseFast` optimized binary with the Windows GUI subsystem (no background console window).

## Project Structure

```
src/
├── main.zig            # Entry point, GLFW window, OpenGL rendering, input handling, main loop
├── config.zig          # Config loading (file + CLI), theme resolution, key=value parser
├── config_watcher.zig  # Hot-reload via ReadDirectoryChangesW (watches config directory)
├── pty.zig             # Windows ConPTY pseudo-terminal
├── directwrite.zig     # DirectWrite FFI for Windows font discovery
├── themes.zig          # Embedded theme data (453 Ghostty-compatible themes)
└── font/
    ├── embedded.zig    # Embedded fallback font (Cozette bitmap font)
    ├── sprite.zig      # Sprite font for box drawing, block elements, braille, powerline
    └── sprite/
        ├── canvas.zig          # 2D canvas for sprite rasterization
        └── draw/
            ├── common.zig      # Shared sprite drawing utilities
            ├── box.zig         # Box drawing characters (U+2500–U+257F)
            └── braille.zig     # Braille patterns (U+2800–U+28FF)

debug/                  # Test scripts (run inside phantty terminal)
pkg/                    # Vendored build dependencies (freetype, zlib, libpng, opengl)
vendor/                 # Vendored source code
```

## Ghostty Reference

Phantty intentionally follows Ghostty's design and behavior. When implementing or modifying features, **cross-reference the Ghostty source** at https://github.com/ghostty-org/ghostty.

Key mapping of Phantty files to Ghostty counterparts:

| Phantty | Ghostty Reference | Notes |
|---------|-------------------|-------|
| `src/config.zig` | [`src/config/Config.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/config/Config.zig) | Same `key = value` format, same key names where applicable |
| `src/config_watcher.zig` | Ghostty's config reload mechanism | Hot-reload on file change |
| `src/pty.zig` | [`src/os/ConPty.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/os/ConPty.zig) | Windows ConPTY, Ghostty also has this for Windows |
| `src/themes.zig` | [`src/config/theme.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/config/theme.zig) | Same theme file format, same built-in theme collection |
| `src/font/sprite/` | [`src/font/sprite/`](https://github.com/ghostty-org/ghostty/tree/main/src/font/sprite) | Box drawing, braille — follows Ghostty's sprite approach |
| `src/font/embedded.zig` | Ghostty's embedded Cozette font | Same fallback font |
| `src/main.zig` (rendering) | [`src/renderer/OpenGL.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/renderer/OpenGL.zig) | OpenGL rendering, cell grid, shaders |
| `src/main.zig` (input) | [`src/apprt/glfw.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/apprt/glfw.zig) | GLFW key/mouse handling |
| `src/directwrite.zig` | [`src/font/discovery.zig`](https://github.com/ghostty-org/ghostty/blob/main/src/font/discovery.zig) | Font discovery (Phantty uses DirectWrite directly) |

When adding features:
- Check how Ghostty implements it first
- Match Ghostty's config key names and value formats
- Follow Ghostty's conventions for theme files, color handling, cursor behavior, etc.
- The VT parsing itself comes from Ghostty as a Zig dependency — don't reimplement terminal emulation

## Config System

Config file location: `%APPDATA%\phantty\config` (on Windows). The config directory and a default config file are created automatically at startup.

Config is loaded in order (last wins): defaults → config file → CLI flags.

Press `Ctrl+,` at runtime to open the config in notepad — changes are hot-reloaded via the file watcher.

## Dependencies

Defined in `build.zig.zon`:
- **ghostty** — libghostty-vt (VT parser + terminal state) from Ghostty's main branch
- **glfw** — Window management and input
- **z2d** — 2D graphics library
- **freetype** / **zlib** / **libpng** / **opengl** — vendored in `pkg/`
