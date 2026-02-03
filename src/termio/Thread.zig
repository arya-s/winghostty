/// IO reader thread — reads from PTY in a blocking loop.
///
/// Each Surface spawns one of these. The thread blocks on ReadFile(),
/// then briefly locks the Surface mutex to feed data through the VT
/// parser and OSC scanner. The main thread only needs to check the
/// atomic dirty flag and briefly lock the mutex to read terminal state.
///
/// Modeled after Ghostty's `src/termio/Thread.zig`.
/// Ghostty uses a dedicated IO thread per surface with the same pattern:
/// blocking read → lock → feed parser → set dirty → unlock.

const std = @import("std");
const Surface = @import("../Surface.zig");

const Thread = @This();

/// The thread entry point. Runs a blocking read loop on the Surface's PTY.
///
/// - Blocks on ReadFile (no polling, no busy-wait)
/// - On data: locks render_state.mutex, feeds VT parser + OSC scanner,
///   sets dirty flag, unlocks
/// - On EOF/error: sets exited flag and exits
///
/// The thread exits when:
/// - ReadFile returns 0 (EOF — process exited)
/// - ReadFile fails with BROKEN_PIPE (pipe closed during shutdown)
/// - ReadFile fails for any other reason
pub fn threadMain(surface: *Surface) void {
    var buf: [16384]u8 = undefined;

    while (true) {
        // Blocking read — this is the key difference from Phase 1.
        // ReadFile blocks until data is available or the pipe is closed.
        const bytes_read = surface.pty.read(&buf) catch {
            // Pipe closed or error — exit thread
            surface.exited.store(true, .release);
            return;
        };

        if (bytes_read == 0) {
            // EOF — process exited
            surface.exited.store(true, .release);
            return;
        }

        const data = buf[0..bytes_read];

        // Lock briefly to feed the VT parser and OSC scanner.
        // The main thread holds this lock only during terminal state reads
        // (and title reads), so contention is minimal.
        {
            surface.render_state.mutex.lock();
            defer surface.render_state.mutex.unlock();

            // Reset OSC batch state for this read chunk. Within a single
            // read, OSC 7 takes priority over OSC 0/2.
            surface.resetOscBatch();

            // Feed VT parser
            var stream = surface.terminal.vtStream();
            stream.nextSlice(data) catch {};

            // Scan for OSC title sequences
            surface.scanForOscTitle(data);
        }

        // Signal the main thread that there's new content to render.
        // This is outside the lock — the dirty flag is atomic.
        surface.dirty.store(true, .release);
    }
}
