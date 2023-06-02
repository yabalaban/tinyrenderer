iterator countup*[T: SomeFloat](a, b: T, step: T | Positive): T =
    assert(step > 0.0, "step must be positive")
    var acc = a
    while acc <= b:
        yield acc
        acc += step

proc abs*[T: SomeUnsignedInt](a, b: T): T {.inline.} =
  max(a, b) - min(a, b) 

proc p*[T: SomeNumber](x: T, y: T): tuple[x: uint, y: uint] {.inline.} =
    (x: x.uint, y: y.uint)