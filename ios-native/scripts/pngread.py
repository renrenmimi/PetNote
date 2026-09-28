import struct, zlib

def read_png(path):
    d = open(path,'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n'
    i = 8; idat = b''; w=h=bd=ct=None
    while i < len(d):
        ln, typ = struct.unpack('>I4s', d[i:i+8])
        body = d[i+8:i+8+ln]
        if typ == b'IHDR':
            w,h,bd,ct,comp,filt,inter = struct.unpack('>IIBBBBB', body)
            if bd != 8 or inter != 0:
                raise ValueError(
                    f"{path}: {bd}-bit, interlace={inter}. This reader handles "
                    "8-bit non-interlaced PNG; run it through "
                    "`sips -s format png --setProperty bitsPerSample 8` first."
                )
        elif typ == b'IDAT': idat += body
        elif typ == b'IEND': break
        i += 12 + ln
    nch = {0:1,2:3,3:1,4:2,6:4}[ct]
    raw = zlib.decompress(idat)
    stride = w*nch
    out = bytearray(h*stride)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        if f == 1:
            for x in range(nch, stride): line[x] = (line[x] + line[x-nch]) & 255
        elif f == 2:
            for x in range(stride): line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride):
                a = line[x-nch] if x >= nch else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x-nch] if x >= nch else 0
                b = prev[x]
                c = prev[x-nch] if x >= nch else 0
                p = a+b-c
                pa,pb,pc = abs(p-a),abs(p-b),abs(p-c)
                pr = a if (pa<=pb and pa<=pc) else (b if pb<=pc else c)
                line[x] = (line[x] + pr) & 255
        out[y*stride:(y+1)*stride] = line
        prev = line
    return w,h,nch,bytes(out)

def px(w,nch,data,x,y):
    o = (y*w + x)*nch
    return data[o], data[o+1], data[o+2]

# Minimal PNG decoder, carried in the repo because this machine has no PIL and
# device screenshots need pixel-level checks. Handles 8-bit non-interlaced PNG,
# which is what `sips -s format png --setProperty bitsPerSample 8` produces.
