## TinyRenderer - Software 3D Renderer
##
## A pure software rasterizer compiled from Nim to JavaScript.
## No WebGL - renders directly to a 2D canvas pixel buffer.
##
## Architecture:
##   1. Load OBJ model and PNG texture via fetch/Image APIs
##   2. Each frame: transform vertices, cull, sort by depth, rasterize
##   3. Scanline algorithm fills triangles with interpolated UV coords
##   4. Texture sampling with lighting applied per-pixel
##   5. Optional ASCII art mode converts pixel buffer to colored characters
##
## Rendering Pipeline:
##   Model Space → Rotate (Y then X) → Project → Screen Space
##   → Backface Cull → Frustum Cull → Depth Sort → Rasterize

import std/[dom, asyncjs, jsffi, strutils, algorithm, math]
import vec3

# ============================================================================
# Types
# ============================================================================

type
  Response* = ref object of JsObject

  UV = tuple[u, v: float]

  Face = object
    v: array[3, int]   # Vertex indices (into Model.vertices)
    t: array[3, int]   # Texture coord indices (into Model.texCoords)

  Texture = ref object
    width*, height*: int
    jsData*: JsObject  # Raw pixel data kept in JS for fast access

  Model = object
    vertices: seq[Vec3]
    texCoords: seq[UV]
    faces: seq[Face]

  Renderer = ref object
    canvas: Element
    ctx: JsObject           # Canvas 2D context
    width, height: int
    imageData: JsObject     # ImageData for pixel rendering
    pixels: JsObject        # Uint8ClampedArray pixel buffer
    model: Model
    texture: Texture
    rotationY, rotationX: float
    autoRotate: bool
    asciiMode: bool
    dragging: bool
    lastMouseX, lastMouseY: int

# ============================================================================
# Globals & Constants
# ============================================================================

var renderer: Renderer

# ASCII art character ramp: space (dark) to $ (bright)
const asciiChars = " .'`^\",:;Il!i><~+_-?][}{1)(|/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$"

# Light direction for diffuse shading (normalized, pointing FROM light source)
let lightDir = vec3(0.0, 0.5, -1.0).normalize()

# Build info for cache debugging
const buildTimestamp = CompileDate & " " & CompileTime

# ============================================================================
# JS Interop
# ============================================================================

proc text*(r: Response): Future[cstring] {.importjs: "#.text()".}
proc fetch*(url: cstring): Future[Response] {.importjs: "fetch(#)".}

# ============================================================================
# Pixel Buffer Operations
# ============================================================================

proc clear(r: Renderer) {.inline.} =
  ## Fill pixel buffer with dark background color (RGB: 20, 20, 30)
  {.emit: ["""
    const p = """, r.pixels, """;
    const len = p.length;
    for(let i=0; i<len; i+=4) { p[i]=20; p[i+1]=20; p[i+2]=30; p[i+3]=255; }
  """].}

# ============================================================================
# Triangle Rasterization
# ============================================================================

proc drawTexturedTriangle(r: Renderer,
    x0, y0: int, u0, v0: float,
    x1, y1: int, u1, v1: float,
    x2, y2: int, u2, v2: float,
    intensity: float) =
  ## Rasterize a textured triangle using scanline algorithm.
  ##
  ## The triangle is split into top and bottom halves at the middle vertex.
  ## For each scanline (y), we interpolate x and UV along the left/right edges,
  ## then interpolate across the span to sample the texture.

  # Sort vertices by Y coordinate (top to bottom)
  var py0, py1, py2 = y0
  var px0, px1, px2 = x0
  var pu0, pu1, pu2 = u0
  var pv0, pv1, pv2 = v0
  py1 = y1; px1 = x1; pu1 = u1; pv1 = v1
  py2 = y2; px2 = x2; pu2 = u2; pv2 = v2

  if py0 > py1: swap(py0, py1); swap(px0, px1); swap(pu0, pu1); swap(pv0, pv1)
  if py0 > py2: swap(py0, py2); swap(px0, px2); swap(pu0, pu2); swap(pv0, pv2)
  if py1 > py2: swap(py1, py2); swap(px1, px2); swap(pu1, pu2); swap(pv1, pv2)

  let totalHeight = py2 - py0
  if totalHeight == 0: return

  # Cache values for inner loop performance
  let width = r.width
  let height = r.height
  let tex = r.texture
  let texW = tex.width - 1
  let texH = tex.height - 1
  let texWidth = tex.width

  var texData: JsObject
  {.emit: [texData, "=", tex, ".jsData.data;"].}

  # Process each scanline from top vertex to bottom vertex
  for i in 0..<totalHeight:
    let secondHalf = i > py1 - py0 or py1 == py0
    let segmentHeight = if secondHalf: py2 - py1 else: py1 - py0
    if segmentHeight == 0: continue

    # Alpha: progress along the full height (v0 to v2)
    # Beta: progress along current segment (v0 to v1, or v1 to v2)
    let alpha = float(i) / float(totalHeight)
    let beta = if secondHalf:
      float(i - (py1 - py0)) / float(segmentHeight)
    else:
      float(i) / float(segmentHeight)

    # Interpolate x and UV coordinates along triangle edges
    var ax = float(px0) + float(px2 - px0) * alpha
    var au = pu0 + (pu2 - pu0) * alpha
    var av = pv0 + (pv2 - pv0) * alpha

    var bx, bu, bv: float
    if secondHalf:
      bx = float(px1) + float(px2 - px1) * beta
      bu = pu1 + (pu2 - pu1) * beta
      bv = pv1 + (pv2 - pv1) * beta
    else:
      bx = float(px0) + float(px1 - px0) * beta
      bu = pu0 + (pu1 - pu0) * beta
      bv = pv0 + (pv1 - pv0) * beta

    # Ensure ax is left edge, bx is right edge
    if ax > bx:
      swap(ax, bx); swap(au, bu); swap(av, bv)

    let y = py0 + i
    if y < 0 or y >= height: continue

    let iax = max(0, int(ax))
    let ibx = min(width - 1, int(bx))
    if iax > ibx: continue

    let spanWidth = bx - ax
    let invSpan = if spanWidth > 0.001: 1.0 / spanWidth else: 0.0
    let flippedY = height - 1 - y  # Canvas Y is flipped
    var baseIdx = (flippedY * width + iax) * 4

    # Fill horizontal span with textured pixels
    for x in iax..ibx:
      let t = (float(x) - ax) * invSpan
      let u = au + (bu - au) * t
      let v = av + (bv - av) * t

      # Sample texture at interpolated UV
      let tpx = int(clamp(u, 0.0, 1.0) * float(texW))
      let tpy = int((1.0 - clamp(v, 0.0, 1.0)) * float(texH))
      let tidx = (tpy * texWidth + tpx) * 4

      var tr, tg, tb: int
      {.emit: [tr, "=", texData, "[", tidx, "];", tg, "=", texData, "[", tidx, "+1];", tb, "=", texData, "[", tidx, "+2];"].}

      # Write pixel with lighting applied
      {.emit: [r.pixels, "[", baseIdx, "]=", tr, "*", intensity, "|0;"].}
      {.emit: [r.pixels, "[", baseIdx, "+1]=", tg, "*", intensity, "|0;"].}
      {.emit: [r.pixels, "[", baseIdx, "+2]=", tb, "*", intensity, "|0;"].}
      {.emit: [r.pixels, "[", baseIdx, "+3]=255;"].}
      baseIdx += 4

# ============================================================================
# 3D Projection & Culling
# ============================================================================

proc projectRotated(r: Renderer, rotated: Vec3): tuple[x, y: int, z: float] {.inline.} =
  ## Project a rotated 3D point to 2D screen coordinates using perspective.
  const fov = 2.0
  let z = rotated.z + 3.0  # Push model back from camera
  let scale = fov / max(z, 0.1)
  let halfW = float(r.width) * 0.5
  let halfH = float(r.height) * 0.5
  (
    x: int((rotated.x * scale + 1.0) * halfW),
    y: int((rotated.y * scale + 1.0) * halfH),
    z: rotated.z
  )

proc isInsideFrustum(r: Renderer, p: tuple[x, y: int, z: float]): bool =
  ## Check if a projected point is within the view frustum.
  let margin = 50  # Allow partially visible triangles
  p.x >= -margin and p.x < r.width + margin and
  p.y >= -margin and p.y < r.height + margin and
  p.z > -10.0

proc triangleVisible(r: Renderer, p0, p1, p2: tuple[x, y: int, z: float]): bool =
  ## A triangle is visible if any vertex is inside the frustum.
  r.isInsideFrustum(p0) or r.isInsideFrustum(p1) or r.isInsideFrustum(p2)

# ============================================================================
# Model Rendering
# ============================================================================

proc drawModel(r: Renderer) =
  ## Transform, cull, sort, and rasterize all model faces.

  type ProjectedFace = tuple[
    depth: float,
    intensity: float,
    p0, p1, p2: tuple[x, y: int, z: float],
    uv0, uv1, uv2: UV
  ]
  var visibleFaces: seq[ProjectedFace] = @[]

  # Precompute rotation matrix components
  let cosY = cos(r.rotationY)
  let sinY = sin(r.rotationY)
  let cosX = cos(r.rotationX)
  let sinX = sin(r.rotationX)

  template rotateVert(v: Vec3): Vec3 =
    # Apply Y rotation, then X rotation
    let ry = vec3(v.x * cosY + v.z * sinY, v.y, -v.x * sinY + v.z * cosY)
    vec3(ry.x, ry.y * cosX - ry.z * sinX, ry.y * sinX + ry.z * cosX)

  let hasTexCoords = r.model.texCoords.len > 0

  # Pass 1: Transform vertices, apply culling, compute lighting
  for face in r.model.faces:
    let v0 = r.model.vertices[face.v[0]]
    let v1 = r.model.vertices[face.v[1]]
    let v2 = r.model.vertices[face.v[2]]

    let rv0 = rotateVert(v0)
    let rv1 = rotateVert(v1)
    let rv2 = rotateVert(v2)

    # Compute face normal for backface culling and lighting
    let edge1 = rv1 - rv0
    let edge2 = rv2 - rv0
    let normal = cross(edge1, edge2).normalize()

    # Backface culling: skip faces pointing away from camera
    if normal.z > 0: continue

    # Diffuse lighting with ambient minimum
    let intensity = max(0.2, dot(normal, lightDir))

    let p0 = r.projectRotated(rv0)
    let p1 = r.projectRotated(rv1)
    let p2 = r.projectRotated(rv2)

    # Frustum culling
    if not r.triangleVisible(p0, p1, p2): continue

    # Get texture coordinates
    var uv0, uv1, uv2: UV
    if hasTexCoords and face.t[0] >= 0 and face.t[0] < r.model.texCoords.len:
      uv0 = r.model.texCoords[face.t[0]]
      uv1 = r.model.texCoords[face.t[1]]
      uv2 = r.model.texCoords[face.t[2]]
    else:
      uv0 = (u: 0.0, v: 0.0)
      uv1 = (u: 1.0, v: 0.0)
      uv2 = (u: 0.5, v: 1.0)

    let avgDepth = (rv0.z + rv1.z + rv2.z) / 3.0
    visibleFaces.add((depth: avgDepth, intensity: intensity,
                      p0: p0, p1: p1, p2: p2, uv0: uv0, uv1: uv1, uv2: uv2))

  # Pass 2: Sort back-to-front (painter's algorithm)
  visibleFaces.sort(proc(a, b: ProjectedFace): int = cmp(b.depth, a.depth))

  # Pass 3: Rasterize
  for fd in visibleFaces:
    r.drawTexturedTriangle(
      fd.p0.x, fd.p0.y, fd.uv0.u, fd.uv0.v,
      fd.p1.x, fd.p1.y, fd.uv1.u, fd.uv1.v,
      fd.p2.x, fd.p2.y, fd.uv2.u, fd.uv2.v,
      fd.intensity
    )

# ============================================================================
# Render Modes
# ============================================================================

proc renderToBuffer(r: Renderer) =
  ## Render model to the pixel buffer (shared by both render modes).
  r.clear()
  var hasTexture: bool
  {.emit: [hasTexture, " = !!", r.texture, " && !!", r.texture, ".jsData && !!", r.texture, ".jsData.data;"].}
  if r.model.vertices.len > 0 and hasTexture:
    r.drawModel()

proc renderNormal(r: Renderer) =
  ## Standard pixel-based rendering to canvas.
  r.renderToBuffer()
  {.emit: [r.ctx, ".putImageData(", r.imageData, ", 0, 0);"].}

proc renderAscii(r: Renderer) =
  ## ASCII art rendering: converts pixel buffer to colored characters.
  ## Zooms on the upper body for better detail.
  r.renderToBuffer()

  # Sample from a 240x240 region centered on upper body
  const srcSize = 240
  let srcOffsetX = (r.width - srcSize) div 2
  let srcOffsetY = r.height div 5

  let asciiCellSize = 10
  let cols = r.width div asciiCellSize
  let rows = r.height div asciiCellSize
  let srcCellSize = srcSize div cols

  {.emit: [r.ctx, ".clearRect(0,0,", r.width, ",", r.height, ");"].}
  {.emit: [r.ctx, ".font='bold 11px monospace';"].}
  {.emit: [r.ctx, ".textBaseline='top';"].}

  for row in 0..<rows:
    for col in 0..<cols:
      var totalR, totalG, totalB, totalBright = 0
      var sampleCount = 0

      # Average pixels within this cell
      for dy in 0..<srcCellSize:
        for dx in 0..<srcCellSize:
          let srcX = srcOffsetX + (col * srcCellSize) + dx
          let srcY = srcOffsetY + (row * srcCellSize) + dy
          if srcX >= 0 and srcX < r.width and srcY >= 0 and srcY < r.height:
            let idx = (srcY * r.width + srcX) * 4
            var pr, pg, pb: int
            {.emit: [pr, "=", r.pixels, "[", idx, "];"].}
            {.emit: [pg, "=", r.pixels, "[", idx, "+1];"].}
            {.emit: [pb, "=", r.pixels, "[", idx, "+2];"].}
            totalR += pr; totalG += pg; totalB += pb
            totalBright += (pr + pg + pb) div 3
            sampleCount += 1

      if sampleCount > 0:
        let avgR = totalR div sampleCount
        let avgG = totalG div sampleCount
        let avgB = totalB div sampleCount
        let avgBright = totalBright div sampleCount

        # Skip background pixels
        if avgBright > 20:
          # Map brightness to character density
          let boostedBright = min(255, (avgBright - 20) * 3)
          let charIdx = min((boostedBright * (asciiChars.len - 1)) div 255, asciiChars.len - 1)
          let charCode = ord(asciiChars[charIdx])

          # Boost colors for visibility
          let boostR = min(255, avgR * 5 div 3)
          let boostG = min(255, avgG * 5 div 3)
          let boostB = min(255, avgB * 5 div 3)

          let drawX = col * asciiCellSize
          let drawY = row * asciiCellSize
          {.emit: [r.ctx, ".fillStyle='rgb('+", boostR, "+','+", boostG, "+','+", boostB, "+')';"].}
          {.emit: [r.ctx, ".fillText(String.fromCharCode(", charCode, "),", drawX, ",", drawY, ");"].}

proc render(r: Renderer) =
  ## Main render dispatch.
  if r.asciiMode: r.renderAscii()
  else: r.renderNormal()

# ============================================================================
# Asset Loading
# ============================================================================

proc parseObjContent(content: string): Model =
  ## Parse Wavefront OBJ format into Model struct.
  ## Supports: v (vertices), vt (texture coords), f (faces with v/vt/vn format)
  var vertices: seq[Vec3] = @[]
  var texCoords: seq[UV] = @[]
  var faces: seq[Face] = @[]

  for line in content.splitLines():
    let parts = line.splitWhitespace()
    if parts.len == 0: continue

    case parts[0]
    of "v":
      if parts.len >= 4:
        vertices.add(vec3(parseFloat(parts[1]), parseFloat(parts[2]), parseFloat(parts[3])))
    of "vt":
      if parts.len >= 3:
        texCoords.add((u: parseFloat(parts[1]), v: parseFloat(parts[2])))
    of "f":
      if parts.len >= 4:
        proc parseFaceIndices(s: string): tuple[v, t: int] =
          let p = s.split('/')
          let vi = parseInt(p[0]) - 1  # OBJ is 1-indexed
          var ti = -1
          if p.len >= 2 and p[1].len > 0:
            ti = parseInt(p[1]) - 1
          (v: vi, t: ti)

        let f0 = parseFaceIndices(parts[1])
        let f1 = parseFaceIndices(parts[2])
        let f2 = parseFaceIndices(parts[3])
        faces.add(Face(v: [f0.v, f1.v, f2.v], t: [f0.t, f1.t, f2.t]))

        # Triangulate quads
        if parts.len >= 5:
          let f3 = parseFaceIndices(parts[4])
          faces.add(Face(v: [f0.v, f2.v, f3.v], t: [f0.t, f2.t, f3.t]))
    else: discard

  Model(vertices: vertices, texCoords: texCoords, faces: faces)

proc loadModel(url: string): Future[Model] {.async.} =
  let response = await fetch(cstring(url))
  let text = await response.text()
  result = parseObjContent($text)

proc loadTexture(url: cstring): Future[JsObject] =
  ## Load texture via Image API, extract pixel data via temporary canvas.
  var promise: Future[JsObject]
  {.emit: [promise, " = new Promise((resolve, reject) => {", """
    const urlStr = """, url, """;
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => {
      const canvas = document.createElement('canvas');
      canvas.width = img.width;
      canvas.height = img.height;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(img, 0, 0);
      const imageData = ctx.getImageData(0, 0, img.width, img.height);
      resolve({ width: img.width, height: img.height, data: imageData.data });
    };
    img.onerror = () => resolve({ width: 1, height: 1, data: new Uint8ClampedArray([128,128,128,255]) });
    img.src = urlStr;
  });"""].}
  result = promise

proc jsTextureToNim(jsObj: JsObject): Texture =
  ## Wrap JS texture object in Nim Texture type (keeps JS data reference).
  result = Texture()
  {.emit: [result, ".width=", jsObj, ".width;", result, ".height=", jsObj, ".height;", result, ".jsData=", jsObj, ";"].}

# ============================================================================
# Input Handling
# ============================================================================

proc setupEventHandlers(r: Renderer) =
  ## Setup mouse and touch drag handlers for rotation control.

  # Mouse drag
  r.canvas.addEventListener("mousedown", proc(e: Event) =
    let me = MouseEvent(e)
    r.dragging = true
    r.lastMouseX = me.clientX
    r.lastMouseY = me.clientY
  )

  document.addEventListener("mouseup", proc(e: Event) =
    r.dragging = false
  )

  document.addEventListener("mousemove", proc(e: Event) =
    if r.dragging:
      let me = MouseEvent(e)
      r.rotationY += float(me.clientX - r.lastMouseX) * 0.01
      r.rotationX += float(me.clientY - r.lastMouseY) * 0.01
      r.lastMouseX = me.clientX
      r.lastMouseY = me.clientY
  )

  # Touch drag (mobile)
  r.canvas.addEventListener("touchstart", proc(e: Event) =
    let te = TouchEvent(e)
    if te.touches.len > 0:
      r.dragging = true
      r.lastMouseX = te.touches[0].clientX
      r.lastMouseY = te.touches[0].clientY
  )

  document.addEventListener("touchend", proc(e: Event) =
    r.dragging = false
  )

  document.addEventListener("touchmove", proc(e: Event) =
    if r.dragging:
      let te = TouchEvent(e)
      if te.touches.len > 0:
        r.rotationY += float(te.touches[0].clientX - r.lastMouseX) * 0.01
        r.rotationX += float(te.touches[0].clientY - r.lastMouseY) * 0.01
        r.lastMouseX = te.touches[0].clientX
        r.lastMouseY = te.touches[0].clientY
  )

# ============================================================================
# Initialization & Main Loop
# ============================================================================

proc initRenderer(canvasId: cstring, width, height: int): Renderer =
  ## Create renderer with canvas context and pixel buffer.
  let canvas = document.getElementById(canvasId)
  canvas.setAttribute("width", cstring($width))
  canvas.setAttribute("height", cstring($height))

  var ctx: JsObject
  {.emit: [ctx, " = ", canvas, ".getContext('2d');"].}

  var imageData: JsObject
  {.emit: [imageData, " = ", ctx, ".createImageData(", width, ", ", height, ");"].}

  var pixels: JsObject
  {.emit: [pixels, " = ", imageData, ".data;"].}

  Renderer(
    canvas: canvas, ctx: ctx, width: width, height: height,
    imageData: imageData, pixels: pixels, model: Model(),
    rotationY: 0.0, rotationX: 0.0,
    autoRotate: true, asciiMode: false, dragging: false
  )

proc animate(timestamp: float) {.exportc.} =
  ## Animation frame callback.
  if renderer.autoRotate and not renderer.dragging:
    renderer.rotationY += 0.01
  renderer.render()
  discard window.requestAnimationFrame(animate)

proc selectModel(modelUrl: cstring, textureUrl: cstring) {.exportc.} =
  ## Load a model and texture, update status display.
  proc load() {.async.} =
    let statusEl = document.getElementById("status")
    statusEl.innerHTML = cstring("Loading model...")
    renderer.model = await loadModel($modelUrl)
    statusEl.innerHTML = cstring("Loading texture...")
    let texJs = await loadTexture(textureUrl)
    renderer.texture = jsTextureToNim(texJs)
    statusEl.innerHTML = cstring("Vertices: " & $renderer.model.vertices.len &
                                  " | Faces: " & $renderer.model.faces.len &
                                  " | Tex: " & $renderer.texture.width & "x" & $renderer.texture.height)
  discard load()

proc toggleAutoRotate() {.exportc.} =
  renderer.autoRotate = not renderer.autoRotate

proc toggleAscii() {.exportc.} =
  renderer.asciiMode = not renderer.asciiMode

proc main() {.exportc.} =
  renderer = initRenderer("canvas", 600, 600)
  renderer.setupEventHandlers()

  let buildInfo = document.getElementById("buildInfo")
  if not buildInfo.isNil:
    buildInfo.innerHTML = cstring("Build: " & buildTimestamp)

  selectModel(cstring("models/diablo3_pose.obj"), cstring("models/diablo3_pose_diffuse.png"))
  discard window.requestAnimationFrame(animate)

# Entry point
window.onload = proc(e: Event) = main()
