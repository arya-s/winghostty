/// IO reader thread — reads from PTY in a blocking loop.
///
/// Each Surface spawns one of these. The thread blocks on ReadFile(),
/// then briefly locks the Surface mutex to feed data through the VT
/// parser and OSC scanner.
///
/// Modeled after Ghostty's `src/termio/Exec.zig` ReadThread:
/// - 1KB read buffer (like Ghostty) to keep lock hold times short
/// - Lock acquired per read chunk
/// - dirty flag set inside the lock so the render thread can't miss it

const std = @import("std");
const Surface = @import("../Surface.zig");

const Thread = @This();

const READ_BUF_SIZE = 1024;

/// The thread entry point. Runs a blocking read loop on the Surface's PTY.
pub fn threadMain(surface: *Surface) void {
    var buf: [READ_BUF_SIZE]u8 = undefined;

    while (true) {
        if (surface.exited.load(.acquire)) return;

        const bytes_read = surface.pty.read(&buf) catch {
            surface.exited.store(true, .release);
            return;
        };

        if (bytes_read == 0) {
            surface.exited.store(true, .release);
            return;
        }

        const data = buf[0..bytes_read];

        {
            surface.render_state.mutex.lock();
            defer surface.render_state.mutex.unlock();

            surface.resetOscBatch();

            var stream = surface.terminal.vtStream();
            stream.nextSlice(data) catch {};

            surface.scanForOscTitle(data);

            // Set dirty inside the lock so the render thread can't
            // miss it — it checks dirty while also holding the lock.
            surface.dirty.store(true, .release);
        }
    }
}
