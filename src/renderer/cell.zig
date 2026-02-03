/// GPU cell data types for batched rendering.
/// Phase 4 will populate these; for now they are type definitions.
///
/// Modeled after Ghostty's `src/renderer/cell.zig`.

/// Background cell — just a grid position and a color.
pub const CellBg = extern struct {
    grid_col: u16,
    grid_row: u16,
    r: f32,
    g: f32,
    b: f32,
};

/// Foreground cell — grid position, glyph offset/size, atlas UVs, and color.
pub const CellFg = extern struct {
    grid_col: u16,
    grid_row: u16,
    glyph_offset_x: f32,
    glyph_offset_y: f32,
    glyph_size_x: f32,
    glyph_size_y: f32,
    uv_x: f32,
    uv_y: f32,
    uv_w: f32,
    uv_h: f32,
    r: f32,
    g: f32,
    b: f32,
};
