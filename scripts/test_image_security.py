#!/usr/bin/env python3
"""Decoder/writer regression tests; requires a C compiler with ASan/UBSan."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def png(w, h, depth, color, raw, interlace=0):
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, depth, color, 0, 0, interlace))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


HARNESS = r'''
#include <assert.h>
#include <sys/stat.h>
#include <unistd.h>
#include "src/c/stb_impl.c"
extern int eh_write_png(const char *, int, int, const void *, int, int);
int main(int argc, char **argv) {
    assert(argc == 3);
    int x, y, n;
    unsigned char *pixels = stbi_load(argv[1], &x, &y, &n, 4);
    assert((pixels != NULL) == atoi(argv[2]));
    if (pixels) { assert(x > 0 && y > 0); stbi_image_free(pixels); }
    assert(atomic_load(&eh_decode_bytes) == 0);
    // Previously wrapped the 16-bit RGBA allocation to zero bytes.
    stbi__uint16 *tiny = eh_image_malloc(2);
    assert(!stbi__convert_format16(tiny, 1, 4, 65536, 8192));
    assert(atomic_load(&eh_decode_bytes) == 0);
    assert(!eh_image_malloc(EH_ALLOCATION_LIMIT + 1));
    void *a = eh_image_malloc(EH_ALLOCATION_LIMIT);
    void *b = eh_image_malloc(EH_ALLOCATION_LIMIT);
    assert(a && b && !eh_image_malloc(1));
    eh_image_free(a); eh_image_free(b);
    unsigned char rgba[] = {20, 40, 60, 255};
    umask(0022);
    assert(eh_write_png("private.png", 1, 1, rgba, 4, 1));
    assert(!eh_write_png("private.png", 1, 1, rgba, 4, 1));
    struct stat st;
    assert(stat("private.png", &st) == 0 && (st.st_mode & 0777) == 0600);
    assert(symlink("private.png", "link.png") == 0);
    assert(!eh_write_png("link.png", 1, 1, rgba, 4, 1));
    pixels = stbi_load("private.png", &x, &y, &n, 4);
    assert(pixels && memcmp(pixels, rgba, 4) == 0);
    stbi_image_free(pixels);
    unlink("link.png"); unlink("private.png");
    assert(atomic_load(&eh_decode_bytes) == 0);
    return 0;
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix='eh-image-tests-') as directory:
        work = Path(directory)
        (work / 'test.c').write_text(HARNESS)
        subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-D_DEFAULT_SOURCE', '-g',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-no-pie',
                        '-I', str(ROOT), '-I', str(ROOT / 'third_party/stb'),
                        str(work / 'test.c'), str(ROOT / 'src/c/stb_write.c'), '-lm', '-o', str(work / 'test')], check=True)
        cases = {
            'rgba': (png(1, 1, 8, 6, b'\0\x14\x28\x3c\xff'), True),
            'gray16': (png(1, 1, 16, 0, b'\0\xff\xff'), True),
            'packed': (png(9, 1, 1, 0, b'\0\xff\x80'), True),
            'excess': (png(1, 1, 8, 6, bytes(1024 * 1024)), False),
            'short': (png(1, 1, 8, 6, bytes(4)), False),
            'allocation_budget': (png(10000, 10000, 8, 6, b'\0'), False),
        }
        for w, h in [(1, 1), (2, 3), (9, 9)]:
            raw = b''
            for xo, yo, xs, ys in zip([0,4,0,2,0,1,0], [0,0,4,0,2,0,1], [8,8,4,4,2,2,1], [8,8,8,4,4,2,2]):
                pw, ph = max(0, (w-xo+xs-1)//xs), max(0, (h-yo+ys-1)//ys)
                if pw and ph:
                    raw += bytes((pw * 4 + 1) * ph)
            cases[f'adam7_{w}_{h}'] = (png(w, h, 8, 6, raw, 1), True)
            cases[f'adam7_excess_{w}_{h}'] = (png(w, h, 8, 6, raw + b'\0', 1), False)
        for name, (data, expected) in cases.items():
            fixture = work / f'{name}.png'
            fixture.write_bytes(data)
            subprocess.run([str(work / 'test'), str(fixture), str(int(expected))], cwd=work, check=True)
            print(f'PASS {name}', flush=True)


if __name__ == '__main__':
    main()
