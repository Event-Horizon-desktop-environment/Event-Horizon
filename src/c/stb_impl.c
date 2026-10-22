/* Bound all decoder allocations, including intermediate buffers and concurrent
 * decodes. Metadata travels with each allocation so frees may cross threads. */
#include <stddef.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#define EH_DECODE_BUDGET ((size_t)256 * 1024 * 1024)
#define EH_ALLOCATION_LIMIT ((size_t)128 * 1024 * 1024)
typedef union { max_align_t alignment; size_t size; } eh_alloc_header;
static _Atomic size_t eh_decode_bytes;
static void *eh_image_malloc(size_t size)
{
    if (size > EH_ALLOCATION_LIMIT) return NULL;
    size_t used = atomic_load(&eh_decode_bytes);
    do {
        if (size > EH_DECODE_BUDGET - used) return NULL;
    } while (!atomic_compare_exchange_weak(&eh_decode_bytes, &used, used + size));
    eh_alloc_header *h = malloc(sizeof(*h) + size);
    if (!h) { atomic_fetch_sub(&eh_decode_bytes, size); return NULL; }
    h->size = size;
    return h + 1;
}
static void eh_image_free(void *ptr)
{
    if (!ptr) return;
    eh_alloc_header *h = (eh_alloc_header *)ptr - 1;
    atomic_fetch_sub(&eh_decode_bytes, h->size);
    free(h);
}
static void *eh_image_realloc(void *ptr, size_t size)
{
    if (!ptr) return eh_image_malloc(size);
    void *next = eh_image_malloc(size);
    if (!next) return NULL;
    size_t old = ((eh_alloc_header *)ptr - 1)->size;
    memcpy(next, ptr, old < size ? old : size);
    eh_image_free(ptr);
    return next;
}
#define STBI_MALLOC eh_image_malloc
#define STBI_REALLOC eh_image_realloc
#define STBI_FREE eh_image_free
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
