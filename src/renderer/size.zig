/// Size and dimension types used throughout the renderer.
/// Modeled after Ghostty's size types in `src/renderer/size.zig`.

/// Grid dimensions in cells.
pub const GridSize = struct {
    cols: u16 = 80,
    rows: u16 = 24,
};

/// Cell dimensions in pixels.
pub const CellSize = struct {
    width: f32 = 10,
    height: f32 = 20,
    baseline: f32 = 4,
    cursor_height: f32 = 16,
    box_thickness: u32 = 1,
};

/// Screen padding in pixels.
pub const Padding = struct {
    /// General padding around content area
    content: f32 = 10,
    /// Extra top offset (e.g., for custom titlebar)
    titlebar: f32 = 0,

    /// Total top padding (content + titlebar)
    pub fn top(self: Padding) f32 {
        return self.content + self.titlebar;
    }
};
