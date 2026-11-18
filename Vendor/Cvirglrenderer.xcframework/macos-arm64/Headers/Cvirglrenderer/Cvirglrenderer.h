#include <stdint.h>
#include <sys/uio.h>
#include "virglrenderer.h"
/* The renderer's own GL and EGL calls go through epoxy too, so they reach Mesa's. */
#include <epoxy/gl.h>
#include <epoxy/egl.h>
/* Opaque in the public header, but the transfer calls take one; this is src/virgl_hw.h's layout. */
struct virgl_box {
  uint32_t x, y, z;
  uint32_t w, h, d;
};
