import image/buffer;
import image/color;
import image/tga;

proc saveTgaImage(buffer: Buffer) =
  let tga = createTgaImage(buffer)
  saveToFile(tga, "output.tga")

var buf = createBuffer(100, 100, PixelType.RGB)

let red = redColor()
buf[52, 41] = red

saveTgaImage(buf)
