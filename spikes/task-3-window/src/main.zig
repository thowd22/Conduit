//! Throwaway spike for Conduit M0 / TASK-3: prove that the leading windowing
//! candidate "GLFW 3.4 + OpenGL 3.3 core" mechanics work on this headless box.
//!
//! It opens a real GLFW window under Xvfb, creates a core-profile 3.3 context,
//! uploads a procedurally generated 2x2 RGBA texture, draws a textured quad,
//! reads the default framebuffer back with glReadPixels, writes a binary PPM,
//! and then checks specific pixels against what the texture must have produced.
//!
//! This is NOT Conduit code. See README.md.

const std = @import("std");
const glfw = @import("glfw");
const zopengl = @import("zopengl");
const gl = zopengl.bindings;

const fb_width = 256;
const fb_height = 256;
const out_path = "readback.ppm";

/// Clear colour, written before the quad so that a failed draw is visible.
const clear_rgb = [3]u8{ 32, 32, 32 };

/// A sample point in *readback* coordinates: x right, y up from the bottom
/// (glReadPixels returns the framebuffer bottom-up).
const Sample = struct {
    x: usize,
    y: usize,
    expected: [3]u8,
    label: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &fw.interface;

    _ = glfw.glfwSetErrorCallback(onGlfwError);

    // Note: glfwGetVersionString/glfwGetPlatform are only valid after init.

    if (glfw.glfwInit() == 0) {
        out.print("FAIL: glfwInit() returned 0 (no usable display)\n", .{}) catch {};
        return error.GlfwInitFailed;
    }
    defer glfw.glfwTerminate();
    out.print("glfwInit(): ok\n", .{}) catch {};
    out.print("GLFW platform in use: {s}\n", .{platformName(glfw.glfwGetPlatform())}) catch {};

    // A non-resizable *visible* window: we want the real swapchain path, and a
    // fixed framebuffer size so the readback is deterministic.
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 3);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_PROFILE, glfw.GLFW_OPENGL_CORE_PROFILE);
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_FORWARD_COMPAT, glfw.GLFW_TRUE);
    glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_FALSE);
    glfw.glfwWindowHint(glfw.GLFW_VISIBLE, glfw.GLFW_TRUE);

    const window = glfw.glfwCreateWindow(fb_width, fb_height, "conduit-task3-spike", null, null) orelse {
        out.print("FAIL: glfwCreateWindow() returned null\n", .{}) catch {};
        return error.WindowCreationFailed;
    };
    defer glfw.glfwDestroyWindow(window);

    var actual_w: c_int = 0;
    var actual_h: c_int = 0;
    glfw.glfwGetFramebufferSize(window, &actual_w, &actual_h);
    out.print("glfwCreateWindow(): ok, framebuffer {d}x{d}\n", .{ actual_w, actual_h }) catch {};
    if (actual_w != fb_width or actual_h != fb_height) {
        out.print("FAIL: framebuffer size is not {d}x{d}; readback would not be comparable\n", .{ fb_width, fb_height }) catch {};
        return error.UnexpectedFramebufferSize;
    }

    glfw.glfwMakeContextCurrent(window);
    glfw.glfwSwapInterval(1);

    // zopengl resolves every entrypoint through GLFW's loader.
    try zopengl.loadCoreProfile(&loadGlProc, 3, 3);
    out.print("zopengl.loadCoreProfile(3, 3): ok\n", .{}) catch {};

    out.print("GL_VENDOR:   {s}\n", .{cstr(gl.getString(gl.VENDOR))}) catch {};
    out.print("GL_RENDERER: {s}\n", .{cstr(gl.getString(gl.RENDERER))}) catch {};
    out.print("GL_VERSION:  {s}\n", .{cstr(gl.getString(gl.VERSION))}) catch {};
    out.print("GLSL:        {s}\n", .{cstr(gl.getString(gl.SHADING_LANGUAGE_VERSION))}) catch {};

    try drawTexturedQuad();

    // Read the default framebuffer back *before* swapping: after a swap the
    // back buffer's contents are undefined.
    var pixels: [fb_width * fb_height * 4]u8 = undefined;
    gl.finish();
    gl.readPixels(0, 0, fb_width, fb_height, gl.RGBA, gl.UNSIGNED_BYTE, &pixels);
    try checkGlError("readPixels");

    glfw.glfwSwapBuffers(window);
    glfw.glfwPollEvents();
    out.print("glfwSwapBuffers() + glfwPollEvents(): ok\n", .{}) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = out_path,
        .data = try toPpm(init.arena.allocator(), &pixels),
    });
    out.print("wrote {s} ({d}x{d} RGB)\n", .{ out_path, fb_width, fb_height }) catch {};

    const ok = try verify(&pixels, out);

    out.flush() catch {};

    if (!ok) return error.PixelVerificationFailed;
    out.print("RESULT: PASS\n", .{}) catch {};
    out.flush() catch {};
}

/// The whole render: 2x2 procedural texture + a single textured quad.
fn drawTexturedQuad() !void {
    gl.viewport(0, 0, fb_width, fb_height);
    const clear_colour = [4]f32{
        @as(f32, @floatFromInt(clear_rgb[0])) / 255.0,
        @as(f32, @floatFromInt(clear_rgb[1])) / 255.0,
        @as(f32, @floatFromInt(clear_rgb[2])) / 255.0,
        1.0,
    };
    gl.clearBufferfv(gl.COLOR, 0, &clear_colour);
    try checkGlError("clearBufferfv");

    // Procedural 2x2 RGBA texture: one flat colour per texel, so the readback
    // can be checked exactly. No image asset is loaded.
    const texels = [_][4]u8{
        texelFor(0, 0), // uv (0,0) -> bottom-left of the quad
        texelFor(1, 0), // uv (1,0) -> bottom-right
        texelFor(0, 1), // uv (0,1) -> top-left
        texelFor(1, 1), // uv (1,1) -> top-right
    };
    var tex_bytes: [16]u8 = undefined;
    for (texels, 0..) |t, i| std.mem.copyForwards(u8, tex_bytes[i * 4 ..][0..4], &t);

    var texture: gl.Uint = 0;
    gl.genTextures(1, &texture);
    try checkGlError("genTextures");
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 2, 2, 0, gl.RGBA, gl.UNSIGNED_BYTE, &tex_bytes);
    try checkGlError("texImage2D");
    // GL_NEAREST keeps every quad pixel identical to its texel.
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    try checkGlError("texParameteri");

    const program = try buildProgram();
    defer gl.deleteProgram(program);
    gl.useProgram(program);
    const tex_loc = gl.getUniformLocation(program, "u_tex");
    if (tex_loc < 0) return error.UniformNotFound;
    gl.uniform1i(tex_loc, 0);

    // Interleaved (x, y, u, v), drawn as one GL_TRIANGLE_STRIP. The quad is
    // inset to 90% of the viewport so a clear-colour border proves that what we
    // read back really came from the draw call.
    const quad = [_]f32{
        -0.9, -0.9, 0.0, 0.0,
        0.9,  -0.9, 1.0, 0.0,
        -0.9, 0.9,  0.0, 1.0,
        0.9,  0.9,  1.0, 1.0,
    };

    var vao: gl.Uint = 0;
    gl.genVertexArrays(1, &vao);
    gl.bindVertexArray(vao);
    try checkGlError("genVertexArrays");

    var vbo: gl.Uint = 0;
    gl.genBuffers(1, &vbo);
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.bufferData(gl.ARRAY_BUFFER, quad.len * @sizeOf(f32), &quad, gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, 4 * @sizeOf(f32), attribOffset(0));
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, 4 * @sizeOf(f32), attribOffset(2 * @sizeOf(f32)));
    try checkGlError("vertexAttribPointer");

    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    try checkGlError("drawArrays");

    gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    gl.bindVertexArray(0);
    gl.deleteBuffers(1, &vbo);
    gl.deleteVertexArrays(1, &vao);
    gl.deleteTextures(1, &texture);
}

fn texelFor(x: u32, y: u32) [4]u8 {
    const palette = [_][4]u8{
        .{ 255, 0, 0, 255 }, // red
        .{ 0, 255, 0, 255 }, // green
        .{ 0, 0, 255, 255 }, // blue
        .{ 255, 255, 255, 255 }, // white
    };
    return palette[y * 2 + x];
}

/// `glVertexAttribPointer`'s last argument is a *byte offset into the buffer
/// currently bound to GL_ARRAY_BUFFER*, not a host address. Clients normally
/// pass small integers such as `(void *)8`.
fn attribOffset(comptime offset_bytes: usize) ?*const anyopaque {
    // Zig 0.16 forbids non-optional null pointers; null is the canonical
    // encoding of offset 0 for this parameter.
    return if (offset_bytes == 0) null else @ptrFromInt(offset_bytes);
}

fn buildProgram() !gl.Uint {
    const vs_src: [:0]const u8 =
        \\#version 330 core
        \\layout(location = 0) in vec2 a_pos;
        \\layout(location = 1) in vec2 a_uv;
        \\out vec2 v_uv;
        \\void main() {
        \\    v_uv = a_uv;
        \\    gl_Position = vec4(a_pos, 0.0, 1.0);
        \\}
    ;
    const fs_src: [:0]const u8 =
        \\#version 330 core
        \\in vec2 v_uv;
        \\uniform sampler2D u_tex;
        \\out vec4 o_colour;
        \\void main() {
        \\    o_colour = texture(u_tex, v_uv);
        \\}
    ;

    const vs = try compileShader(gl.VERTEX_SHADER, vs_src);
    defer gl.deleteShader(vs);
    const fs = try compileShader(gl.FRAGMENT_SHADER, fs_src);
    defer gl.deleteShader(fs);

    const program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);

    var status: gl.Int = 0;
    gl.getProgramiv(program, gl.LINK_STATUS, &status);
    if (status == 0) {
        var log: [1024]u8 = undefined;
        var log_len: gl.Sizei = 0;
        gl.getProgramInfoLog(program, log.len, &log_len, &log);
        std.debug.print("program link failed: {s}\n", .{log[0..@intCast(@max(log_len, 0))]});
        return error.ShaderLinkFailed;
    }
    return program;
}

fn compileShader(kind: gl.Enum, source: [:0]const u8) !gl.Uint {
    const shader = gl.createShader(kind);
    gl.shaderSource(shader, 1, &source.ptr, null);

    gl.compileShader(shader);
    var status: gl.Int = 0;
    gl.getShaderiv(shader, gl.COMPILE_STATUS, &status);
    if (status == 0) {
        var log: [1024]u8 = undefined;
        var log_len: gl.Sizei = 0;
        gl.getShaderInfoLog(shader, log.len, &log_len, &log);
        std.debug.print("shader compile failed: {s}\n", .{log[0..@intCast(@max(log_len, 0))]});
        return error.ShaderCompileFailed;
    }
    return shader;
}

/// Convert the RGBA8 readback to a binary (P6) PPM, top-down.
fn toPpm(gpa: std.mem.Allocator, pixels: *const [fb_width * fb_height * 4]u8) ![]u8 {
    const header = try std.fmt.allocPrint(
        gpa,
        "P6\n# Conduit TASK-3 GLFW+GL spike readback\n{d} {d}\n255\n",
        .{ fb_width, fb_height },
    );
    const rgb = try gpa.alloc(u8, fb_width * fb_height * 3);
    for (0..fb_width * fb_height) |i| {
        // Flip: readback row 0 is the bottom of the image, PPM row 0 is the top.
        const src = (fb_height - 1 - i / fb_width) * fb_width + (i % fb_width);
        rgb[i * 3 + 0] = pixels[src * 4 + 0];
        rgb[i * 3 + 1] = pixels[src * 4 + 1];
        rgb[i * 3 + 2] = pixels[src * 4 + 2];
    }

    const out = try gpa.alloc(u8, header.len + rgb.len);
    @memcpy(out[0..header.len], header);
    @memcpy(out[header.len..], rgb);
    return out;
}

/// Check specific pixels against the colours the texture must have produced.
fn verify(pixels: *const [fb_width * fb_height * 4]u8, out: *std.Io.Writer) !bool {
    const samples = [_]Sample{
        .{ .x = 1, .y = 1, .expected = clear_rgb, .label = "clear border, bottom-left corner" },
        .{ .x = fb_width - 2, .y = fb_height - 2, .expected = clear_rgb, .label = "clear border, top-right corner" },
        .{ .x = fb_width / 4, .y = fb_height / 4, .expected = texelFor(0, 0)[0..3].*, .label = "quad quadrant: texture (0,0)" },
        .{ .x = fb_width * 3 / 4, .y = fb_height / 4, .expected = texelFor(1, 0)[0..3].*, .label = "quad quadrant: texture (1,0)" },
        .{ .x = fb_width / 4, .y = fb_height * 3 / 4, .expected = texelFor(0, 1)[0..3].*, .label = "quad quadrant: texture (0,1)" },
        .{ .x = fb_width * 3 / 4, .y = fb_height * 3 / 4, .expected = texelFor(1, 1)[0..3].*, .label = "quad quadrant: texture (1,1)" },
    };

    out.print("\npixel verification ({d}x{d} readback, coordinates x right / y up):\n", .{ fb_width, fb_height }) catch {};
    var all_ok = true;
    for (samples) |s| {
        const i = (s.y * fb_width + s.x) * 4;
        const got = [3]u8{ pixels[i], pixels[i + 1], pixels[i + 2] };
        const ok = std.meta.eql(got, s.expected);
        all_ok = all_ok and ok;
        out.print(
            "  ({d:>3},{d:>3})  got {d:>3},{d:>3},{d:>3}  want {d:>3},{d:>3},{d:>3}  {s}  [{s}]\n",
            .{ s.x, s.y, got[0], got[1], got[2], s.expected[0], s.expected[1], s.expected[2], if (ok) "OK" else "MISMATCH", s.label },
        ) catch {};
    }
    return all_ok;
}

fn checkGlError(stage: []const u8) !void {
    const err = gl.getError();
    if (err != gl.NO_ERROR) {
        std.debug.print("glGetError() after {s}: 0x{X}\n", .{ stage, err });
        return error.GlError;
    }
}

/// Adapts GLFW's loader to the signature zopengl wants.
fn loadGlProc(proc: [*:0]const u8) callconv(.c) ?*const anyopaque {
    const p = glfw.glfwGetProcAddress(proc) orelse return null;
    return @ptrCast(p);
}

fn onGlfwError(code: c_int, description: [*c]const u8) callconv(.c) void {
    std.debug.print("GLFW error {d}: {s}\n", .{ code, std.mem.span(description) });
}

fn cstr(p: [*c]const u8) []const u8 {
    return std.mem.span(p);
}

fn platformName(p: c_int) []const u8 {
    return switch (p) {
        glfw.GLFW_PLATFORM_X11 => "X11",
        glfw.GLFW_PLATFORM_WAYLAND => "Wayland",
        glfw.GLFW_PLATFORM_COCOA => "Cocoa",
        glfw.GLFW_PLATFORM_WIN32 => "Win32",
        glfw.GLFW_PLATFORM_NULL => "null",
        else => "unknown",
    };
}
