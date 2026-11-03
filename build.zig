const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const imgui_dir = b.path("third_party/imgui");
    const dcimgui_dir = b.path("third_party/dcimgui");

    // Headers C (SDL3 + bindings C do Dear ImGui) traduzidos para um módulo Zig.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(imgui_dir);
    translate.addIncludePath(dcimgui_dir);
    translate.addIncludePath(dcimgui_dir.path(b, "backends"));
    translate.defineCMacro("IMGUI_USE_WCHAR32", "1");
    translate.linkSystemLibrary("sdl3", .{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addImport("c", translate.createModule());

    mod.addIncludePath(imgui_dir);
    mod.addIncludePath(imgui_dir.path(b, "backends"));
    mod.addIncludePath(dcimgui_dir);
    mod.addIncludePath(dcimgui_dir.path(b, "backends"));
    mod.addCMacro("IMGUI_ENABLE_FREETYPE", "1");
    mod.addCMacro("IMGUI_USE_WCHAR32", "1"); // emojis fora do plano básico (😂, 🌸...)
    mod.addCSourceFiles(.{
        .root = b.path("third_party"),
        .files = &.{
            "imgui/imgui.cpp",
            "imgui/imgui_draw.cpp",
            "imgui/imgui_tables.cpp",
            "imgui/imgui_widgets.cpp",
            "imgui/imgui_demo.cpp",
            "imgui/misc/freetype/imgui_freetype.cpp",
            "imgui/backends/imgui_impl_sdl3.cpp",
            "imgui/backends/imgui_impl_sdlrenderer3.cpp",
            "dcimgui/dcimgui.cpp",
            "dcimgui/backends/dcimgui_impl_sdl3.cpp",
            "dcimgui/backends/dcimgui_impl_sdlrenderer3.cpp",
        },
        .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" },
    });
    mod.linkSystemLibrary("sdl3", .{});
    mod.linkSystemLibrary("freetype2", .{});

    const exe = b.addExecutable(.{ .name = "larpercord", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Roda o larperCord").dependOn(&run.step);
}
