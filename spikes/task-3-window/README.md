# TASK-3 spike: GLFW 3.4 + OpenGL 3.3 core on headless Linux

> **This is throwaway spike code.** It exists only to answer one question for
> TASK-3: *do the mechanics of the `GLFW 3.4 + OpenGL 3.3 core` candidate actually
> work on this headless box?*
> Nothing in this directory may be copied, vendored, referenced or "absorbed" by
> the real project build (**TASK-4**). `build.zig`, `src/` and the vendored
> `c/glfw3.h` here are a self-contained scratch experiment; the real project has
> its own `src/`, root `build.zig`, and binding strategy from decision-2. This
> directory is retained as historical spike evidence.

---

## 1. What it proves

A single native executable, built by Zig 0.16.0, that on this **headless** machine:

1. initialises GLFW and creates a **real, visible** window (256x256) under Xvfb;
2. creates an **OpenGL 3.3 core profile** context on it;
3. loads every GL entrypoint through `glfwGetProcAddress`;
4. uploads a **procedurally generated 2x2 RGBA texture** (computed in code, no
   image asset) — one flat colour per texel: red / green / blue / white;
5. compiles and links a GLSL 3.30 vertex + fragment shader and draws a single
   **textured quad** (`GL_TRIANGLE_STRIP`, 4 vertices, interleaved pos+uv) via a
   VAO + VBO;
6. reads the default framebuffer back with **`glReadPixels`**;
7. writes the readback to a **binary PPM** (`readback.ppm`) and **asserts specific
   pixel values**, exiting non-zero on any mismatch.

What it deliberately does **not** prove: anything about performance, latency or
frame pacing. This box is software-rendered (`llvmpipe`) under Xvfb, so any
timing number taken here would be meaningless.

### Design of the verification

The quad is inset to ±0.9 of the viewport, so the framebuffer should contain
**exactly five colours**: the clear colour around the border, plus the four
texture quadrants. Any specific-pixel table is therefore a real check, not a
tautology:

* border pixels → clear colour `rgb(32,32,32)`
* screen bottom-left quadrant → texture texel (0,0) = red
* screen bottom-right quadrant → texture texel (1,0) = green
* screen top-left quadrant → texture texel (0,1) = blue
* screen top-right quadrant → texture texel (1,1) = white

---

## 2. Reproduce from a clean checkout

Prerequisites already installed on this box: Zig 0.16.0, `libglfw3-dev`,
Mesa, Xvfb, ImageMagick (only for the optional PNG preview).

```console
$ cd spikes/task-3-window
$ zig build
$ xvfb-run -a ./zig-out/bin/glfw-gl-quad
```

Equivalent one-liner (`run` depends on `install`):

```console
$ xvfb-run -a zig build run
```

`xvfb-run` is **required**. Running without a display fails, by design:

```console
$ env -u DISPLAY -u WAYLAND_DISPLAY ./zig-out/bin/glfw-gl-quad
GLFW error 65550: Failed to detect any supported platform
error: GlfwInitFailed
EXIT=1
```

### Observed output (verbatim, archived from the TASK-3 run)

```console
$ zig build && xvfb-run -a ./zig-out/bin/glfw-gl-quad
glfwInit(): ok
GLFW platform in use: X11
glfwCreateWindow(): ok, framebuffer 256x256
zopengl.loadCoreProfile(3, 3): ok
GL_VENDOR:   Mesa
GL_RENDERER: llvmpipe (LLVM 21.1.8, 256 bits)
GL_VERSION:  4.5 (Core Profile) Mesa 26.0.8-1ubuntu0.3
GLSL:        4.50
glfwSwapBuffers() + glfwPollEvents(): ok
wrote readback.ppm (256x256 RGB)

pixel verification (256x256 readback, coordinates x right / y up):
  (  1,  1)  got  32, 32, 32  want  32, 32, 32  OK  [clear border, bottom-left corner]
  (254,254)  got  32, 32, 32  want  32, 32, 32  OK  [clear border, top-right corner]
  ( 64, 64)  got 255,  0,  0  want 255,  0,  0  OK  [quad quadrant: texture (0,0)]
  (192, 64)  got   0,255,  0  want   0,255,  0  OK  [quad quadrant: texture (1,0)]
  ( 64,192)  got   0,  0,255  want   0,  0,255  OK  [quad quadrant: texture (0,1)]
  (192,192)  got 255,255,255  want 255,255,255  OK  [quad quadrant: texture (1,1)]
RESULT: PASS
```

Exit code `0`.

---

## 3. The readback file

`readback.ppm` — binary PPM (`P6`), 256x256, maxval 255, 196663 bytes
(55-byte header + 256*256*3 payload). Written to the process's working
directory. It is gitignored because it is generated output.

**Independent verification** (a Python script reading the file, *not* the
spike's own in-process check):

```console
$ convert readback.ppm readback.png   # optional visual preview
```

```console
$ python3 - <<'EOF'
d=open('readback.ppm','rb').read(); i=d.index(b'255\n')+4; px=d[i:]
w=h=256
def at(x,y):
    o=(y*w+x)*3; return tuple(px[o:o+3])
print("--- spatial check, PPM row 0 = TOP of image ---")
cases=[("screen top-left  quadrant",(64,64),(0,0,255)),
       ("screen top-right quadrant",(192,64),(255,255,255)),
       ("screen bottom-left quadrant",(64,192),(255,0,0)),
       ("screen bottom-right quadrant",(192,192),(0,255,0)),
       ("clear border corner",(0,0),(32,32,32)),
       ("clear border mid-right",(255,128),(32,32,32)),
       ("clear border mid-bottom",(128,255),(32,32,32))]
ok=True
for name,(x,y),exp in cases:
    got=at(x,y); m = got==exp; ok&=m
    print(f"  {name:26} ({x:3},{y:3}) = {got}  expect {exp}  {'OK' if m else 'MISMATCH'}")
print("ALL OK" if ok else "FAILED")
EOF
--- spatial check, PPM row 0 = TOP of image ---
  screen top-left  quadrant   ( 64, 64) = (0, 0, 255)  expect (0, 0, 255)  OK
  screen top-right quadrant  (192, 64) = (255, 255, 255)  expect (255, 255, 255)  OK
  screen bottom-left quadrant  (64,192) = (255, 0, 0)  expect (255, 0, 0)  OK
  screen bottom-right quadrant (192,192) = (0, 255, 0)  expect (0, 255, 0)  OK
  clear border corner          (  0,  0) = (32, 32, 32)  expect (32, 32, 32)  OK
  clear border mid-right      (255,128) = (32, 32, 32)  expect (32, 32, 32)  OK
  clear border mid-bottom     (128,255) = (32, 32, 32)  expect (32, 32, 32)  OK
ALL OK
```

A full-image histogram agrees exactly — **five** distinct colours, and the pixel
counts match the geometry to the pixel:

```console
distinct colours: 5; quad = 4 x 115x115 = 52900 px, border = 12636 px, total 65536
```

(quad spans 230x230 px, i.e. ±0.9 of a 256 px viewport, centred, so each quadrant
is 115x115 and the clear-colour border is 256*256 - 230*230 = 12636 px.)

The rendered image:

![readback](readback.png)

*(Regenerate locally with `convert readback.ppm readback.png`. The file is
gitignored, so it is not committed and this image only renders for someone who
has just run the spike.)*

---

## 4. Library versions and bindings used

| Thing | Version | Where it came from | How it is bound |
|---|---|---|---|
| Zig | **0.16.0** | `/opt/zig-x86_64-linux-0.16.0` | — |
| GLFW | **3.4.0** | system `libglfw3-dev` 3.4-4 (Ubuntu 26.04.1), `pkg-config --modversion glfw3` → `3.4.0` | **`zig translate-c`** on the vendored `c/glfw3.h`, generated at build time into `.zig-cache/o/…/glfw3.zig`; linked with `-lglfw` |
| OpenGL | context reports **4.5 (Core Profile)**, GLSL 4.50 | Mesa 26.0.8-1ubuntu0.3, `llvmpipe (LLVM 21.1.8, 256 bits)` | **zopengl 0.6.0-dev** (pure Zig), entrypoints resolved through `glfwGetProcAddress` |
| zopengl | `0.6.0-dev` | `zig fetch` from `https://github.com/zig-gamedev/zopengl/archive/refs/heads/master.tar.gz`, pinned hash `zopengl-0.6.0-dev-5-tnz8mnDgCHR72YtUpLBYW_u4JgZ0Ub-UFX-M0zRSG1` | Zig package dependency |
| Xvfb | **2:21.1.22-1ubuntu1.2** | `dpkg -s xvfb` | — |

Notes on the binding choices, since they are the interesting part of this spike:

* **`zig translate-c` is the GLFW binding used by this historical spike.** It
  deliberately translates the vendored `c/glfw3.h` so the experiment stays
  self-contained. A later audit corrected the original repository survey:
  `zig-gamedev/zglfw` does exist and builds on Zig 0.16; decision-2 records it as
  Conduit's GLFW fallback. That does not change what this prototype tested.
  `c/glfw3.h` is a verbatim copy of `/usr/include/GLFW/glfw3.h` (zlib licence,
  © Marcus Geelnard / Camilla Löwy). `translate-c` emits the macros as
  `GLFW_`-prefixed constants (e.g. `GLFW_CONTEXT_VERSION_MAJOR`) — note the
  prefix is *not* stripped.
* **zopengl is the OpenGL binding** and it works on 0.16 as-is: its own
  `build.zig.zon` declares `minimum_zig_version = "0.16.0"` and `zig build`
  inside it exits 0. It exposes `loadCoreProfile(loader, major, minor)`, where
  the loader is supplied by the caller — here a two-line adapter over
  `glfwGetProcAddress`.
* A GL function loader is therefore **not needed at all** for this path:
  `glfwGetProcAddress` + zopengl is sufficient. (Separately, `libGL.so.1`
  here is a GLVND dispatch library that exports the GL 3.3 core entrypoints
  directly, verified with `nm -D`, so a direct `-lGL` link would also have
  worked on Linux. GLFW + zopengl is the portable form.)

---

## 5. Honest notes on what did not work

Everything in the scope list eventually worked; nothing was papered over. These
are the real failures hit on the way, all of which are genuine portability traps
worth recording for TASK-4:

1. **The first binding survey checked the wrong repository names.** Requests for
   `zig-gamedev/glfw` and `mach-gamedev/glfw` returned 404, but the maintained
   package is `zig-gamedev/zglfw`. It exists and builds on Zig 0.16, and is the
   fallback recorded in decision-2. The spike still uses `zig translate-c`
   because direct header translation was its deliberately self-contained test
   path, not because a maintained GLFW Zig package is unavailable.
2. **First run: the readback was entirely the clear colour.** The first working
   build rendered nothing at all while `glGetError()` stayed `GL_NO_ERROR`.
   Root cause: `glVertexAttribPointer`'s final argument is a **byte offset into
   the buffer bound to `GL_ARRAY_BUFFER`**, not a host address. Passing the real
   address of the vertex array (which is also what an `@offsetOf`-style helper
   naturally produces) yields garbage attribute offsets and a completely
   clipped draw. Correct form is `attribOffset(0)` / `attribOffset(2 * @sizeOf(f32))`,
   i.e. tiny integers disguised as pointers. In Zig 0.16 the offset-0 case *must*
   be passed as `null` (`?*const anyopaque`), because non-optional null pointers
   are rejected: `error: pointer type '*const anyopaque' does not allow address zero`.
3. **A latent ordering bug, fixed, but not the cause of the symptom above.** An
   early version called `glfwSwapBuffers` *before* `glReadPixels`; after a swap
   the back buffer's contents are undefined, so the readback must happen
   **before** the swap. On this box a swapped-out back buffer did read back as
   an all-clear image. The reorder was made independently of item 2, and the
   all-clear symptom *persisted after it* — item 2 is the real cause. The code
   now does draw → read → write → swap.
4. `std.zig.allocator` **does not exist** in Zig 0.16 (it compiled fine in older
   versions), so the spike uses `init.arena` from the `std.process.Init`
   parameter. Related 0.16 notes: `main` takes `std.process.Init` (which carries
   `io`, `gpa`, `arena`), and `std.Build.Step.TranslateC.create(...).createModule()`
   replaced the old `b.addTranslateC` + `createModule` idiom.
5. `glGetShaderInfoLog` / `glGetProgramInfoLog` return **`void`** in zopengl's
   core-profile bindings (the out-parameter is non-optional `[*c]Sizei`), so the
   log length must be read back from that pointer rather than from a return value.

Unverified / out of scope, and stated as such:

* **No performance conclusion is drawn.** Everything here ran on `llvmpipe`
  software rasterisation under Xvfb. Statements about real-GPU behaviour are
  *not* supported by this spike.
* **macOS and Windows are untested.** Only the Linux/X11 path was exercised.
  GLFW 3.4 on those platforms is a different backend entirely.
* Dependency download from a genuinely cold Zig global cache was not exercised;
  the archived run only proves the pinned package after Zig resolved it.
* Wayland was **not** exercised: GLFW reported `X11`, because `xvfb-run` provides
  only an X display. Whether GLFW would pick the Wayland backend under a
  compositor (e.g. `weston`) on this box is untested here — that matters for
  TASK-3's windowing decision and is a reasonable follow-up spike.

---

## 6. Layout

```
spikes/task-3-window/
├── .gitignore          # .zig-cache/, zig-out/, zig-pkg/, generated readback
├── build.zig           # translate-c of c/glfw3.h + zopengl dep + -lglfw
├── build.zig.zon       # pins zopengl 0.6.0-dev
├── c/glfw3.h           # vendored copy of /usr/include/GLFW/glfw3.h (zlib)
├── src/main.zig        # window + GL context + textured quad + glReadPixels
├── readback.ppm        # generated and ignored; appears after a run
└── readback.png        # optional generated and ignored preview
```
