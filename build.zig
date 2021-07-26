const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("kisa", "src/main.zig");
    exe.addPackagePath("zzz", "zzz/src/main.zig");
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

    const main_test = b.addTest("src/main.zig");
    main_test.addPackagePath("zzz", "zzz/src/main.zig");
    main_test.setTarget(target);
    main_test.setBuildMode(mode);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&main_test.step);
}
