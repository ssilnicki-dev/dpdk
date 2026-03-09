const std = @import("std");

pub fn build(b: *std.Build) void {
    const prefix = b.option([]const u8, "prefix", "Install prefix");
    if (prefix) |p| buildExt(b, p) else buildInt(b);
}

fn buildInt(b: *std.Build) void {
    _ = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_dir = b.option([]const u8, "build_dir", "Meson build directory") orelse b.pathFromRoot("build-zig");
    const meson = b.option([]const u8, "meson", "Path to the meson executable") orelse "meson";
    const ninja = b.option([]const u8, "ninja", "Path to the ninja executable") orelse "ninja";
    const source_dir = b.pathFromRoot(".");
    const reconfigure = b.option(bool, "reconfigure", "Pass --reconfigure to meson setup") orelse false;
    const default_library = b.option([]const u8, "default_library", "Meson default_library (static/shared/both)") orelse "static";
    const enable_kmods = b.option(bool, "enable_kmods", "Enable compilation of kernel modules") orelse true;
    const install_usertools = b.option(bool, "install_usertools", "Install usertools") orelse true;
    const install_examples = b.option(bool, "install_examples", "Install examples") orelse true;
    const install_buildtools = b.option(bool, "install_buildtools", "Install buildtools") orelse true;
    const build_tests = b.option(bool, "build_tests", "Build tests") orelse true;
    const disable_apps = b.option([]const u8, "disable_apps", "List of disabled apps") orelse "";
    const enable_drivers = b.option([]const u8, "enable_drivers", "List of enabled drivers") orelse "";

    const buildtype = switch (optimize) {
        .Debug => "debug",
        .ReleaseSafe => "debugoptimized",
        .ReleaseFast => "release",
        .ReleaseSmall => "minsize",
    };

    var env = b.graph.environ_map.clone(b.allocator) catch @panic("OOM");
    defer env.deinit();
    env.put("NINJA", ninja) catch @panic("OOM");
    env.put("CC", "zig cc") catch @panic("OOM");
    env.put("CXX", "zig c++") catch @panic("OOM");
    env.put("CFLAGS", "-fno-sanitize=undefined") catch @panic("OOM");
    env.put("CXXFLAGS", "-fno-sanitize=undefined") catch @panic("OOM");
    env.put("AR", "zig ar") catch @panic("OOM");
    env.put("RANLIB", "zig ranlib") catch @panic("OOM");

    var meson_setup_proc_args: std.ArrayList([]const u8) = .empty;
    defer meson_setup_proc_args.deinit(b.allocator);
    meson_setup_proc_args.appendSlice(b.allocator, &.{
        meson,
        "setup",
        build_dir,
        source_dir,
        "--backend",
        "ninja",
        "--buildtype",
        buildtype,
        "--default-library",
        default_library,
        std.fmt.allocPrint(b.allocator, "-Denable_kmods={any}", .{enable_kmods}) catch @panic("OOM"),
        std.fmt.allocPrint(b.allocator, "-Dtests={any}", .{build_tests}) catch @panic("OOM"),
        std.fmt.allocPrint(b.allocator, "-Dinstall_buildtools={any}", .{install_buildtools}) catch @panic("OOM"),
        std.fmt.allocPrint(b.allocator, "-Dinstall_examples={any}", .{install_examples}) catch @panic("OOM"),
        std.fmt.allocPrint(b.allocator, "-Dinstall_usertools={any}", .{install_usertools}) catch @panic("OOM"),
        std.fmt.allocPrint(b.allocator, "-Denable_drivers={s}", .{enable_drivers}) catch @panic("OOM"),
    }) catch @panic("OOM");

    if (disable_apps.len > 0) meson_setup_proc_args.append(b.allocator, std.fmt.allocPrint(b.allocator, "-Ddisable_apps={s}", .{disable_apps}) catch @panic("OOM")) catch @panic("OOM");
    if (reconfigure) meson_setup_proc_args.append(b.allocator, "--reconfigure") catch @panic("OOM");

    var setup_child_process = std.process.spawn(b.graph.io, .{
        .argv = meson_setup_proc_args.items,
        .environ_map = &env,
    }) catch @panic("failed to spwan meson setup");

    const res = setup_child_process.wait(b.graph.io) catch @panic("failed to wait meson setup process");
    switch (res) {
        .exited => |code| {
            if (code != 0) @panic("meson setup exited with non-zero code");
        },
        else => @panic("meson setup run failed"),
    }

    const plan_path = b.pathJoin(&.{
        build_dir,
        "meson-info",
        "intro-install_plan.json",
    });

    const plan_file = std.Io.Dir.openFileAbsolute(b.graph.io, plan_path, .{}) catch @panic("falied open plan json");
    defer plan_file.close(b.graph.io);
    const plan_stat = plan_file.stat(b.graph.io) catch @panic("failed stat plan json");
    const plan_data = b.allocator.alloc(u8, @intCast(plan_stat.size)) catch @panic("OOM");
    defer b.allocator.free(plan_data);
    if (plan_file.readPositionalAll(b.graph.io, plan_data, 0) catch @panic("failed read plan json") != plan_stat.size) @panic("incomplete read plan json");
    var parsed = std.json.parseFromSlice(std.json.Value, b.allocator, plan_data, .{}) catch @panic("failed to parse plan json");
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) @panic("unexpected Meson install_plan JSON");

    const compile = b.addSystemCommand(&.{
        meson,
        "compile",
        "-C",
        build_dir,
    });
    const compile_step = b.step("compile", "Compile DPDK");
    compile_step.dependOn(&compile.step);
    b.default_step.dependOn(&compile.step);

    for (&[_][]const u8{ "headers", "configure" }) |headers_section| {
        if (root.object.get(headers_section)) |headers_val| {
            if (headers_val == .object) {
                var it = headers_val.object.iterator();
                while (it.next()) |entry| {
                    const src = entry.key_ptr.*;
                    if (entry.value_ptr.* == .object) {
                        if (entry.value_ptr.object.get("destination")) |d| {
                            switch (d) {
                                .string => |dst_path| {
                                    if (std.mem.startsWith(u8, dst_path, "{includedir}/")) {
                                        const hdr = b.addInstallHeaderFile(.{ .cwd_relative = src }, dst_path["{includedir}/".len..]);
                                        hdr.step.dependOn(&compile.step);
                                        b.getInstallStep().dependOn(&hdr.step);
                                    } else {
                                        @panic("unexpected json format");
                                    }
                                },
                                else => @panic("unexpected json format"),
                            }
                        } else {
                            @panic("unexpected json format");
                        }
                    } else {
                        @panic("unexpected json format");
                    }
                }
            }
        }
    }

    if (root.object.get("targets")) |targets_val| {
        if (targets_val == .object) {
            var it = targets_val.object.iterator();
            while (it.next()) |entry| {
                const src = entry.key_ptr.*;
                if (entry.value_ptr.* == .object) {
                    if (entry.value_ptr.object.get("destination")) |d| {
                        switch (d) {
                            .string => |dst_path| {
                                const dst = blk: {
                                    if (std.mem.startsWith(u8, dst_path, "{libdir}/")) break :blk dst_path["{libdir}/".len..];
                                    if (std.mem.startsWith(u8, dst_path, "{libdir_static}/")) break :blk dst_path["{libdir_static}/".len..];
                                    if (std.mem.startsWith(u8, dst_path, "{libdir_shared}/")) break :blk dst_path["{libdir_shared}/".len..];
                                    @panic("unexpected json format");
                                };
                                const lib = b.addInstallLibFile(.{ .cwd_relative = src }, dst);
                                lib.step.dependOn(&compile.step);
                                b.getInstallStep().dependOn(&lib.step);
                            },
                            else => @panic("unexpected json format"),
                        }
                    } else {
                        @panic("unexpected json format");
                    }
                } else {
                    @panic("unexpected json format");
                }
            }
        }
    }
}

fn buildExt(b: *std.Build, prefix: []const u8) void {
    _ = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const meson = b.option([]const u8, "meson", "Path to the meson executable") orelse "meson";
    const ninja = b.option([]const u8, "ninja", "Path to the ninja executable") orelse "ninja";
    const build_dir = b.option([]const u8, "build_dir", "Meson build directory") orelse b.pathFromRoot("build-zig");
    const source_dir = b.pathFromRoot(".");
    const reconfigure = b.option(bool, "reconfigure", "Pass --reconfigure to meson setup") orelse false;
    const default_library = b.option([]const u8, "default_library", "Meson default_library (static/shared/both)") orelse "static";
    const enable_kmods = b.option(bool, "enable_kmods", "Enable compilation of kernel modules") orelse true;
    const install_usertools = b.option(bool, "install_usertools", "Install usertools") orelse true;
    const install_examples = b.option(bool, "install_examples", "Install examples") orelse true;
    const install_buildtools = b.option(bool, "install_buildtools", "Install buildtools") orelse true;
    const build_tests = b.option(bool, "build_tests", "Build tests") orelse true;
    const disable_apps = b.option([]const u8, "disable_apps", "List of disabled apps") orelse "";
    const enable_drivers = b.option([]const u8, "enable_drivers", "List of enabled drivers") orelse "";

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
        std.fmt.allocPrint(b.allocator, "-Denable_kmods={any}", .{enable_kmods}) catch @panic("OOM"),
        std.fmt.allocPrint(b.allocator, "-Dtests={any}", .{build_tests}) catch @panic("OOM"),
        std.fmt.allocPrint(b.allocator, "-Dinstall_buildtools={any}", .{install_buildtools}) catch @panic("OOM"),
        std.fmt.allocPrint(b.allocator, "-Dinstall_examples={any}", .{install_examples}) catch @panic("OOM"),
        std.fmt.allocPrint(b.allocator, "-Dinstall_usertools={any}", .{install_usertools}) catch @panic("OOM"),
        std.fmt.allocPrint(b.allocator, "-Denable_drivers={s}", .{enable_drivers}) catch @panic("OOM"),
    });
    if (disable_apps.len > 0) configure.addArg(std.fmt.allocPrint(b.allocator, "-Ddisable_apps={s}", .{disable_apps}) catch @panic("OOM"));
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
        "--only-changed",
        "-q",
    });
    install.step.dependOn(&compile.step);

    const configure_step = b.step("configure", "Configure DPDK with meson using zig toolchain");
    configure_step.dependOn(&configure.step);

    const compile_step = b.step("compile", "Compile DPDK");
    compile_step.dependOn(&compile.step);

    b.default_step.dependOn(&install.step);
}
