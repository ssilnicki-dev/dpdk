const std = @import("std");

fn normalizePrefix(prefix: []const u8) []const u8 {
    return std.mem.trim(u8, prefix, "/");
}

fn stagedPath(b: *std.Build, destdir: []const u8, prefix: []const u8, leaf: []const u8) []const u8 {
    const normalized_prefix = normalizePrefix(prefix);
    if (normalized_prefix.len == 0) {
        return std.fs.path.join(b.allocator, &.{ destdir, leaf }) catch @panic("OOM");
    }
    return std.fs.path.join(b.allocator, &.{ destdir, normalized_prefix, leaf }) catch @panic("OOM");
}

pub fn build(b: *std.Build) void {
    _ = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const meson = b.option([]const u8, "meson", "Path to the meson executable") orelse "meson";
    const ninja = b.option([]const u8, "ninja", "Path to the ninja executable") orelse "ninja";
    const build_dir = b.option([]const u8, "build-dir", "Meson build directory") orelse "build-zig";
    const prefix = b.option([]const u8, "prefix", "Install prefix inside the staging directory") orelse "/";
    const destdir = b.option([]const u8, "destdir", "Meson DESTDIR staging directory") orelse b.install_prefix;
    const reconfigure = b.option(bool, "reconfigure", "Pass --reconfigure to meson setup") orelse false;
    const default_library = b.option([]const u8, "default-library", "Meson default_library (static/shared/both)") orelse "static";

    if (!std.mem.eql(u8, default_library, "static") and
        !std.mem.eql(u8, default_library, "shared") and
        !std.mem.eql(u8, default_library, "both")) {
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
        "--libdir",
        "lib",
        "--includedir",
        "include",
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

    const install = b.addSystemCommand(&.{
        meson,
        "install",
        "-C",
        build_dir,
    });
    install.setEnvironmentVariable("DESTDIR", destdir);
    install.step.dependOn(&compile.step);

    const configure_step = b.step("configure", "Configure DPDK with meson using zig toolchain");
    configure_step.dependOn(&configure.step);

    const compile_step = b.step("compile", "Compile DPDK");
    compile_step.dependOn(&compile.step);

    const print_paths = b.addSystemCommand(&.{
        "sh",
        "-c",
        "printf 'DPDK staged under: %s%s\nheaders: %s%sinclude\nlibraries: %s%slib\n' \"$DESTDIR\" \"$PREFIX\" \"$DESTDIR\" \"$PREFIX/\" \"$DESTDIR\" \"$PREFIX/\"",
    });
    print_paths.setEnvironmentVariable("DESTDIR", destdir);
    print_paths.setEnvironmentVariable("PREFIX", prefix);
    print_paths.step.dependOn(&install.step);

    const install_step = b.step("install", "Install DPDK into DESTDIR/PREFIX");
    install_step.dependOn(&print_paths.step);

    b.getInstallStep().dependOn(&print_paths.step);

    const include_dir = stagedPath(b, destdir, prefix, "include");
    const lib_dir = stagedPath(b, destdir, prefix, "lib");
    const dpdk_options = b.addOptions();
    dpdk_options.addOption([]const u8, "include_dir", include_dir);
    dpdk_options.addOption([]const u8, "lib_dir", lib_dir);

    const dpdk_module = b.addModule("dpdk", .{ .root_source_file = b.path("zig/dpdk.zig") });
    dpdk_module.addOptions("dpdk_build_options", dpdk_options);

    b.default_step.dependOn(&print_paths.step);
}
