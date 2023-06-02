import image/buffer; 
import image/color; 
import obj/model; 
import utils;

proc drawLine*(buffer: var Buffer, p0: tuple[x: uint, y: uint], p1: tuple[x: uint, y: uint], c: Color) = 
  var p0 = p0 
  var p1 = p1 
  var steep = false 

  if abs(p0.x, p1.x) < abs(p0.y, p1.y):
    swap(p0.x, p0.y)
    swap(p1.x, p1.y)
    steep = true

  if p0.x > p1.x:
    swap(p0.x, p1.x)
    swap(p0.y, p1.y)

  let dx = p1.x - p0.x
  let derror2 = 2 * abs(p0.y, p1.y)
  var error2 = 0
  var y = p0.y
  for x in countup(p0.x, p1.x):
    if steep:
      buffer[y, x] = c
    else:
      buffer[x, y] = c
    error2 += derror2.int

    if error2 > dx.int:
      if p1.y > p0.y: 
        y += 1 
      else: 
        y -= 1
      error2 -= 2 * dx.int

proc drawModel*(buffer: var Buffer, model: Model, c: Color) =
  for face in model.faces:
    let pairs = @[(face[0], face[1]), (face[1], face[2]), (face[2], face[0])]
    for pair in pairs:
      let p0 = model.vertices[pair[0]]
      let p1 = model.vertices[pair[1]]
      let x0 = (p0.x + 1) * buffer.width.float / 2
      let y0 = (p0.y + 1) * buffer.height.float / 2
      let x1 = (p1.x + 1) * buffer.width.float / 2
      let y1 = (p1.y + 1) * buffer.height.float / 2
      drawLine(
        buffer, 
        p(min(x0, buffer.width.float - 1), min(y0, buffer.height.float - 1)), 
        p(min(x1, buffer.width.float - 1), min(y1, buffer.height.float - 1)), 
        c
      )