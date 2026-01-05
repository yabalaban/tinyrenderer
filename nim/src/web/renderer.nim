## Web-based software renderer using HTML5 Canvas
import std/[dom, asyncjs, jsffi, math, strutils, sequtils]
import vec3

# Fetch API bindings for JS backend
type
  Response* = ref object of JsObject
  FetchOptions* = ref object of JsObject

proc text*(r: Response): Future[cstring] {.importjs: "#.text()".}
proc fetch*(url: cstring): Future[Response] {.importjs: "fetch(#)".}

type
  Color = object
    r, g, b, a: uint8

  Vertex = Vec3
  Face = tuple[i0, i1, i2: int]

  Model = object
    vertices: seq[Vertex]
    faces: seq[Face]

  Renderer = ref object
    canvas: Element
    ctx: JsObject
    width, height: int
    imageData: JsObject
    pixels: JsObject
    model: Model
    rotationY: float
    rotationX: float
    autoRotate: bool
    dragging: bool
    lastMouseX, lastMouseY: int

var renderer: Renderer

proc createColor(r, g, b: uint8, a: uint8 = 255): Color =
  Color(r: r, g: g, b: b, a: a)

proc whiteColor(): Color = createColor(255, 255, 255)
proc greenColor(): Color = createColor(0, 255, 100)
proc blueColor(): Color = createColor(100, 150, 255)

proc setPixel(r: Renderer, x, y: int, c: Color) =
  if x < 0 or x >= r.width or y < 0 or y >= r.height:
    return
  # Flip Y for canvas (0,0 is top-left)
  let flippedY = r.height - 1 - y
  let idx = (flippedY * r.width + x) * 4
  r.pixels[idx] = c.r.int
  r.pixels[idx + 1] = c.g.int
  r.pixels[idx + 2] = c.b.int
  r.pixels[idx + 3] = c.a.int

proc clear(r: Renderer, c: Color = createColor(20, 20, 30)) =
  for y in 0..<r.height:
    for x in 0..<r.width:
      r.setPixel(x, y, c)

proc drawLine(r: Renderer, x0, y0, x1, y1: int, c: Color) =
  var x0 = x0
  var y0 = y0
  var x1 = x1
  var y1 = y1
  var steep = false

  if abs(x0 - x1) < abs(y0 - y1):
    swap(x0, y0)
    swap(x1, y1)
    steep = true

  if x0 > x1:
    swap(x0, x1)
    swap(y0, y1)

  let dx = x1 - x0
  let dy = abs(y1 - y0)
  var error = 0
  var y = y0
  let yStep = if y1 > y0: 1 else: -1

  for x in x0..x1:
    if steep:
      r.setPixel(y, x, c)
    else:
      r.setPixel(x, y, c)
    error += dy * 2
    if error > dx:
      y += yStep
      error -= dx * 2

proc project(r: Renderer, v: Vertex): tuple[x, y: int, z: float] =
  # Apply rotations
  var rotated = v.rotateY(r.rotationY).rotateX(r.rotationX)

  # Simple perspective projection
  let fov = 2.0
  let z = rotated.z + 3.0  # Move model back
  let scale = fov / max(z, 0.1)

  let x = int((rotated.x * scale + 1.0) * float(r.width) / 2.0)
  let y = int((rotated.y * scale + 1.0) * float(r.height) / 2.0)

  result = (x: x, y: y, z: rotated.z)

proc isInsideFrustum(r: Renderer, p: tuple[x, y: int, z: float]): bool =
  ## Frustum culling - check if projected point is within view bounds
  let margin = 50  # Allow some margin for partially visible triangles
  p.x >= -margin and p.x < r.width + margin and
  p.y >= -margin and p.y < r.height + margin and
  p.z > -10.0  # Near plane culling

proc triangleVisible(r: Renderer, p0, p1, p2: tuple[x, y: int, z: float]): bool =
  ## Check if at least one vertex is potentially visible
  r.isInsideFrustum(p0) or r.isInsideFrustum(p1) or r.isInsideFrustum(p2)

import std/algorithm

proc drawModel(r: Renderer, wireColor: Color) =
  type FaceData = tuple[
    face: Face,
    depth: float,
    rv0, rv1, rv2: Vec3,  # Rotated vertices
    p0, p1, p2: tuple[x, y: int, z: float]  # Projected points
  ]
  var visibleFaces: seq[FaceData] = @[]

  # First pass: transform, cull backfaces, cull frustum
  for face in r.model.faces:
    let v0 = r.model.vertices[face.i0]
    let v1 = r.model.vertices[face.i1]
    let v2 = r.model.vertices[face.i2]

    # Rotate vertices
    let rv0 = v0.rotateY(r.rotationY).rotateX(r.rotationX)
    let rv1 = v1.rotateY(r.rotationY).rotateX(r.rotationX)
    let rv2 = v2.rotateY(r.rotationY).rotateX(r.rotationX)

    # Backface culling - compute face normal
    let edge1 = rv1 - rv0
    let edge2 = rv2 - rv0
    let normal = cross(edge1, edge2)

    # Skip back-facing triangles (normal pointing away from camera)
    if normal.z >= 0:
      continue

    # Project vertices
    let p0 = r.project(v0)
    let p1 = r.project(v1)
    let p2 = r.project(v2)

    # Frustum culling - skip if entirely outside view
    if not r.triangleVisible(p0, p1, p2):
      continue

    # Store for depth sorting
    let avgDepth = (rv0.z + rv1.z + rv2.z) / 3.0
    visibleFaces.add((
      face: face,
      depth: avgDepth,
      rv0: rv0, rv1: rv1, rv2: rv2,
      p0: p0, p1: p1, p2: p2
    ))

  # Depth sort: painter's algorithm (back to front)
  visibleFaces.sort(proc(a, b: FaceData): int =
    if a.depth > b.depth: -1
    elif a.depth < b.depth: 1
    else: 0
  )

  # Draw visible faces
  for fd in visibleFaces:
    r.drawLine(fd.p0.x, fd.p0.y, fd.p1.x, fd.p1.y, wireColor)
    r.drawLine(fd.p1.x, fd.p1.y, fd.p2.x, fd.p2.y, wireColor)
    r.drawLine(fd.p2.x, fd.p2.y, fd.p0.x, fd.p0.y, wireColor)

proc render(r: Renderer) =
  r.clear()
  if r.model.vertices.len > 0:
    r.drawModel(greenColor())

  # Copy pixel data to canvas
  {.emit: [r.ctx, ".putImageData(", r.imageData, ", 0, 0);"].}

proc parseObjContent(content: string): Model =
  var vertices: seq[Vertex] = @[]
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
    of "f":
      if parts.len >= 4:
        # OBJ face indices are 1-based and may have texture/normal indices
        proc parseIndex(s: string): int =
          let idx = s.split('/')[0]
          parseInt(idx) - 1

        let i0 = parseIndex(parts[1])
        let i1 = parseIndex(parts[2])
        let i2 = parseIndex(parts[3])
        faces.add((i0: i0, i1: i1, i2: i2))

        # Handle quads by triangulating
        if parts.len >= 5:
          let i3 = parseIndex(parts[4])
          faces.add((i0: i0, i1: i2, i2: i3))
    else:
      discard

  result = Model(vertices: vertices, faces: faces)

proc loadModel(url: string): Future[Model] {.async.} =
  let response = await fetch(cstring(url))
  let text = await response.text()
  result = parseObjContent($text)

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

proc selectModel(url: cstring) {.exportc.} =
  proc load() {.async.} =
    let statusEl = document.getElementById("status")
    statusEl.innerHTML = cstring("Loading model...")

    renderer.model = await loadModel($url)

    statusEl.innerHTML = cstring("Vertices: " & $renderer.model.vertices.len &
                                  " | Faces: " & $renderer.model.faces.len &
                                  " | Drag to rotate")

  discard load()

proc toggleAutoRotate() {.exportc.} =
  renderer.autoRotate = not renderer.autoRotate
  let btn = document.getElementById("autoRotateBtn")
  if renderer.autoRotate:
    btn.innerHTML = cstring("Auto-Rotate: ON")
  else:
    btn.innerHTML = cstring("Auto-Rotate: OFF")

proc main() {.exportc.} =
  renderer = initRenderer("canvas", 600, 600)
  renderer.setupEventHandlers()

  # Load default model
  selectModel(cstring("models/african_head.obj"))

  # Start animation loop
  discard window.requestAnimationFrame(animate)

# Auto-start when DOM is ready
window.onload = proc(e: Event) =
  main()
