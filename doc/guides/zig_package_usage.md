# Using DPDK as a Zig package dependency

This repository ships a `build.zig` + `build.zig.zon` pair so another Zig
project can import DPDK as a dependency and stage generated headers/libraries
into that project's artifact directory.

## Producer side (this repository)

The DPDK Zig build script supports these options:

- `-Dbuild-dir=<dir>`: Meson build directory.
- `-Ddefault-library=<static|shared|both>`: type of DPDK libraries to build.
- `-Dprefix=<path>`: install prefix *inside* the staging directory (defaults to `/`).
- `-Ddestdir=<path>`: staging directory used as Meson `DESTDIR`
  (defaults to Zig's install prefix for the current build invocation).

`zig build install` runs `meson install` and stages artifacts in:

- headers: `<destdir>/<prefix>/include`
- libraries: `<destdir>/<prefix>/lib`

The build script forces Meson `--includedir=include` and `--libdir=lib` so
consumer projects can use stable paths across distributions.

## Consumer side (another Zig project)

In your consumer project's `build.zig.zon`:

```zig
.dependencies = .{
    .dpdk = .{ .path = "../dpdk" },
},
```

In your consumer project's `build.zig`:


The dependency must be used by your build graph; simply calling
`b.dependency(...)` and discarding the result may not trigger its build steps.
The snippet below imports DPDK's exported Zig module to force dependency
execution in a version-friendly way.
The object returned by `b.dependency(...)` is a `Build.Dependency`; use
`dep.module("dpdk")` when a `*Build.Module` is required (e.g. `addImport`).

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dpdk_dep = b.dependency("dpdk", .{
        .optimize = optimize,
        .target = target,
        .default_library = "static",
        // Stage dependency output under this project's zig-out tree:
        .destdir = b.install_prefix,
        .prefix = "/dpdk",
    });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });


    // Force dependency execution by importing the module exported by DPDK's
    // build script. The module also exposes `include_dir` and `lib_dir`
    // constants for use in source code if needed.
    exe.root_module.addImport("dpdk", dpdk_dep.module("dpdk"));

    // Include/link against staged DPDK artifacts.
    exe.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ b.install_prefix, "dpdk/include" }) });
    exe.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ b.install_prefix, "dpdk/lib" }) });

    // Link the DPDK libs your app needs.
    exe.linkSystemLibrary("rte_eal");
    exe.linkSystemLibrary("rte_mbuf");

    b.installArtifact(exe);
}
```

With this setup, DPDK artifacts are staged under your consumer project's
`zig-out/dpdk`, and your application can include DPDK headers and link the
installed libraries.
