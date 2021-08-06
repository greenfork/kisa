const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("kisa", "src/main.zig");
    exe.addPackagePath("zzz", "zzz/src/main.zig");
    exe.addPackagePath("known-folders", "known-folders/known-folders.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    const test_main = b.step("test-main", "Run tests in main");
    const test_main_nofork = b.step("test-main-nofork", "Run tests in main without forking");
    const test_state = b.step("test-state", "Run tests in state");
    const test_config = b.step("test-config", "Run tests in config");
    const test_jsonrpc = b.step("test-jsonrpc", "Run tests in jsonrpc");
    const test_transport = b.step("test-transport", "Run tests in transport");

    {
        var test_cases = b.addTest("src/main.zig");
        test_cases.setFilter("main:");
        test_cases.addPackagePath("zzz", "zzz/src/main.zig");
        test_cases.addPackagePath("known-folders", "known-folders/known-folders.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_step.dependOn(&test_cases.step);
        test_main.dependOn(&test_cases.step);
        test_main_nofork.dependOn(&test_cases.step);
    }

    {
        // Forked tests must be run 1 at a time, otherwise they interfere with other tests.
        var test_cases = b.addTest("src/main.zig");
        test_cases.setFilter("fork/socket:");
        test_cases.addPackagePath("zzz", "zzz/src/main.zig");
        test_cases.addPackagePath("known-folders", "known-folders/known-folders.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_step.dependOn(&test_cases.step);
        test_main.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/state.zig");
        test_cases.setFilter("state:");
        test_cases.addPackagePath("zzz", "zzz/src/main.zig");
        test_cases.addPackagePath("known-folders", "known-folders/known-folders.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_step.dependOn(&test_cases.step);
        test_state.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/config.zig");
        test_cases.setFilter("config:");
        test_cases.addPackagePath("zzz", "zzz/src/main.zig");
        test_cases.addPackagePath("known-folders", "known-folders/known-folders.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_step.dependOn(&test_cases.step);
        test_config.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/jsonrpc.zig");
        test_cases.setFilter("jsonrpc:");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_step.dependOn(&test_cases.step);
        test_jsonrpc.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/transport.zig");
        test_cases.setFilter("transport/fork1:");
        test_cases.addPackagePath("known-folders", "known-folders/known-folders.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_step.dependOn(&test_cases.step);
        test_transport.dependOn(&test_cases.step);
    }

    {
        const test_cases = b.addTest("src/transport.zig");
        test_cases.setFilter("transport/fork2:");
        test_cases.addPackagePath("known-folders", "known-folders/known-folders.zig");
        test_cases.setTarget(target);
        test_cases.setBuildMode(mode);
        test_step.dependOn(&test_cases.step);
        test_transport.dependOn(&test_cases.step);
    }
}
