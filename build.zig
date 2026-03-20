const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "amux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
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

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run amux");
    run_step.dependOn(&run_cmd.step);
}
