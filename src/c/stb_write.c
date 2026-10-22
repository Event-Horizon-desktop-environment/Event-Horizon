/* PNG encoding for the screenshot path.
 *
 * Kept in its own translation unit (and its own header include) so the
 * writer symbols stay `extern`: the Zig side cImports `stb_image_write.h`
 * for the declarations and links this object for the implementation.
 * `stb_impl.c` next door does the same for the *decoder* — the two stb
 * libraries only share a header-name prefix, never a symbol.
 */
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

/* Encode through a securely opened descriptor, never fopen's umask defaults. */
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
typedef struct { int fd; int failed; } eh_png_sink;
/** Write an encoded chunk completely, recording failures for the caller. */
static void eh_png_write(void *context, void *data, int size)
{
    eh_png_sink *sink = context;
    char *p = data;
    while (size > 0 && !sink->failed) {
        ssize_t n = write(sink->fd, p, (size_t)size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { sink->failed = 1; break; }
        p += n;
        size -= (int)n;
    }
}
/** Encode RGBA pixels to a private file; exclusive mode refuses existing paths. */
int eh_write_png(const char *path, int w, int h, const void *data, int stride, int exclusive)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (exclusive ? O_EXCL : O_TRUNC), 0600);
    if (fd < 0) return 0;
    eh_png_sink sink = {fd, 0};
    int ok = stbi_write_png_to_func(eh_png_write, &sink, w, h, 4, data, stride);
    if (close(fd) != 0) sink.failed = 1;
    return ok && !sink.failed;
}
