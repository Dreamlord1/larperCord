const std = @import("std");

/// Temas embutidos (usados também pelo passo `snapshots`).
const theme_names = [_][]const u8{ "classico", "vidro", "terminal", "bolhas", "zen", "papel", "escritorio" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Padrão: ReleaseFast (o de debug desenha cada quadro ~4x mais devagar).
    // O QA usa -Doptimize=debug, com as checagens de segurança.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "debug, safe, fast ou small (padrão: fast)") orelse .fast;
    const strip = b.option(bool, "strip", "Remove símbolos de debug do executável") orelse (optimize != .debug);

    const imgui_dir = b.path("third_party/imgui");
    const dcimgui_dir = b.path("third_party/dcimgui");

    const builtin_themes = b.createModule(.{ .root_source_file = b.path("themes/builtin.zig") });

    // Headers C (SDL3, Dear ImGui, fontconfig, libc) traduzidos num módulo Zig.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(imgui_dir);
    translate.addIncludePath(dcimgui_dir);
    translate.addIncludePath(dcimgui_dir.path(b, "backends"));
    translate.addIncludePath(b.path("third_party/stb"));
    translate.defineCMacro("IMGUI_USE_WCHAR32", "1");
    translate.linkSystemLibrary("sdl3", .{});
    translate.linkSystemLibrary("fontconfig", .{});
    translate.linkSystemLibrary("libcurl", .{});
    translate.linkSystemLibrary("zlib", .{});
    translate.linkSystemLibrary("libwebp", .{});
    translate.linkSystemLibrary("libwebpdemux", .{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = strip,
    });
    mod.addImport("c", translate.createModule());
    mod.addImport("builtin_themes", builtin_themes);

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
    // Decodificador de imagens (PNG/JPEG/GIF) dos anexos; WebP vem da libwebp.
    mod.addIncludePath(b.path("third_party/stb"));
    mod.addCSourceFile(.{ .file = b.path("third_party/stb/stb_image.c"), .flags = &.{"-O2"} });
    mod.linkSystemLibrary("sdl3", .{});
    mod.linkSystemLibrary("freetype2", .{});
    mod.linkSystemLibrary("fontconfig", .{});
    mod.linkSystemLibrary("libcurl", .{});
    mod.linkSystemLibrary("zlib", .{});
    mod.linkSystemLibrary("libwebp", .{});
    mod.linkSystemLibrary("libwebpdemux", .{});

    const exe = b.addExecutable(.{ .name = "larpercord", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Roda o larperCord").dependOn(&run.step);

    // Testes das partes puras (sem janela nem GPU): rodam em qualquer CI.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("builtin_themes", builtin_themes);
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Roda os testes").dependOn(&b.addRunArtifact(tests).step);

    // Um print de cada tema em docs/themes/ (usado no README).
    const snaps = b.step("snapshots", "Gera docs/themes/<tema>.png para cada tema embutido");
    for (theme_names) |name| {
        const shot = b.addRunArtifact(exe);
        shot.addArgs(&.{ "--theme", name, "--shot" });
        shot.addArg(b.fmt("docs/themes/{s}.png", .{name}));
        shot.setEnvironmentVariable("SDL_VIDEO_DRIVER", "offscreen"); // não abre janela
        shot.has_side_effects = true;
        snaps.dependOn(&shot.step);
    }
}
