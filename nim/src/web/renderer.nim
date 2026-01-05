## Web-based software renderer using HTML5 Canvas
import std/[dom, asyncjs, jsffi, strutils, algorithm, math]
import vec3

# Fetch API bindings for JS backend
type
  Response* = ref object of JsObject
  FetchOptions* = ref object of JsObject

proc text*(r: Response): Future[cstring] {.importjs: "#.text()".}
proc fetch*(url: cstring): Future[Response] {.importjs: "fetch(#)".}

type
  UV = tuple[u, v: float]

  Vertex = Vec3

  Face = object
    v: array[3, int]   # Vertex indices
    t: array[3, int]   # Texture coord indices

  Texture = ref object
    width*, height*: int
    jsData*: JsObject   # Keep data in JS for fast access

  Model = object
    vertices: seq[Vertex]
    texCoords: seq[UV]
    faces: seq[Face]

  Renderer = ref object
    canvas: Element
    ctx: JsObject
    width, height: int
    imageData: JsObject
    pixels: JsObject
    model: Model
    texture: Texture
    rotationY: float
    rotationX: float
    autoRotate: bool
    dragging: bool
    lastMouseX, lastMouseY: int

var renderer: Renderer

# Light direction (normalized vector pointing FROM the light source)
# Camera at z=0 looking towards +Z, so light from front means negative Z
let lightDir = vec3(0.0, 0.5, -1.0).normalize()

proc clear(r: Renderer) {.inline.} =
  # Use JS typed array operations for fast clear
  {.emit: ["""
    const p = """, r.pixels, """;
    const len = p.length;
    for(let i=0; i<len; i+=4) { p[i]=20; p[i+1]=20; p[i+2]=30; p[i+3]=255; }
  """].}

proc drawTexturedTriangle(r: Renderer,
    x0, y0: int, u0, v0: float,
    x1, y1: int, u1, v1: float,
    x2, y2: int, u2, v2: float,
    intensity: float) =
  ## Scanline triangle rasterization with texture interpolation
  # Sort vertices by y coordinate using local vars (avoid tuple overhead)
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

  let width = r.width
  let height = r.height
  let tex = r.texture
  let texW = tex.width - 1
  let texH = tex.height - 1
  let texWidth = tex.width

  # Draw both halves of triangle
  for i in 0..<totalHeight:
    let secondHalf = i > py1 - py0 or py1 == py0
    let segmentHeight = if secondHalf: py2 - py1 else: py1 - py0
    if segmentHeight == 0: continue

    let alpha = float(i) / float(totalHeight)
    let beta = if secondHalf:
      float(i - (py1 - py0)) / float(segmentHeight)
    else:
      float(i) / float(segmentHeight)

    # Interpolate x and UV along edges
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

    if ax > bx:
      swap(ax, bx)
      swap(au, bu)
      swap(av, bv)

    let y = py0 + i
    if y < 0 or y >= height: continue

    let iax = max(0, int(ax))
    let ibx = min(width - 1, int(bx))
    if iax > ibx: continue

    let spanWidth = bx - ax
    let invSpan = if spanWidth > 0.001: 1.0 / spanWidth else: 0.0
    let flippedY = height - 1 - y
    var baseIdx = (flippedY * width + iax) * 4

    # Inner loop - most critical for performance
    for x in iax..ibx:
      let t = (float(x) - ax) * invSpan
      let u = au + (bu - au) * t
      let v = av + (bv - av) * t

      # Inline texture sample and pixel write
      let tpx = int(clamp(u, 0.0, 1.0) * float(texW))
      let tpy = int((1.0 - clamp(v, 0.0, 1.0)) * float(texH))
      let tidx = (tpy * texWidth + tpx) * 4

      var tr, tg, tb: int
      {.emit: ["var td=", tex, ".jsData.data;", tr, "=td[", tidx, "];", tg, "=td[", tidx, "+1];", tb, "=td[", tidx, "+2];"].}

      # Apply lighting and write pixel directly
      {.emit: [r.pixels, "[", baseIdx, "]=", tr, "*", intensity, "|0;"].}
      {.emit: [r.pixels, "[", baseIdx, "+1]=", tg, "*", intensity, "|0;"].}
      {.emit: [r.pixels, "[", baseIdx, "+2]=", tb, "*", intensity, "|0;"].}
      {.emit: [r.pixels, "[", baseIdx, "+3]=255;"].}
      baseIdx += 4

proc projectRotated(r: Renderer, rotated: Vec3): tuple[x, y: int, z: float] {.inline.} =
  ## Project already-rotated vertex to screen coordinates
  const fov = 2.0
  let z = rotated.z + 3.0  # Move model back
  let scale = fov / max(z, 0.1)
  let halfW = float(r.width) * 0.5
  let halfH = float(r.height) * 0.5
  (
    x: int((rotated.x * scale + 1.0) * halfW),
    y: int((rotated.y * scale + 1.0) * halfH),
    z: rotated.z
  )

proc isInsideFrustum(r: Renderer, p: tuple[x, y: int, z: float]): bool =
  ## Frustum culling - check if projected point is within view bounds
  let margin = 50  # Allow some margin for partially visible triangles
  p.x >= -margin and p.x < r.width + margin and
  p.y >= -margin and p.y < r.height + margin and
  p.z > -10.0  # Near plane culling

proc triangleVisible(r: Renderer, p0, p1, p2: tuple[x, y: int, z: float]): bool =
  ## Check if at least one vertex is potentially visible
  r.isInsideFrustum(p0) or r.isInsideFrustum(p1) or r.isInsideFrustum(p2)

proc drawModel(r: Renderer) =
  # Data needed for drawing after culling
  type ProjectedFace = tuple[
    depth: float,
    intensity: float,
    p0, p1, p2: tuple[x, y: int, z: float],
    uv0, uv1, uv2: UV
  ]
  var visibleFaces: seq[ProjectedFace] = @[]

  # Precompute trig for rotation (avoid recalculating per-vertex)
  let cosY = cos(r.rotationY)
  let sinY = sin(r.rotationY)
  let cosX = cos(r.rotationX)
  let sinX = sin(r.rotationX)

  template rotateVert(v: Vec3): Vec3 =
    # Inline combined Y then X rotation
    let ry = vec3(v.x * cosY + v.z * sinY, v.y, -v.x * sinY + v.z * cosY)
    vec3(ry.x, ry.y * cosX - ry.z * sinX, ry.y * sinX + ry.z * cosX)

  let hasTexCoords = r.model.texCoords.len > 0

  # First pass: transform, cull backfaces, compute lighting, cull frustum
  for face in r.model.faces:
    let v0 = r.model.vertices[face.v[0]]
    let v1 = r.model.vertices[face.v[1]]
    let v2 = r.model.vertices[face.v[2]]

    # Rotate vertices (using precomputed trig)
    let rv0 = rotateVert(v0)
    let rv1 = rotateVert(v1)
    let rv2 = rotateVert(v2)

    # Compute full 3D face normal for lighting
    let edge1 = rv1 - rv0
    let edge2 = rv2 - rv0
    let normal = cross(edge1, edge2).normalize()

    # Backface culling - camera at z=0 looking towards +Z
    # Front faces have normals pointing TOWARDS camera, i.e., towards -Z
    if normal.z > 0:
      continue

    # Compute lighting intensity
    let intensity = max(0.2, dot(normal, lightDir))

    # Project already-rotated vertices
    let p0 = r.projectRotated(rv0)
    let p1 = r.projectRotated(rv1)
    let p2 = r.projectRotated(rv2)

    # Frustum culling - skip if entirely outside view
    if not r.triangleVisible(p0, p1, p2):
      continue

    # Get UV coordinates
    var uv0, uv1, uv2: UV
    if hasTexCoords and face.t[0] >= 0 and face.t[0] < r.model.texCoords.len:
      uv0 = r.model.texCoords[face.t[0]]
      uv1 = r.model.texCoords[face.t[1]]
      uv2 = r.model.texCoords[face.t[2]]
    else:
      uv0 = (u: 0.0, v: 0.0)
      uv1 = (u: 1.0, v: 0.0)
      uv2 = (u: 0.5, v: 1.0)

    # Store for depth sorting
    let avgDepth = (rv0.z + rv1.z + rv2.z) * 0.333333
    visibleFaces.add((
      depth: avgDepth, intensity: intensity,
      p0: p0, p1: p1, p2: p2,
      uv0: uv0, uv1: uv1, uv2: uv2
    ))

  # Depth sort: painter's algorithm (back to front, furthest first)
  visibleFaces.sort(proc(a, b: ProjectedFace): int = cmp(b.depth, a.depth))

  # Draw visible faces with texturing
  for fd in visibleFaces:
    r.drawTexturedTriangle(
      fd.p0.x, fd.p0.y, fd.uv0.u, fd.uv0.v,
      fd.p1.x, fd.p1.y, fd.uv1.u, fd.uv1.v,
      fd.p2.x, fd.p2.y, fd.uv2.u, fd.uv2.v,
      fd.intensity
    )

proc render(r: Renderer) =
  r.clear()
  if r.model.vertices.len > 0:
    r.drawModel()

  # Copy pixel data to canvas
  {.emit: [r.ctx, ".putImageData(", r.imageData, ", 0, 0);"].}

proc parseObjContent(content: string): Model =
  var vertices: seq[Vertex] = @[]
  var texCoords: seq[UV] = @[]
  var faces: seq[Face] = @[]

  for line in content.splitLines():
    let parts = line.splitWhitespace()
    if parts.len == 0:
      continue

    case parts[0]
    of "v":
      if parts.len >= 4:
        let x = parseFloat(parts[1])
        let y = parseFloat(parts[2])
        let z = parseFloat(parts[3])
        vertices.add(vec3(x, y, z))
    of "vt":
      if parts.len >= 3:
        let u = parseFloat(parts[1])
        let v = parseFloat(parts[2])
        texCoords.add((u: u, v: v))
    of "f":
      if parts.len >= 4:
        # OBJ face format: v/vt/vn or v/vt or v//vn or v
        proc parseFaceIndices(s: string): tuple[v, t: int] =
          let parts = s.split('/')
          let vi = parseInt(parts[0]) - 1  # Vertex index (1-based to 0-based)
          var ti = -1
          if parts.len >= 2 and parts[1].len > 0:
            ti = parseInt(parts[1]) - 1  # Texture index
          (v: vi, t: ti)

        let f0 = parseFaceIndices(parts[1])
        let f1 = parseFaceIndices(parts[2])
        let f2 = parseFaceIndices(parts[3])
        faces.add(Face(v: [f0.v, f1.v, f2.v], t: [f0.t, f1.t, f2.t]))

        # Handle quads by triangulating
        if parts.len >= 5:
          let f3 = parseFaceIndices(parts[4])
          faces.add(Face(v: [f0.v, f2.v, f3.v], t: [f0.t, f2.t, f3.t]))
    else:
      discard

  result = Model(vertices: vertices, texCoords: texCoords, faces: faces)

proc loadModel(url: string): Future[Model] {.async.} =
  let response = await fetch(cstring(url))
  let text = await response.text()
  result = parseObjContent($text)

proc loadTexture(url: cstring): Future[JsObject] =
  ## Load texture from image URL using JavaScript Image API
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
  ## Convert JS texture object to Nim Texture - store reference only
  result = Texture()
  {.emit: [result, ".width=", jsObj, ".width;", result, ".height=", jsObj, ".height;", result, ".jsData=", jsObj, ";"].}

proc animate(timestamp: float) {.exportc.} =
  if renderer.autoRotate and not renderer.dragging:
    renderer.rotationY += 0.01

  renderer.render()
  discard window.requestAnimationFrame(animate)

proc setupEventHandlers(r: Renderer) =
  # Mouse events for rotation control
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
      let deltaX = me.clientX - r.lastMouseX
      let deltaY = me.clientY - r.lastMouseY
      r.rotationY += float(deltaX) * 0.01
      r.rotationX += float(deltaY) * 0.01
      r.lastMouseX = me.clientX
      r.lastMouseY = me.clientY
  )

  # Touch events for mobile
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
        let deltaX = te.touches[0].clientX - r.lastMouseX
        let deltaY = te.touches[0].clientY - r.lastMouseY
        r.rotationY += float(deltaX) * 0.01
        r.rotationX += float(deltaY) * 0.01
        r.lastMouseX = te.touches[0].clientX
        r.lastMouseY = te.touches[0].clientY
  )

proc initRenderer(canvasId: cstring, width, height: int): Renderer =
  let canvas = document.getElementById(canvasId)
  canvas.setAttribute("width", cstring($width))
  canvas.setAttribute("height", cstring($height))

  var ctx: JsObject
  {.emit: [ctx, " = ", canvas, ".getContext('2d');"].}

  var imageData: JsObject
  {.emit: [imageData, " = ", ctx, ".createImageData(", width, ", ", height, ");"].}

  var pixels: JsObject
  {.emit: [pixels, " = ", imageData, ".data;"].}

  result = Renderer(
    canvas: canvas,
    ctx: ctx,
    width: width,
    height: height,
    imageData: imageData,
    pixels: pixels,
    model: Model(),
    rotationY: 0.0,
    rotationX: 0.0,
    autoRotate: true,
    dragging: false
  )

proc selectModel(modelUrl: cstring, textureUrl: cstring) {.exportc.} =
  proc load() {.async.} =
    let statusEl = document.getElementById("status")
    statusEl.innerHTML = cstring("Loading model...")

    renderer.model = await loadModel($modelUrl)

    statusEl.innerHTML = cstring("Loading texture...")

    # Load texture
    let texJs = await loadTexture(textureUrl)
    renderer.texture = jsTextureToNim(texJs)

    statusEl.innerHTML = cstring("Vertices: " & $renderer.model.vertices.len &
                                  " | Faces: " & $renderer.model.faces.len &
                                  " | Tex: " & $renderer.texture.width & "x" & $renderer.texture.height)

  discard load()

proc toggleAutoRotate() {.exportc.} =
  renderer.autoRotate = not renderer.autoRotate
  let btn = document.getElementById("autoRotateBtn")
  if renderer.autoRotate:
    btn.innerHTML = cstring("Auto-Rotate: ON")
  else:
    btn.innerHTML = cstring("Auto-Rotate: OFF")

const buildTimestamp = CompileDate & " " & CompileTime

proc main() {.exportc.} =
  renderer = initRenderer("canvas", 600, 600)
  renderer.setupEventHandlers()

  # Show build timestamp
  let buildInfo = document.getElementById("buildInfo")
  if not buildInfo.isNil:
    buildInfo.innerHTML = cstring("Build: " & buildTimestamp)

  # Load default model with texture
  selectModel(
    cstring("models/diablo3_pose.obj"),
    cstring("models/diablo3_pose_diffuse.png")
  )

  # Start animation loop
  discard window.requestAnimationFrame(animate)

# Auto-start when DOM is ready
window.onload = proc(e: Event) =
  main()
