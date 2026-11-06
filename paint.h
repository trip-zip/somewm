#ifndef SOMEWM_PAINT_H
#define SOMEWM_PAINT_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* All calls require the same caller-owned GLES2 context to be current.
 * State is not restored. Destroy textures and masks before their renderer.
 * Coordinates are device pixels. Colors are premultiplied. Radii use CSS
 * order: top-left, top-right, bottom-right, bottom-left. */
struct paint;
struct paint_texture;
struct paint_mask;
struct paint_target;

struct paint_box { float x, y, width, height; };
struct paint_color { float r, g, b, a; };
struct paint_clip { struct paint_box box; float radii[4]; };
#define PAINT_CLIPS 4

struct paint_rect_params {
    struct paint_box box;
    struct paint_color color;
    float radii[4];
    struct paint_box cutout; /* Width 0 disables the cutout. */
    float cutout_radii[4];
    struct paint_clip clips[PAINT_CLIPS];
    size_t clips_len;
    const struct paint_mask *mask;
    struct paint_box mask_box;
};

struct paint_texture_params {
    const struct paint_texture *texture;
    struct paint_box dst;
    struct paint_box src; /* Texture pixels. */
    int transform; /* Source wl_output_transform, 0 through 7. */
    float alpha;
    float radii[4];
    struct paint_clip clips[PAINT_CLIPS];
    size_t clips_len;
    const struct paint_mask *mask;
    struct paint_box mask_box;
    bool nearest; /* False selects linear filtering. */
};

struct paint_shadow_params {
    struct paint_box box;
    float radii[4];
    float blur;
    float spread;
    float offset_x, offset_y;
    struct paint_color color;
    struct paint_clip clips[PAINT_CLIPS];
    size_t clips_len;
};

/* Returns NULL if the context or required extensions are unavailable. */
struct paint *paint_create(void);
void paint_destroy(struct paint *p);

/* An offscreen RGBA8 color target owned by the renderer. Created under
 * the caller's current context, destroyed before the renderer. */
struct paint_target *paint_target_create(struct paint *p, int width, int height);
void paint_target_destroy(struct paint_target *t);
/* The framebuffer id for paint_begin and paint_readback. */
unsigned int paint_target_fbo(const struct paint_target *t);

/* The caller owns fbo. Boxes use the output's logical orientation and the
 * inverse output transform maps them to the buffer. Damage uses buffer
 * coordinates with row zero at the scanout top. Damage rectangles must not
 * overlap. The list is copied. An empty list covers the whole buffer.
 * Draws require a successful begin. clips_len must not exceed PAINT_CLIPS. */
bool paint_begin(struct paint *p, unsigned int fbo, int width, int height,
        int transform, const struct paint_box *damage, size_t damage_len);
void paint_clear(struct paint *p, struct paint_color color);
void paint_rect(struct paint *p, const struct paint_rect_params *params);
void paint_texture(struct paint *p, const struct paint_texture_params *params);
void paint_shadow(struct paint *p, const struct paint_shadow_params *params);
/* Flushes and checks reset status and errors. False invalidates the frame. */
bool paint_end(struct paint *p);

/* Native-endian ARGB32, premultiplied, top-down rows, stride in bytes.
 * Uploads copy the pixels and own the resulting texture. */
struct paint_texture *paint_texture_upload(struct paint *p, int width, int height,
        int stride, const void *pixels);
/* Imports borrow a caller-owned GL_TEXTURE_2D or GL_TEXTURE_EXTERNAL_OES id.
 * Row zero is the image top. Destroying the handle never deletes the id. */
struct paint_texture *paint_texture_import(struct paint *p, unsigned int gl_id,
        unsigned int gl_target, int width, int height, bool has_alpha);
void paint_texture_destroy(struct paint_texture *t);

/* A8 coverage, top-down rows, stride in bytes. Upload copies the bytes. */
struct paint_mask *paint_mask_upload(struct paint *p, int width, int height,
        int stride, const void *coverage);
void paint_mask_destroy(struct paint_mask *m);

/* Reads integer buffer coordinates into top-down native-endian ARGB32 rows.
 * Valid during a frame or after the caller binds an fbo. Row zero is the
 * scanout top, which corresponds to framebuffer row zero. Stride is bytes. */
bool paint_readback(struct paint *p, struct paint_box box, int stride, void *pixels);
void paint_fit_radii(float dst[4], const float radii[4], float w, float h);

#endif
