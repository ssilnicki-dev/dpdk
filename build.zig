const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const meson = b.option([]const u8, "meson", "Path to the meson executable") orelse "meson";
    const ninja = b.option([]const u8, "ninja", "Path to the ninja executable") orelse "ninja";
    const build_dir = b.option([]const u8, "build_dir", "Meson build directory") orelse b.pathFromRoot("build-zig");
    const source_dir = b.pathFromRoot(".");
    const prefix = b.option([]const u8, "prefix", "Install prefix") orelse "/usr/local";
    const reconfigure = b.option(bool, "reconfigure", "Pass --reconfigure to meson setup") orelse false;
    const default_library = b.option([]const u8, "default_library", "Meson default_library (static/shared/both)") orelse "static";
    const enable_kmods = b.option(bool, "enable_kmods", "Enable compilation of kernel modules") orelse true;
    const install_usertools = b.option(bool, "install_usertools", "Install usertools") orelse true;
    const install_examples = b.option(bool, "install_examples", "Install examples") orelse true;
    const install_buildtools = b.option(bool, "install_buildtools", "Install buildtools") orelse true;
    const build_tests = b.option(bool, "build_tests", "Build tests") orelse true;
    const disable_apps = b.option([]const u8, "disable_apps", "List of disabled apps") orelse "";
    const enable_drivers = b.option([]const u8, "enable_drivers", "List of enabled drivers") orelse "*";

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
        source_dir,
        "--prefix",
        prefix,
        "--backend",
        "ninja",
        "--buildtype",
        buildtype,
        "--default-library",
        default_library,
    });

    configure.addArgs(&.{
        std.fmt.allocPrint(b.allocator, "-Denable_kmods={any}", .{enable_kmods}) catch @panic("failed"),
        std.fmt.allocPrint(b.allocator, "-Dtests={any}", .{build_tests}) catch @panic("failed"),
        std.fmt.allocPrint(b.allocator, "-Dinstall_buildtools={any}", .{install_buildtools}) catch @panic("failed"),
        std.fmt.allocPrint(b.allocator, "-Dinstall_examples={any}", .{install_examples}) catch @panic("failed"),
        std.fmt.allocPrint(b.allocator, "-Dinstall_usertools={any}", .{install_usertools}) catch @panic("failed"),
        std.fmt.allocPrint(b.allocator, "-Denable_drivers={s}", .{enable_drivers}) catch @panic("failed"),
    });
    if (disable_apps.len > 0) configure.addArg(std.fmt.allocPrint(b.allocator, "-Ddisable_apps={s}", .{disable_apps}) catch @panic("failed"));
    if (reconfigure) configure.addArg("--reconfigure");

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

    b.default_step.dependOn(&install.step);
}
