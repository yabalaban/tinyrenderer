# TinyRenderer

Software 3D rasterizer: Nim → JavaScript. Renders textured models in browser via Canvas 2D. No WebGL.

## Stack

```
Nim → JavaScript (nim js)
HTML5 Canvas 2D
Pure software rasterization
```

## Structure

```
tinyrenderer/
├── docs/
│   ├── index.html
│   ├── renderer.js          # compiled (do not edit)
│   └── models/
│       ├── diablo3_pose.obj
│       └── diablo3_pose_diffuse.png
├── nim/src/web/
│   ├── renderer.nim         # main (~580 lines)
│   ├── vec3.nim             # vector math
│   └── config.nims
├── claude.md
└── LICENSE
```

## Build

```bash
cd nim/src/web
nim js -d:release -o:../../../docs/renderer.js renderer.nim
```

## Pipeline

```
Model Space
    ↓ Rotate (Y then X)
    ↓ Project (perspective)
Screen Space
    ↓ Backface cull
    ↓ Frustum cull
    ↓ Depth sort
    ↓ Rasterize (scanline)
Pixel Buffer
```

## Code Sections (renderer.nim)

```
1.  Types
2.  Globals & Constants
3.  JS Interop
4.  Pixel Buffer Operations
5.  Triangle Rasterization
6.  3D Projection & Culling
7.  Model Rendering
8.  Render Modes
9.  Asset Loading
10. Input Handling
11. Initialization & Main Loop
```

## Emit Patterns

Correct — JS string concatenation:

```nim
{.emit: [
  ctx, ".fillStyle='rgb('+",
  r, "+','+",
  g, "+','+",
  b, "+')';",
].}
```

Wrong — variables become literals:

```nim
{.emit: [ctx, ".fillStyle='rgb(", r, ",", g, ")';"].}
# outputs: ctx.fillStyle='rgb(r_123,g_456)';
```

Cache texture data before loops:

```nim
var texData: JsObject
{.emit: [texData, "=", tex, ".jsData.data;"].}
```

Export for HTML:

```nim
proc toggleAscii() {.exportc.} =
  renderer.asciiMode = not renderer.asciiMode
```

## Features

```
- Textured rendering + diffuse lighting
- Painter's algorithm depth sort
- Backface + frustum culling
- ASCII art mode (colored, zoomed)
- Mouse/touch rotation
- Auto-rotation toggle
- Mobile responsive
```

## Guidelines

```
Performance:
- Cache texture refs before inner loops
- Use {.inline.} for hot functions
- Precompute sin/cos per frame
- Avoid allocations in render loop

Style:
- Section headers: # ====
- Doc comments: ##
- Prefer let over var

Debug:
- Build timestamp in bottom-right
- Update ?v= in script tag
- Check console for emit errors

Common Issues:
- Texture missing → check emit null check
- Vars as literals → use JS concatenation
- Model inverted → canvas Y is flipped
- Cache stale → update ?v= param
```
