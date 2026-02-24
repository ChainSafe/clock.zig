const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zig_beacon_clock", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "zig_beacon_clock",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Example executable
    const example = b.addExecutable(.{
        .name = "clock_basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/clock_basic.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zig_beacon_clock", .module = mod }},
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    const run_step = b.step("run-example", "Run the clock_basic example");
    run_step.dependOn(&run_example.step);

    const test_step = b.step("test", "Run zig-beacon-clock tests");

    // Full test suite via lib.zig (runs inline tests from all layers)
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    // Layer-0 standalone tests (pure functions, no libc)
    const slot_math_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/slot_math.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_slot_math_tests = b.addRunArtifact(slot_math_tests);
    test_step.dependOn(&run_slot_math_tests.step);
}
