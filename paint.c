#include "paint.h"
#include "paint_shaders.h"

#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <dlfcn.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct program {
    GLuint id;
    GLint size, radii, clip_count, clip_boxes, clip_radii;
    GLint masked, mask_tex, mask_box, color, cutout_box, cutout_radii;
    GLint tex, alpha, blur;
};

struct paint {
    struct program rect, rgba, rgbx, external, shadow;
    GLenum (*reset_status)(void);
    int width, height, transform;
    struct paint_box *damage;
    size_t damage_len;
    bool active, failed, lost;
};

struct paint_texture {
    GLuint id;
    GLenum target;
    int width, height;
    bool owned, has_alpha;
};

struct paint_mask { GLuint id; };
struct paint_target { GLuint fbo, texture; };

static bool has_extension(const char *extensions, const char *name) {
    if (!extensions) return false;
    size_t len = strlen(name);
    const char *at = extensions;
    while ((at = strstr(at, name))) {
        if ((at == extensions || at[-1] == ' ') &&
                (at[len] == '\0' || at[len] == ' ')) return true;
        at += len;
    }
    return false;
}

static bool errors(void) {
    bool failed = false;
    while (glGetError() != GL_NO_ERROR) failed = true;
    return failed;
}

static GLuint compile(GLenum type, const char **sources, int count) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, count, sources, NULL);
    glCompileShader(shader);
    GLint ok;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "paint: shader compile: %s\n", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static bool program_create(struct program *s, const char *prefix, const char *body) {
    const char *vertex[] = {paint_shader_vertex};
    const char *fragment[] = {prefix, paint_shader_common, body};
    GLuint vs = compile(GL_VERTEX_SHADER, vertex, 1);
    GLuint fs = compile(GL_FRAGMENT_SHADER, fragment, 3);
    if (!vs || !fs) {
        glDeleteShader(vs);
        glDeleteShader(fs);
        return false;
    }
    s->id = glCreateProgram();
    glAttachShader(s->id, vs);
    glAttachShader(s->id, fs);
    glBindAttribLocation(s->id, 0, "position");
    glBindAttribLocation(s->id, 1, "local");
    glBindAttribLocation(s->id, 2, "uv");
    glLinkProgram(s->id);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok;
    glGetProgramiv(s->id, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetProgramInfoLog(s->id, sizeof(log), NULL, log);
        fprintf(stderr, "paint: program link: %s\n", log);
        return false;
    }
#define UNIFORM(name) s->name = glGetUniformLocation(s->id, #name)
    UNIFORM(size); UNIFORM(radii); UNIFORM(clip_count);
    UNIFORM(clip_boxes); UNIFORM(clip_radii); UNIFORM(masked);
    UNIFORM(mask_tex); UNIFORM(mask_box); UNIFORM(color);
    UNIFORM(cutout_box); UNIFORM(cutout_radii); UNIFORM(tex);
    UNIFORM(alpha); UNIFORM(blur);
#undef UNIFORM
    return true;
}

struct paint *paint_create(void) {
    const char *version = (const char *)glGetString(GL_VERSION);
    const char *ext = (const char *)glGetString(GL_EXTENSIONS);
    if (!version || (strncmp(version, "OpenGL ES 2.", 12) &&
            strncmp(version, "OpenGL ES 3.", 12)) ||
            !has_extension(ext, "GL_OES_EGL_image_external")) {
        fprintf(stderr, "paint: GLES2 and GL_OES_EGL_image_external are required\n");
        return NULL;
    }
    struct paint *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    if (has_extension(ext, "GL_EXT_robustness") ||
            has_extension(ext, "GL_KHR_robustness")) {
        /* GLVND exports the core alias, not the extension aliases. All
         * three names dispatch the same reset-status operation in Mesa. */
        p->reset_status = (GLenum (*)(void))dlsym(RTLD_DEFAULT, "glGetGraphicsResetStatusEXT");
        if (!p->reset_status)
            p->reset_status = (GLenum (*)(void))dlsym(RTLD_DEFAULT, "glGetGraphicsResetStatusKHR");
        if (!p->reset_status)
            p->reset_status = (GLenum (*)(void))dlsym(RTLD_DEFAULT, "glGetGraphicsResetStatus");
        if (!p->reset_status) {
            fprintf(stderr, "paint: reset-status entry point unavailable\n");
            paint_destroy(p);
            return NULL;
        }
    }
    if (!program_create(&p->rect, "", paint_shader_rect) ||
            !program_create(&p->rgba, "", paint_shader_texture) ||
            !program_create(&p->rgbx, "#define OPAQUE\n", paint_shader_texture) ||
            !program_create(&p->external,
                "#extension GL_OES_EGL_image_external : require\n#define EXTERNAL\n",
                paint_shader_texture) ||
            !program_create(&p->shadow, "", paint_shader_shadow) || errors()) {
        paint_destroy(p);
        return NULL;
    }
    return p;
}

void paint_destroy(struct paint *p) {
    if (!p) return;
    glDeleteProgram(p->rect.id);
    glDeleteProgram(p->rgba.id);
    glDeleteProgram(p->rgbx.id);
    glDeleteProgram(p->external.id);
    glDeleteProgram(p->shadow.id);
    free(p->damage);
    free(p);
}

static bool valid_box(struct paint_box b) {
    return isfinite(b.x) && isfinite(b.y) && isfinite(b.width) &&
        isfinite(b.height) && b.width >= 0 && b.height >= 0 &&
        isfinite(b.x + b.width) && isfinite(b.y + b.height);
}

bool paint_begin(struct paint *p, unsigned int fbo, int width, int height,
        int transform, const struct paint_box *damage, size_t damage_len) {
    if (!p || p->active || p->lost || width <= 0 || height <= 0 ||
            transform < 0 || transform > 7 || (damage_len && !damage) ||
            damage_len > SIZE_MAX / sizeof(*damage)) return false;
    for (size_t i = 0; i < damage_len; i++)
        if (!valid_box(damage[i])) return false;
    struct paint_box *copy = NULL;
    if (damage_len) {
        copy = malloc(damage_len * sizeof(*copy));
        if (!copy) return false;
        memcpy(copy, damage, damage_len * sizeof(*copy));
    }
    free(p->damage);
    p->damage = copy;
    p->damage_len = damage_len;
    p->width = width;
    p->height = height;
    p->transform = transform;
    p->failed = false;
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glViewport(0, 0, width, height);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_DITHER);
    glDisable(GL_SAMPLE_ALPHA_TO_COVERAGE);
    glDisable(GL_SAMPLE_COVERAGE);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glEnable(GL_SCISSOR_TEST);
    glEnable(GL_BLEND);
    glBlendEquation(GL_FUNC_ADD);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE || errors())
        return false;
    p->active = true;
    return true;
}

static void scissor(struct paint *p, size_t i) {
    struct paint_box b = p->damage_len ? p->damage[i] :
        (struct paint_box){0, 0, p->width, p->height};
    int x = (int)floorf(fmaxf(0, fminf(p->width, b.x)));
    int y = (int)floorf(fmaxf(0, fminf(p->height, b.y)));
    int right = (int)ceilf(fmaxf(0, fminf(p->width, b.x + b.width)));
    int bottom = (int)ceilf(fmaxf(0, fminf(p->height, b.y + b.height)));
    glScissor(x, y, right - x, bottom - y);
}

void paint_clear(struct paint *p, struct paint_color color) {
    if (!p || !p->active) return;
    glClearColor(color.r, color.g, color.b, color.a);
    for (size_t i = 0; i < (p->damage_len ? p->damage_len : 1); i++) {
        scissor(p, i);
        glClear(GL_COLOR_BUFFER_BIT);
    }
}

void paint_fit_radii(float dst[4], const float radii[4], float w, float h) {
    float f = 1;
    if (radii[0] + radii[1] > w) f = fminf(f, w / (radii[0] + radii[1]));
    if (radii[3] + radii[2] > w) f = fminf(f, w / (radii[3] + radii[2]));
    if (radii[0] + radii[3] > h) f = fminf(f, h / (radii[0] + radii[3]));
    if (radii[1] + radii[2] > h) f = fminf(f, h / (radii[1] + radii[2]));
    for (int i = 0; i < 4; i++) dst[i] = radii[i] * f;
}

static void point(float *x, float *y, int transform) {
    float a = *x, b = *y;
    switch (transform) {
    case 1: *x = 1 - b; *y = a; break;
    case 2: *x = 1 - a; *y = 1 - b; break;
    case 3: *x = b; *y = 1 - a; break;
    case 4: *x = 1 - a; *y = b; break;
    case 5: *x = b; *y = a; break;
    case 6: *x = a; *y = 1 - b; break;
    case 7: *x = 1 - b; *y = 1 - a; break;
    }
}

static bool round_uniforms(struct paint *p, struct program *s,
        struct paint_box box, const float radii[4],
        const struct paint_clip *clips, size_t clips_len,
        const struct paint_mask *mask, struct paint_box mask_box) {
    if (!valid_box(box) || clips_len > PAINT_CLIPS ||
            (mask && (!valid_box(mask_box) || mask_box.width <= 0 || mask_box.height <= 0))) {
        p->failed = true;
        return false;
    }
    if (box.width == 0 || box.height == 0) return false;
    GLfloat boxes[PAINT_CLIPS][4], rs[PAINT_CLIPS][4];
    for (size_t i = 0; i < clips_len; i++) {
        if (!valid_box(clips[i].box)) {
            p->failed = true;
            return false;
        }
        boxes[i][0] = clips[i].box.x - box.x;
        boxes[i][1] = clips[i].box.y - box.y;
        boxes[i][2] = clips[i].box.width;
        boxes[i][3] = clips[i].box.height;
        memcpy(rs[i], clips[i].radii, sizeof(rs[i]));
    }
    glUseProgram(s->id);
    glUniform2f(s->size, box.width, box.height);
    glUniform4fv(s->radii, 1, radii);
    glUniform1i(s->clip_count, (GLint)clips_len);
    if (clips_len) {
        glUniform4fv(s->clip_boxes, (GLsizei)clips_len, &boxes[0][0]);
        glUniform4fv(s->clip_radii, (GLsizei)clips_len, &rs[0][0]);
    }
    glUniform1i(s->masked, mask != NULL);
    glUniform1i(s->mask_tex, 1);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, mask ? mask->id : 0);
    if (mask) glUniform4f(s->mask_box, mask_box.x - box.x, mask_box.y - box.y,
        mask_box.width, mask_box.height);
    return true;
}

static void quad(struct paint *p, struct paint_box box, float pad,
        const struct paint_texture *texture, struct paint_box src, int transform) {
    float vertices[4][6];
    int inverse = p->transform;
    if ((inverse & 1) && !(inverse & 4)) inverse ^= 2;
    float width = (p->transform & 1) ? p->height : p->width;
    float height = (p->transform & 1) ? p->width : p->height;
    for (int i = 0; i < 4; i++) {
        float x = (i & 1) ? box.width + pad : -pad;
        float y = (i & 2) ? box.height + pad : -pad;
        float px = (box.x + x) / width, py = (box.y + y) / height;
        point(&px, &py, inverse);
        vertices[i][0] = 2 * px - 1;
        vertices[i][1] = 2 * py - 1;
        vertices[i][2] = x / box.width;
        vertices[i][3] = y / box.height;
        float u = x / box.width, v = y / box.height;
        point(&u, &v, transform);
        vertices[i][4] = texture ? (src.x + u * src.width) / texture->width : 0;
        vertices[i][5] = texture ? (src.y + v * src.height) / texture->height : 0;
    }
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    for (GLuint i = 0; i < 3; i++) {
        glEnableVertexAttribArray(i);
        glVertexAttribPointer(i, 2, GL_FLOAT, GL_FALSE, sizeof(vertices[0]), &vertices[0][2 * i]);
    }
    for (size_t i = 0; i < (p->damage_len ? p->damage_len : 1); i++) {
        scissor(p, i);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
    for (GLuint i = 0; i < 3; i++) glDisableVertexAttribArray(i);
}

void paint_rect(struct paint *p, const struct paint_rect_params *params) {
    if (!p || !p->active || !params) return;
    struct program *s = &p->rect;
    if (!round_uniforms(p, s, params->box, params->radii, params->clips,
            params->clips_len, params->mask, params->mask_box)) return;
    glUniform4f(s->color, params->color.r, params->color.g, params->color.b, params->color.a);
    glUniform4f(s->cutout_box, params->cutout.x - params->box.x,
        params->cutout.y - params->box.y, params->cutout.width, params->cutout.height);
    glUniform4fv(s->cutout_radii, 1, params->cutout_radii);
    /* The shader's one-pixel ramp extends half a pixel beyond the box. */
    quad(p, params->box, 0.5f, NULL, (struct paint_box){0}, 0);
}

static void texture_parameters(GLenum target, bool nearest) {
    glTexParameteri(target, GL_TEXTURE_MIN_FILTER, nearest ? GL_NEAREST : GL_LINEAR);
    glTexParameteri(target, GL_TEXTURE_MAG_FILTER, nearest ? GL_NEAREST : GL_LINEAR);
    glTexParameteri(target, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(target, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

struct paint_target *paint_target_create(struct paint *p, int width, int height) {
    if (!p || p->lost || p->active || width <= 0 || height <= 0) return NULL;
    struct paint_target *t = calloc(1, sizeof(*t));
    if (!t) return NULL;
    glGenTextures(1, &t->texture);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, t->texture);
    texture_parameters(GL_TEXTURE_2D, true);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0,
        GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &t->fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, t->fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
        GL_TEXTURE_2D, t->texture, 0);
    bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    if (errors() || !complete || !t->texture || !t->fbo) {
        paint_target_destroy(t);
        return NULL;
    }
    return t;
}

void paint_target_destroy(struct paint_target *t) {
    if (!t) return;
    glDeleteFramebuffers(1, &t->fbo);
    glDeleteTextures(1, &t->texture);
    free(t);
}

unsigned int paint_target_fbo(const struct paint_target *t) {
    return t ? t->fbo : 0;
}

void paint_texture(struct paint *p, const struct paint_texture_params *params) {
    if (!p || !p->active || !params) return;
    const struct paint_texture *t = params->texture;
    if (!t || params->transform < 0 || params->transform > 7 || !valid_box(params->src)) {
        p->failed = true;
        return;
    }
    struct program *s = t->target == GL_TEXTURE_EXTERNAL_OES ? &p->external :
        (t->has_alpha ? &p->rgba : &p->rgbx);
    if (!round_uniforms(p, s, params->dst, params->radii, params->clips,
            params->clips_len, params->mask, params->mask_box)) return;
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(t->target, t->id);
    texture_parameters(t->target, params->nearest);
    glUniform1i(s->tex, 0);
    glUniform1f(s->alpha, params->alpha);
    quad(p, params->dst, 0.5f, t, params->src, params->transform);
}

void paint_shadow(struct paint *p, const struct paint_shadow_params *params) {
    if (!p || !p->active || !params) return;
    if (!isfinite(params->blur) || params->blur < 0 || !isfinite(params->spread)) {
        p->failed = true;
        return;
    }
    struct paint_box b = params->box;
    b.x += params->offset_x - params->spread;
    b.y += params->offset_y - params->spread;
    b.width = fmaxf(0, b.width + 2 * params->spread);
    b.height = fmaxf(0, b.height + 2 * params->spread);
    float radii[4];
    for (int i = 0; i < 4; i++) radii[i] = fmaxf(0, params->radii[i] + params->spread);
    struct program *s = &p->shadow;
    if (!round_uniforms(p, s, b, radii, params->clips, params->clips_len,
            NULL, (struct paint_box){0})) return;
    glUniform4f(s->color, params->color.r, params->color.g, params->color.b, params->color.a);
    glUniform1f(s->blur, params->blur);
    quad(p, b, fmaxf(params->blur, 0.5f), NULL, (struct paint_box){0}, 0);
}

bool paint_end(struct paint *p) {
    if (!p || !p->active) return false;
    glFlush();
    if (p->reset_status && p->reset_status() != GL_NO_ERROR) p->lost = true;
    bool gl_failed = errors();
    p->active = false;
    return !p->failed && !p->lost && !gl_failed;
}

static bool pixel_size(int width, int height, int stride, size_t bpp) {
    return width > 0 && height > 0 && stride > 0 &&
        (size_t)width <= SIZE_MAX / bpp / (size_t)height &&
        (size_t)stride >= (size_t)width * bpp &&
        (size_t)height <= SIZE_MAX / (size_t)stride;
}

static GLuint upload(int width, int height, GLenum format, const void *pixels) {
    GLuint id;
    glGenTextures(1, &id);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, id);
    texture_parameters(GL_TEXTURE_2D, false);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, format, width, height, 0, format, GL_UNSIGNED_BYTE, pixels);
    return id;
}

struct paint_texture *paint_texture_upload(struct paint *p, int width, int height,
        int stride, const void *pixels) {
    if (!p || p->lost || !pixels || !pixel_size(width, height, stride, 4)) return NULL;
    unsigned char *rgba = malloc((size_t)width * height * 4);
    if (!rgba) return NULL;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            uint32_t c;
            memcpy(&c, (const char *)pixels + (size_t)y * stride + (size_t)x * 4, 4);
            size_t i = ((size_t)y * width + x) * 4;
            rgba[i] = c >> 16;
            rgba[i + 1] = c >> 8;
            rgba[i + 2] = c;
            rgba[i + 3] = c >> 24;
        }
    }
    struct paint_texture *t = calloc(1, sizeof(*t));
    if (t) {
        *t = (struct paint_texture){upload(width, height, GL_RGBA, rgba),
            GL_TEXTURE_2D, width, height, true, true};
        if (errors()) {
            p->failed = true;
            paint_texture_destroy(t);
            t = NULL;
        }
    }
    free(rgba);
    return t;
}

struct paint_texture *paint_texture_import(struct paint *p, unsigned int gl_id,
        unsigned int gl_target, int width, int height, bool has_alpha) {
    if (!p || p->lost || !gl_id || width <= 0 || height <= 0 ||
            (gl_target != GL_TEXTURE_2D && gl_target != GL_TEXTURE_EXTERNAL_OES)) return NULL;
    struct paint_texture *t = malloc(sizeof(*t));
    if (t) *t = (struct paint_texture){gl_id, gl_target, width, height, false, has_alpha};
    return t;
}

void paint_texture_destroy(struct paint_texture *t) {
    if (!t) return;
    if (t->owned) glDeleteTextures(1, &t->id);
    free(t);
}

struct paint_mask *paint_mask_upload(struct paint *p, int width, int height,
        int stride, const void *coverage) {
    if (!p || p->lost || !coverage || !pixel_size(width, height, stride, 1)) return NULL;
    unsigned char *packed = malloc((size_t)width * height);
    if (!packed) return NULL;
    for (int y = 0; y < height; y++)
        memcpy(packed + (size_t)y * width, (const char *)coverage + (size_t)y * stride, width);
    struct paint_mask *m = malloc(sizeof(*m));
    if (m) {
        m->id = upload(width, height, GL_ALPHA, packed);
        if (errors()) {
            p->failed = true;
            paint_mask_destroy(m);
            m = NULL;
        }
    }
    free(packed);
    return m;
}

void paint_mask_destroy(struct paint_mask *m) {
    if (!m) return;
    glDeleteTextures(1, &m->id);
    free(m);
}

bool paint_readback(struct paint *p, struct paint_box box, int stride, void *pixels) {
    if (!p || p->lost || !pixels || !valid_box(box) ||
            box.x < 0 || box.y < 0 || box.x >= INT_MAX || box.y >= INT_MAX ||
            box.width >= INT_MAX || box.height >= INT_MAX ||
            floorf(box.x) != box.x || floorf(box.y) != box.y ||
            floorf(box.width) != box.width || floorf(box.height) != box.height ||
            !pixel_size((int)box.width, (int)box.height, stride, 4)) return false;
    int w = (int)box.width, h = (int)box.height;
    unsigned char *rgba = malloc((size_t)w * h * 4);
    if (!rgba) return false;
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels((int)box.x, (int)box.y, w, h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    bool failed = errors();
    p->failed |= failed;
    if (!failed) {
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                size_t i = ((size_t)y * w + x) * 4;
                uint32_t c = (uint32_t)rgba[i + 3] << 24 | (uint32_t)rgba[i] << 16 |
                    (uint32_t)rgba[i + 1] << 8 | rgba[i + 2];
                memcpy((char *)pixels + (size_t)y * stride + (size_t)x * 4, &c, 4);
            }
        }
    }
    free(rgba);
    return !failed;
}
