# Zig package integration notes

When this repository is used as a Zig dependency, importing only the module
(`dep.module("dpdk")`) does **not** automatically execute the dependency's
`default_step`.

In this package, the DPDK C libraries are built by the dependency's
`default_step` (`meson setup` + `meson compile`), so you must explicitly make
your main project's build graph depend on that step.

## Force DPDK build when building your top-level project

In the top-level `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_dpdk = b.dependency("dpdk", .{
        .target = target,
        .optimize = optimize,
    });

    // Importing the module alone does not build DPDK C libs.
    const dpdk_mod = dep_dpdk.module("dpdk");

    const exe = b.addExecutable(.{
        .name = "app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("dpdk", dpdk_mod);

    // Force running dependency default step (meson/ninja build in this repo).
    exe.step.dependOn(&dep_dpdk.builder.default_step);

    b.installArtifact(exe);
}
```

You can also attach the dependency to a higher-level step instead:

```zig
b.getInstallStep().dependOn(&dep_dpdk.builder.default_step);
```

That ensures `zig build` (or `zig build install`) runs DPDK's build steps before
(or along with) the main project build.
