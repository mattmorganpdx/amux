//! Where a server binds its socket.
//!
//! Both the GUI and `amuxd` used to resolve this inline, and they have to agree:
//! the socket path is what identifies a server instance, and the session file is
//! scoped to it (see `session.bindInstance`). Two copies of the chain is two
//! chances to drift.
//!
//! This is deliberately *not* the client-side lookup. `amux-cli` probes for a
//! socket that already exists, including `$XDG_RUNTIME_DIR` under socket
//! activation; a server is choosing where to bind. Different questions.

const std = @import("std");

/// The historical path, and still the fallback when nothing says otherwise.
pub const default = "/tmp/amux.sock";

/// `AMUX_SOCKET` -> `AMUX_SOCKET_PATH` -> the default.
///
/// `AMUX_SOCKET_PATH` is what panes get in their environment, so a server
/// spawned from inside a pane inherits the same socket rather than silently
/// binding a second one.
pub fn forServer() []const u8 {
    return std.posix.getenv("AMUX_SOCKET") orelse
        std.posix.getenv("AMUX_SOCKET_PATH") orelse
        default;
}
