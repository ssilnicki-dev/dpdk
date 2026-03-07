const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const meson = b.option([]const u8, "meson", "Path to the meson executable") orelse "meson";
    const ninja = b.option([]const u8, "ninja", "Path to the ninja executable") orelse "ninja";
    const build_dir = b.option([]const u8, "build-dir", "Meson build directory") orelse "build-zig";
    const prefix = b.option([]const u8, "prefix", "Install prefix") orelse "/usr/local";
    const reconfigure = b.option(bool, "reconfigure", "Pass --reconfigure to meson setup") orelse false;

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
        "--ninja",
        ninja,
    });
    if (reconfigure) {
        configure.addArg("--reconfigure");
    }
    configure.setEnvironmentVariable("CC", "zig cc");
    configure.setEnvironmentVariable("CXX", "zig c++");
    configure.setEnvironmentVariable("AR", "zig ar");
    configure.setEnvironmentVariable("RANLIB", "zig ranlib");

    const compile = b.addSystemCommand(&.{
        meson,
        "compile",
        "-C",
        build_dir,
    });
    compile.step.dependOn(&configure.step);

    const install = b.addSystemCommand(&.{
        meson,
        "install",
        "-C",
        build_dir,
    });
    install.step.dependOn(&compile.step);

    const configure_step = b.step("configure", "Configure DPDK with meson using zig toolchain");
    configure_step.dependOn(&configure.step);

    const compile_step = b.step("compile", "Compile DPDK");
    compile_step.dependOn(&compile.step);

    b.getInstallStep().dependOn(&install.step);

    b.default_step.dependOn(&compile.step);
}
