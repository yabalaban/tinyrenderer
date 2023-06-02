type 
  Color* = object 
    r*, g*, b*, a*: uint8 

proc createColor*(r, g, b, a: uint8): Color = 
  result.r = r
  result.g = g
  result.b = b
  result.a = a 

proc createColor*(r, g, b: uint8): Color = 
  createColor(r, g, b, 0xFF)

proc createColor*(c: uint8): Color =
  createColor(c, c, c)

proc blackColor*(): Color =
  createColor(0x00)

proc whiteColor*(): Color =
  createColor(0xFF)

proc redColor*(): Color =
  createColor(0xFF, 0x00, 0x00)

proc greenColor*(): Color =
  createColor(0x00, 0xFF, 0x00)

proc blueColor*(): Color =
  createColor(0x00, 0x00, 0xFF)

proc withAlpha*(color: Color, a: uint8): Color =
  result = color 
  result.a = a 