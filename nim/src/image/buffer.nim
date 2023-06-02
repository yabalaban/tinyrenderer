import std/sequtils;

import color;

type 
  PixelType* = enum 
    RGB,
    RGBA, 

  Buffer* = object
    width*: uint 
    height*: uint
    data*: seq[uint8]
    pixelType*: PixelType
    
# Forward declarations 
proc createBuffer*(width, height: uint, pixelType: PixelType): Buffer

func pixelSize(pixelType: PixelType): uint {.inline.} =
  case pixelType:
  of RGB:
    result = 3
  of RGBA:
    result = 4 

func index(x, y, width: uint, pixelType: PixelType): uint {.inline.} =
  pixelSize(pixelType) * (y * width + x) 

proc createBuffer*(width, height: uint, pixelType: PixelType): Buffer = 
  result.width = width
  result.height = height
  result.pixelType = pixelType 
  case pixelType:
  of RGB:
    insert(result.data, repeat(0x00'u8, 3 * width * height))
  of RGBA:
    insert(result.data, cycle([0x00'u8, 0x00, 0x00, 0xFF], width * height))
  
proc `[]=`* (buf: var Buffer, x, y: uint, color: Color) =
  let idx = index(x, y, buf.width, buf.pixelType)
  buf.data[idx] = color.b
  buf.data[idx + 1] = color.g
  buf.data[idx + 2] = color.r
  if buf.pixelType == PixelType.RGBA:
    buf.data[idx + 3] = color.a

proc `[]`* (buf: Buffer, x, y: uint): Color =
  let idx = index(x, y, buf.width, buf.pixelType)
  let b = buf.data[idx] 
  let g = buf.data[idx + 1] 
  let r = buf.data[idx + 2] 
  var a: uint8
  if buf.pixelType == PixelType.RGBA:
    a = buf.data[idx + 3]
  else:
    a = 0xFF
  result = createColor(r, g, b, a)