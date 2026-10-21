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
