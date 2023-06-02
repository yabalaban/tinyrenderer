import image/buffer;
import image/color;
import image/tga;
import obj/model;

import tinyrenderer;

proc saveTgaImage(buffer: Buffer) =
  let tga = createTgaImage(buffer)
  saveToFile(tga, "output.tga")

var buf = createBuffer(1200, 1200, PixelType.RGB)

let white = whiteColor()
let obj = loadObjFile("obj/african_head/african_head.obj")
buf.drawModel(obj, white)

saveTgaImage(buf)
