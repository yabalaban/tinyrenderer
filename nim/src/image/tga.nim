import std/sequtils;

import buffer;

type
  ImageSpec = tuple 
    xOrigin:              array[2, uint8]
    yOrigin:              array[2, uint8]
    width:                array[2, uint8]
    height:               array[2, uint8]
    pixelDepth:           uint8
    descriptor:           uint8
    
  Header = tuple 
    idLength:             uint8
    colorMapType:         uint8
    imageType:            uint8
    colorMapSpec:         array[5, uint8] # unused 
    imageSpec:            ImageSpec

  Data = object
    imageId:              seq[uint8]
    colorMapData:         seq[uint8]
    imageData:            seq[uint8]

  Footer = tuple 
    extensionOffset:      array[4, uint8]
    developerAreaOffset:  array[4, uint8]
    signature:            array[16, uint8]
    dot:                  uint8
    nul:                  uint8

  TGAImage* = object 
    header:                 Header 
    data:                   Data  
    footer:                 Footer 
     
proc createTgaImage*(buffer: Buffer): TGAImage = 
  result.header.imageType = 0x02

  copyMem(addr result.header.imageSpec.width, unsafeAddr buffer.width, sizeof(uint16))
  copyMem(addr result.header.imageSpec.height, unsafeAddr buffer.height, sizeof(uint16))

  case buffer.pixelType 
  of RGB:
    result.header.imageSpec.pixelDepth = 0x18 # RGB, 24-bit
  of RGBA:
    result.header.imageSpec.pixelDepth = 0x20 # RGBA, 32-bit
    result.header.imageSpec.descriptor = 0x08 # 8-bit depth  

  insert(result.data.imageData, buffer.data)

  result.footer.signature = [0x54'u8, 0x52, 0x55, 0x45, 0x56, 0x49, 0x53, 0x49, 0x4f, 0x4e, 0x2d, 0x58, 0x46, 0x49, 0x4c, 0x45]
  result.footer.dot = '.'.uint8
     
proc saveToFile*(image: TGAImage, filename: string) = 
  var f = open(filename, fmWrite)
  discard f.writeBuffer(image.header.unsafeAddr, sizeof(image.header))
  discard f.writeBytes(image.data.imageData, 0, len(image.data.imageData))
  discard f.writeBuffer(image.footer.unsafeAddr, sizeof(image.footer))
  f.close()
