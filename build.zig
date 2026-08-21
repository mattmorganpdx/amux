const std = @import("std");
const builtin = @import("builtin");

// amux pins the Zig 0.15.x series.
//
// Zig 0.16 is not usable yet for two independent reasons:
//   1. `linkSystemLibrary2` was removed; linking moved onto `std.Build.Module`.
//   2. More importantly, 0.16's translate-c cannot process the GTK4 headers.
//      glib's `G_GNUC_BEGIN_IGNORE_DEPRECATIONS` expands to `_Pragma(...)`,
//      which translate-c emits as bare `pragma`/`diagnostic` tokens, so the
//      `@cImport` in src/c.zig fails with thousands of errors. That is an
//      upstream limitation, not something this repo can work around.
//
// Revisit when translate-c handles `_Pragma`. Keep `minimum_zig_version` in
// build.zig.zon in sync with `min_zig` below.
const min_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };
const max_zig = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 }; // exclusive

const zig_ok = builtin.zig_version.order(min_zig) != .lt and
    builtin.zig_version.order(max_zig) == .lt;

pub fn build(b: *std.Build) void {
    // Gate the real build so an unsupported compiler reports this one clear
    // error instead of a wall of downstream API/translate-c failures.
    if (comptime !zig_ok) {
        @compileError(std.fmt.comptimePrint(
            "amux requires Zig >={f} and <{f}, but found {f}.\n" ++
                "Install Zig 0.15.2 and build with it, e.g.:\n" ++
                "  sudo snap revert zig      # if 0.15.2 is still on disk\n" ++
                "  sudo snap refresh --hold zig\n",
            .{ min_zig, max_zig, builtin.zig_version },
        ));
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The headless terminal engine from the Ghostty fork. Compiled in as a Zig
    // module rather than linked as a library: the generated C headers expose
    // only OSC/color/SGR/key, while the Zig module exports Terminal, Screen,
    // PageList, Parser, Stream and search.
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    });
    const ghostty_vt = ghostty_dep.module("ghostty-vt");

    // amux's seam onto that engine (src/vt.zig), as a module so the daemon, the
    // GUI and the tests all name the same thing.
    const vt_mod = b.createModule(.{
        .root_source_file = b.path("src/vt.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ghostty_vt", .module = ghostty_vt },
        },
    });

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "amux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vt", .module = vt_mod },
            },
        }),
    });

    // Link GTK4 via pkg-config
    exe.linkSystemLibrary2("gtk4", .{});

    // Link pre-built libghostty shared library.
    // The .so has all C++ dependencies (simdutf, glslang, oniguruma, etc.)
    // statically linked inside, so we only need to link libghostty itself.
    exe.addLibraryPath(b.path("ghostty-lib"));
    exe.addIncludePath(b.path("ghostty-lib"));
    exe.linkSystemLibrary2("ghostty", .{});

    // Link libnotify for desktop notifications
    exe.linkSystemLibrary2("libnotify", .{});

    // System libraries
    exe.linkLibC();

    b.installArtifact(exe);

    // --- Daemon executable ---
    //
    // No GTK and no libghostty: amuxd owns pseudoterminals and terminal state
    // only, so it runs under systemd with no display. It shares the terminal
    // engine with everything else via the ghostty_vt module.
    const amuxd = b.addExecutable(.{
        .name = "amuxd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vt", .module = vt_mod },
            },
        }),
    });
    b.installArtifact(amuxd);

    // --- CLI executable ---
    const cli = b.addExecutable(.{
        .name = "amux-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli.linkLibC();

    b.installArtifact(cli);

    // --- Tests ---
    //
    // `zig build test`. Only modules that do not need GTK or libghostty can be
    // tested this way; the GUI still has to be exercised by running it.
    const vt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vt.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ghostty_vt", .module = ghostty_vt },
            },
        }),
    });
    const run_vt_tests = b.addRunArtifact(vt_tests);

    const daemon_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "vt", .module = vt_mod },
            },
        }),
    });
    const run_daemon_tests = b.addRunArtifact(daemon_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_vt_tests.step);
    test_step.dependOn(&run_daemon_tests.step);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run amux");
    run_step.dependOn(&run_cmd.step);
}
