const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const meson = b.option([]const u8, "meson", "Path to the meson executable") orelse "meson";
    const ninja = b.option([]const u8, "ninja", "Path to the ninja executable") orelse "ninja";
    const build_dir = b.option([]const u8, "build-dir", "Meson build directory") orelse "build-zig";
    const prefix = b.option([]const u8, "prefix", "Install prefix") orelse "/usr/local";
    const reconfigure = b.option(bool, "reconfigure", "Pass --reconfigure to meson setup") orelse false;
    const default_library = b.option([]const u8, "default-library", "Meson default_library (static/shared/both)") orelse "static";

    if (!std.mem.eql(u8, default_library, "static") and
        !std.mem.eql(u8, default_library, "shared") and
        !std.mem.eql(u8, default_library, "both"))
    {
        std.debug.panic("Invalid default-library '{s}', expected static/shared/both", .{default_library});
    }

    const buildtype = switch (optimize) {
        .Debug => "debug",
        .ReleaseSafe => "debugoptimized",
        .ReleaseFast => "release",
        .ReleaseSmall => "minsize",
    };

    const configure = b.addSystemCommand(&.{
        meson,
        "setup",
        build_dir,
        ".",
        "--prefix",
        prefix,
        "--backend",
        "ninja",
        "--buildtype",
        buildtype,
        "--default-library",
        default_library,
    });
    if (reconfigure) {
        configure.addArg("--reconfigure");
    }
    configure.setEnvironmentVariable("NINJA", ninja);
    configure.setEnvironmentVariable("CC", "zig cc");
    configure.setEnvironmentVariable("CXX", "zig c++");
    configure.setEnvironmentVariable("CFLAGS", "-fno-sanitize=undefined");
    configure.setEnvironmentVariable("CXXFLAGS", "-fno-sanitize=undefined");
    configure.setEnvironmentVariable("AR", "zig ar");
    configure.setEnvironmentVariable("RANLIB", "zig ranlib");

    const compile = b.addSystemCommand(&.{
        meson,
        "compile",
        "-C",
        build_dir,
    });
    compile.step.dependOn(&configure.step);

    const configure_step = b.step("configure", "Configure DPDK with meson using zig toolchain");
    configure_step.dependOn(&configure.step);

    const compile_step = b.step("compile", "Compile DPDK");
    compile_step.dependOn(&compile.step);

    b.default_step.dependOn(&compile.step);

    _ = b.addModule("dpdk", .{ .root_source_file = b.path("zig/dpdk.zig") });
}
