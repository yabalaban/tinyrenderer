import std/strutils;
import system/io;

type 
  Vertex = tuple[x: float, y: float, z: float]
  Face = tuple[i0: uint, i1: uint, i2: uint]

  Model* = object
    vertices*: seq[Vertex]
    faces*: seq[Face]

proc loadObjFile*(filename: string): Model =
  let f = open(filename)
  defer: f.close()

  var line: string 
  while f.readLine(line):
    let spl = split(line)
    case spl[0]
    of "v":
      let vertex = (x: parseFloat spl[1], y: parseFloat spl[2], z: parseFloat spl[3])
      result.vertices.add(vertex)
    of "f":
      let face = (
        i0: parseUInt(split(spl[1], "/")[0]) - 1,
        i1: parseUInt(split(spl[2], "/")[0]) - 1,
        i2: parseUInt(split(spl[3], "/")[0]) - 1,
      )
      result.faces.add(face)
    else:
      discard 

  