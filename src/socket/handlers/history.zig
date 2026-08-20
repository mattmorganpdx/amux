//! history.* handlers: list, show, search, delete.

const std = @import("std");
const protocol = @import("../protocol.zig");
const Server = @import("../server.zig");
const Window = @import("../../window.zig");
const Workspace = @import("../../workspace.zig");
const PaneTree = @import("../../pane_tree.zig");
const TerminalWidget = @import("../../terminal_widget.zig");
const CommandPalette = @import("../../command_palette.zig");
const ClaudeSessionStore = @import("../../claude_session_store.zig");
const history = @import("../../history.zig");
const c = @import("../../c.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.socket_handlers);

const common = @import("common.zig");

// Shared infrastructure, aliased so the handler bodies below read exactly as
// they did when every handler lived in one file.
const toU64 = common.toU64;
const toUsize = common.toUsize;
const gtk_dispatch_timeout_ns = common.gtk_dispatch_timeout_ns;
const runOnMainThread = common.runOnMainThread;
const respondFromMainThread = common.respondFromMainThread;
const respondFromMainThreadWith = common.respondFromMainThreadWith;
const ResolveError = common.ResolveError;
const ResolvedSurface = common.ResolvedSurface;
const RealizedRequirement = common.RealizedRequirement;
const resolveSurfaceOnMain = common.resolveSurfaceOnMain;
const resolveErrorResponse = common.resolveErrorResponse;
const ReadResult = common.ReadResult;
const readSurfaceTextOnMain = common.readSurfaceTextOnMain;
const JsonArrayBuilder = common.JsonArrayBuilder;
const jsonEscapeString = common.jsonEscapeString;
const parseDirection = common.parseDirection;

// ------------------------------------------------------------------
// History handlers — file-only, no GTK dispatch needed
// ------------------------------------------------------------------

pub fn handleHistoryList(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    const limit_param = req.getIntParam(alloc, "limit");
    const ws_filter = req.getIntParam(alloc, "workspace_id");

    var index = history.loadIndex(alloc) catch {
        // No index yet — return empty array
        return protocol.successResponse(alloc, req.id, "[]");
    };
    defer history.freeIndex(alloc, &index);

    var arr = JsonArrayBuilder.init(alloc);
    defer arr.deinit();
    try arr.startArray();

    var count: usize = 0;
    const max_count: usize = if (limit_param) |l| (toUsize(l) orelse index.entries.items.len) else index.entries.items.len;

    // Iterate in reverse (newest first)
    var i: usize = index.entries.items.len;
    while (i > 0 and count < max_count) {
        i -= 1;
        const entry = index.entries.items[i];

        // Apply workspace filter if provided
        if (ws_filter) |ws_id| {
            if (toU64(ws_id)) |filter_id| {
                if (entry.workspace_id != filter_id) continue;
            } else continue;
        }

        const entry_json = try serializeHistoryEntry(alloc, &entry);
        defer alloc.free(entry_json);
        try arr.addRaw(entry_json);
        count += 1;
    }

    try arr.endArray();
    const result = try arr.toOwnedSlice();
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

pub fn handleHistoryShow(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    const id = req.getStringParam(alloc, "id") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "id is required");
    };
    defer alloc.free(id);

    const text = history.loadEntryText(alloc, id) catch |err| switch (err) {
        error.InvalidEntryId => return protocol.errorResponse(alloc, req.id, "invalid_id", "History id contains unsupported characters"),
        else => return protocol.errorResponse(alloc, req.id, "not_found", "History entry not found"),
    };
    defer alloc.free(text);

    const escaped = try jsonEscapeString(alloc, text);
    defer alloc.free(escaped);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"id":"{s}","text":"{s}"}}
    , .{ id, escaped });
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

pub fn handleHistorySearch(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    const query = req.getStringParam(alloc, "query") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "query is required");
    };
    defer alloc.free(query);

    const results = history.searchEntries(alloc, query) catch {
        return protocol.errorResponse(alloc, req.id, "search_failed", "Failed to search history");
    };
    defer history.freeSearchResults(alloc, results);

    var arr = JsonArrayBuilder.init(alloc);
    defer arr.deinit();
    try arr.startArray();

    for (results) |entry| {
        const entry_json = try serializeHistoryEntry(alloc, &entry);
        defer alloc.free(entry_json);
        try arr.addRaw(entry_json);
    }

    try arr.endArray();
    const result = try arr.toOwnedSlice();
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

pub fn handleHistoryDelete(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    const id = req.getStringParam(alloc, "id") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "id is required");
    };
    defer alloc.free(id);

    history.deleteEntry(alloc, id) catch |err| switch (err) {
        error.InvalidEntryId => return protocol.errorResponse(alloc, req.id, "invalid_id", "History id contains unsupported characters"),
        error.NotFound => return protocol.errorResponse(alloc, req.id, "not_found", "History entry not found"),
        error.IndexUnavailable => return protocol.errorResponse(alloc, req.id, "index_unavailable", "History index could not be read"),
    };

    return protocol.successResponse(alloc, req.id, "{\"deleted\":true}");
}

fn serializeHistoryEntry(alloc: Allocator, entry: *const history.HistoryEntry) ![]const u8 {
    const escaped_title = try jsonEscapeString(alloc, entry.workspace_title);
    defer alloc.free(escaped_title);
    const escaped_cwd = try jsonEscapeString(alloc, entry.cwd);
    defer alloc.free(escaped_cwd);
    const escaped_reason = try jsonEscapeString(alloc, entry.reason);
    defer alloc.free(escaped_reason);

    return std.fmt.allocPrint(alloc,
        \\{{"id":"{s}","workspace_id":{d},"workspace_title":"{s}","pane_id":{d},"closed_at":{d},"lines":{d},"bytes":{d},"cwd":"{s}","reason":"{s}"}}
    , .{
        entry.id,
        entry.workspace_id,
        escaped_title,
        entry.pane_id,
        entry.closed_at,
        entry.lines,
        entry.bytes,
        escaped_cwd,
        escaped_reason,
    });
}
