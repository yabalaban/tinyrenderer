## 3D Vector math for transformations
import std/math

type
  Vec3* = object
    x*, y*, z*: float

proc vec3*(x, y, z: float): Vec3 =
  Vec3(x: x, y: y, z: z)

proc `+`*(a, b: Vec3): Vec3 =
  vec3(a.x + b.x, a.y + b.y, a.z + b.z)

proc `-`*(a, b: Vec3): Vec3 =
  vec3(a.x - b.x, a.y - b.y, a.z - b.z)

proc `*`*(a: Vec3, s: float): Vec3 =
  vec3(a.x * s, a.y * s, a.z * s)

proc dot*(a, b: Vec3): float =
  a.x * b.x + a.y * b.y + a.z * b.z

proc cross*(a, b: Vec3): Vec3 =
  vec3(
    a.y * b.z - a.z * b.y,
    a.z * b.x - a.x * b.z,
    a.x * b.y - a.y * b.x
  )

proc length*(v: Vec3): float =
  sqrt(v.x * v.x + v.y * v.y + v.z * v.z)

proc normalize*(v: Vec3): Vec3 =
  let len = v.length
  if len > 0:
    vec3(v.x / len, v.y / len, v.z / len)
  else:
    v

proc rotateY*(v: Vec3, angle: float): Vec3 =
  let c = cos(angle)
  let s = sin(angle)
  vec3(
    v.x * c + v.z * s,
    v.y,
    -v.x * s + v.z * c
  )

proc rotateX*(v: Vec3, angle: float): Vec3 =
  let c = cos(angle)
  let s = sin(angle)
  vec3(
    v.x,
    v.y * c - v.z * s,
    v.y * s + v.z * c
  )
