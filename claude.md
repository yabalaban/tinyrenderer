# TinyRenderer

A software 3D rasterizer written in Nim, compiled to JavaScript. Renders textured 3D models in the browser using a 2D canvas—no WebGL.

## Stack

- **Nim** → JavaScript (via `nim js`)
- **HTML5 Canvas 2D** for pixel-level rendering
- **Pure software rasterization** (scanline triangle filling)

## Project Structure

```
tinyrenderer/
├── docs/                    # Web demo (GitHub Pages ready)
│   ├── index.html          # Demo page with controls
│   ├── renderer.js         # Compiled output (do not edit)
│   └── models/
│       ├── diablo3_pose.obj
│       └── diablo3_pose_diffuse.png
├── nim/src/web/
│   ├── renderer.nim        # Main renderer (~580 lines)
│   ├── vec3.nim            # 3D vector math
│   └── config.nims         # Nim JS backend config
└── LICENSE
```

## Build

```bash
cd nim/src/web
nim js -d:release -o:../../../docs/renderer.js renderer.nim
```

## Architecture

### Rendering Pipeline

```
Model Space → Rotate (Y then X) → Project → Screen Space
           → Backface Cull → Frustum Cull → Depth Sort → Rasterize
```

### Code Organization (renderer.nim)

The file is organized into labeled sections:

1. **Types** - `Face`, `Texture`, `Model`, `Renderer`
2. **Globals & Constants** - renderer instance, ASCII charset, light direction
3. **JS Interop** - `fetch`, `text` bindings
4. **Pixel Buffer Operations** - `clear()`
5. **Triangle Rasterization** - `drawTexturedTriangle()` scanline algorithm
6. **3D Projection & Culling** - perspective projection, frustum/backface culling
7. **Model Rendering** - `drawModel()` with 3-pass pipeline
8. **Render Modes** - Normal pixel rendering vs ASCII art mode
9. **Asset Loading** - OBJ parser, texture loader via Image API
10. **Input Handling** - Mouse/touch drag for rotation
11. **Initialization & Main Loop** - Entry point, animation loop

### Key Patterns

**Nim → JS Interop**

Use `{.emit: [...].}` for inline JavaScript. Variables are interpolated:

```nim
# Correct - JS string concatenation for dynamic values
{.emit: [ctx, ".fillStyle='rgb('+", r, "+','+", g, "+','+", b, "+')';"].}

# Wrong - variable names become literals inside string
{.emit: [ctx, ".fillStyle='rgb(", r, ",", g, ",", b, ")';"].}
```

**Texture Data Access**

Texture pixel data is kept as a JS reference (`JsObject`) for performance. Cache the data reference before hot loops:

```nim
var texData: JsObject
{.emit: [texData, "=", tex, ".jsData.data;"].}
# Then use texData[idx] in the loop
```

**Exported Functions**

Functions called from HTML use `{.exportc.}`:

```nim
proc toggleAscii() {.exportc.} =
  renderer.asciiMode = not renderer.asciiMode
```

## Features

- **Textured rendering** with diffuse lighting
- **Painter's algorithm** depth sorting
- **Backface culling** and frustum culling
- **ASCII art mode** with colored characters (zooms on upper body)
- **Mouse/touch drag** for rotation
- **Auto-rotation** toggle
- **Mobile responsive** design

## Guidelines

### Performance

- Cache texture data references before inner loops
- Use `{.inline.}` for small hot functions
- Avoid allocations in the render loop
- Precompute trig values (sin/cos) per frame, not per vertex

### Code Style

- Use section headers (`# ====`) to organize code
- Add doc comments (`##`) for public/complex procs
- Keep emit blocks minimal and well-commented
- Prefer `let` over `var` when possible

### Debugging

- Build timestamp shown in bottom-right corner
- Update cache buster in HTML when testing: `renderer.js?v=TIMESTAMP`
- Check browser console for JS errors from emit code

### Common Issues

1. **Texture not showing**: Check emit syntax for texture null check
2. **Variables as literals**: Use JS string concatenation in emit, not string interpolation
3. **Model inverted**: Canvas Y is flipped; use `height - 1 - y`
4. **Cache issues**: Update `?v=` query param in script tag
