#include "paint.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "paint_context.h"
static struct paint *renderer;
static const char *case_name;
static const struct paint_color red = {1, 0, 0, 1};
static const struct paint_color blue = {0, 0, 1, 1};
static const struct paint_color transparent = {0};

struct fixture { struct paint_target *target; GLuint fbo; int width, height; };

static struct fixture begin_size(int width, int height, struct paint_color background, int transform) {
    struct fixture f = {.width = width, .height = height};
    f.target = paint_target_create(renderer, width, height);
    assert(f.target);
    f.fbo = paint_target_fbo(f.target);
    assert(paint_begin(renderer, f.fbo, width, height, transform, NULL, 0));
    paint_clear(renderer, background);
    return f;
}

static struct fixture begin(struct paint_color background) {
    return begin_size(64, 64, background, 0);
}

static void finish(struct fixture f) {
    assert(paint_end(renderer));
    paint_target_destroy(f.target);
}

static uint32_t pixel(int x, int y) {
    uint32_t value;
    assert(paint_readback(renderer, (struct paint_box){x, y, 1, 1}, 4, &value));
    return value;
}

static void expect_value(uint32_t actual, uint32_t expected, int x, int y) {
    for (int shift = 0; shift < 32; shift += 8) {
        int a = (actual >> shift) & 255, e = (expected >> shift) & 255;
        if (abs(a - e) > 2) {
            fprintf(stderr, "%s: (%d,%d) got %08x, expected %08x\n", case_name, x, y, actual, expected);
            abort();
        }
    }
}

static void expect(int x, int y, uint32_t expected) {
    expect_value(pixel(x, y), expected, x, y);
}

static void ramp(int x, int y) {
    uint32_t c = pixel(x, y);
    int r = (c >> 16) & 255, b = c & 255;
    assert(r > 0 && r < 255 && b > 0 && b < 255);
}

static struct paint_texture *solid(void) {
    uint32_t pixels[32 * 32];
    for (size_t i = 0; i < 32 * 32; i++) pixels[i] = 0xffff0000;
    struct paint_texture *t = paint_texture_upload(renderer, 32, 32, 128, pixels);
    assert(t);
    return t;
}

static struct paint_texture_params texture_params(const struct paint_texture *t) {
    return (struct paint_texture_params){.texture = t, .dst = {0, 0, 64, 64},
        .src = {0, 0, 32, 32}, .alpha = 1};
}

static void rect_square_corners(void) {
    struct fixture f = begin(blue);
    struct paint_rect_params r = {.box = {8, 12, 40, 32}, .color = red};
    paint_rect(renderer, &r);
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++)
        expect(x, y, x >= 8 && x < 48 && y >= 12 && y < 44 ? 0xffff0000 : 0xff0000ff);
    finish(f);
}

static void rect_rounded_corners(void) {
    struct fixture f = begin(blue);
    struct paint_rect_params r = {.box = {8, 8, 48, 48}, .color = red, .radii = {16,16,16,16}};
    paint_rect(renderer, &r);
    expect(10, 10, 0xff0000ff);
    expect(32, 32, 0xffff0000);
    ramp(12, 12);
    finish(f);
}

static void rect_fit_radii(void) {
    struct fixture f = begin(blue);
    struct paint_rect_params r = {.box = {8, 8, 48, 48}, .color = red, .radii = {40,40,0,0}};
    float fitted[4];
    paint_fit_radii(fitted, r.radii, 48, 48);
    assert(fitted[0] == 24 && fitted[1] == 24 && fitted[2] == 0 && fitted[3] == 0);
    paint_rect(renderer, &r);
    for (int y = 0; y < 24; y++) for (int x = 0; x < 24; x++) {
        float d = hypotf(x + 0.5f - fitted[0], y + 0.5f - fitted[0]) - fitted[0];
        if (d <= -0.5f) expect(8 + x, 8 + y, 0xffff0000);
        else if (d >= 0.5f) expect(8 + x, 8 + y, 0xff0000ff);
        else if (fabsf(d) < 0.4f) ramp(8 + x, 8 + y);
    }
    finish(f);
}

static void border_ring(void) {
    struct fixture f = begin(blue);
    struct paint_rect_params r = {.box = {8,8,48,48}, .color = red,
        .radii = {16,16,16,16}, .cutout = {12,12,40,40}, .cutout_radii = {12,12,12,12}};
    paint_rect(renderer, &r);
    expect(32, 32, 0xff0000ff);
    expect(10, 32, 0xffff0000);
    expect(14, 14, 0xffff0000);
    expect(18, 18, 0xff0000ff);
    ramp(15, 15);
    finish(f);
}

static void texture_backing_shared_arc(void) {
    struct paint_texture *t = solid();
    struct paint_texture_params q = texture_params(t);
    q.dst = (struct paint_box){8, 8, 48, 48};
    q.clips_len = 2;
    q.clips[0] = (struct paint_clip){{8, 8, 48, 48}, {16, 16, 16, 16}};
    q.clips[1] = q.clips[0];
    q.background_clips = 1;
    q.surface_alpha = 1;
    struct fixture f = begin(blue);
    paint_texture(renderer, &q);
    uint32_t baseline[64 * 64];
    assert(paint_readback(renderer, (struct paint_box){0, 0, 64, 64}, 64 * 4, baseline));
    q.background = (struct paint_color){0, 1, 0, 1};
    paint_clear(renderer, blue);
    paint_texture(renderer, &q);
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++)
        expect(x, y, baseline[y * 64 + x]);

    for (int i = 0; i < 4; i++) q.clips[1].radii[i] = 22;
    paint_clear(renderer, blue);
    paint_texture(renderer, &q);
    expect(12, 14, 0xff00ff00);
    expect(32, 32, 0xffff0000);
    q.background = transparent;
    paint_clear(renderer, blue);
    paint_texture(renderer, &q);
    expect(12, 14, 0xff0000ff);
    finish(f);
    paint_texture_destroy(t);
}

static void texture_backing_alpha(void) {
    uint32_t half_red = 0x80800000;
    struct paint_texture *t = paint_texture_upload(renderer, 1, 1, 4, &half_red);
    assert(t);
    struct paint_texture_params q = {.texture = t, .dst = {0, 0, 64, 64},
        .src = {0, 0, 1, 1}, .alpha = .5f, .surface_alpha = .5f,
        .background = {0, 1, 0, 1}};
    struct fixture f = begin(transparent);
    paint_texture(renderer, &q);
    expect(32, 32, 0x80206000);
    finish(f);
    paint_texture_destroy(t);
}

static void texture_under_one_clip(void) {
    struct fixture f = begin(blue);
    struct paint_texture *t = solid();
    struct paint_texture_params q = texture_params(t);
    q.clips_len = 1;
    q.clips[0] = (struct paint_clip){{8,8,48,48}, {16,16,16,16}};
    paint_texture(renderer, &q);
    expect(10,10,0xff0000ff);
    expect(32,32,0xffff0000);
    ramp(12,12);
    paint_texture_destroy(t);
    finish(f);
}

static void texture_under_two_clips(void) {
    struct fixture f = begin(blue);
    struct paint_texture *t = solid();
    struct paint_texture_params q = texture_params(t);
    q.clips_len = 2;
    q.clips[0] = (struct paint_clip){{8,8,48,48}, {16,16,16,16}};
    q.clips[1] = (struct paint_clip){{20,8,40,40}, {16,16,16,16}};
    paint_texture(renderer, &q);
    expect(10,10,0xff0000ff);
    expect(22,10,0xff0000ff);
    expect(32,32,0xffff0000);
    expect(32,50,0xff0000ff);
    paint_texture_destroy(t);
    finish(f);
}

static void texture_under_circle_mask(void) {
    struct fixture f = begin(blue);
    unsigned char disc[32][37];
    memset(disc, 0, sizeof(disc));
    for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++)
        disc[y][x] = hypotf(x + 0.5f - 16, y + 0.5f - 16) < 12 ? 255 : 0;
    struct paint_mask *mask = paint_mask_upload(renderer,32,32,37,disc);
    assert(mask);
    struct paint_texture *t = solid();
    struct paint_texture_params q = texture_params(t);
    q.dst = (struct paint_box){8,8,48,48};
    q.mask = mask;
    q.mask_box = (struct paint_box){19,13,32,32};
    paint_texture(renderer, &q);
    expect(35,29,0xffff0000);
    expect(20,14,0xff0000ff);
    expect(23,29,0xffff0000);
    expect(20,29,0xff0000ff);
    expect(10,29,0xff0000ff);
    paint_clear(renderer,blue);
    struct paint_rect_params r={.box={8,8,48,48},.color=red,.mask=mask,
        .mask_box={19,13,32,32}};
    paint_rect(renderer,&r);
    expect(35,29,0xffff0000);
    expect(20,14,0xff0000ff);
    expect(10,29,0xff0000ff);
    paint_mask_destroy(mask);
    paint_texture_destroy(t);
    finish(f);
}

static void rect_under_mask_and_rounded_clip(void) {
    struct fixture f = begin(transparent);
    unsigned char disc[64][64];
    for (int y=0;y<64;y++) for (int x=0;x<64;x++)
        disc[y][x] = hypotf(x+.5f-32,y+.5f-32) < 30 ? 255 : 0;
    struct paint_mask *mask = paint_mask_upload(renderer,64,64,64,disc);
    assert(mask);
    struct paint_rect_params r = {.box={0,0,64,64}, .color=red,
        .mask=mask, .mask_box={0,0,64,64}, .clips_len=1,
        .clips={{{16,0,48,64},{24,24,24,24}}}};
    paint_rect(renderer,&r);
    expect(32,32,0xffff0000);
    expect(20,8,0);
    expect(61,15,0);
    paint_mask_destroy(mask);
    finish(f);
}

static void shared_mask_box(void) {
    struct fixture f = begin(transparent);
    unsigned char bytes[32][64];
    for (int y=0;y<32;y++) for (int x=0;x<64;x++) bytes[y][x] = y >= 16 ? 255 : 0;
    struct paint_mask *mask = paint_mask_upload(renderer,64,32,64,bytes);
    assert(mask);
    struct paint_rect_params r = {.box={4,8,20,32}, .color=red,
        .mask=mask, .mask_box={0,8,64,32}};
    paint_rect(renderer,&r);
    r.box.x=36;
    paint_rect(renderer,&r);
    expect(10,10,0); expect(40,10,0);
    expect(10,30,0xffff0000); expect(40,30,0xffff0000);
    paint_mask_destroy(mask);
    finish(f);
}

static void mask_straddling_box(void) {
    struct fixture f = begin(transparent);
    unsigned char bytes[16][16];
    memset(bytes,255,sizeof(bytes));
    struct paint_mask *mask = paint_mask_upload(renderer,16,16,16,bytes);
    assert(mask);
    struct paint_rect_params r = {.box={4,16,28,16}, .color=red,
        .mask=mask, .mask_box={16,16,16,16}};
    paint_rect(renderer,&r);
    expect(10,24,0); expect(20,24,0xffff0000);
    paint_mask_destroy(mask);
    finish(f);
}

/* Rotate centered coordinates, then reflect the destination x coordinate.
 * This computes source sampling independently of the library's point switch. */
static void source_point(float *x, float *y, int transform) {
    float a = *x - 0.5f, b = *y - 0.5f;
    for (int i = 0; i < (transform & 3); i++) {
        float old = a;
        a = -b;
        b = old;
    }
    if (transform & 4) a = -a;
    *x = a + 0.5f;
    *y = b + 0.5f;
}

static void texture_source_box_and_transform(void) {
    const uint32_t colors[4] = {0xffff0000,0xff00ff00,0xff0000ff,0xffffff00};
    struct paint_texture *t = paint_texture_upload(renderer,2,2,8,colors);
    assert(t);
    for (int transform = 0; transform < 8; transform++) {
        struct fixture f = begin(transparent);
        struct paint_texture_params q = {.texture=t, .dst={8,12,40,32},
            .src={0,0,2,2}, .transform=transform, .alpha=1, .nearest=true};
        paint_texture(renderer, &q);
        for (int y = 0; y < 2; y++) for (int x = 0; x < 2; x++) {
            float u = (x + 0.5f) / 2, v = (y + 0.5f) / 2;
            source_point(&u, &v, transform);
            expect(18 + 20*x,20 + 16*y,colors[(int)(v * 2)*2 + (int)(u * 2)]);
        }
        expect(7,20,0);
        expect(48,20,0);
        q.dst = (struct paint_box){8,48,40,8};
        q.src = (struct paint_box){1,0,1,2};
        paint_texture(renderer, &q);
        for (int y = 0; y < 2; y++) for (int x = 0; x < 2; x++) {
            float u = (x + 0.5f) / 2, v = (y + 0.5f) / 2;
            source_point(&u, &v, transform);
            expect(18 + 20*x,50 + 4*y,colors[(int)(v * 2)*2 + 1]);
        }
        finish(f);
    }
    paint_texture_destroy(t);
}

static void texture_import(void) {
    struct fixture f = begin(blue);
    GLuint id;
    unsigned char rgba[] = {128,0,0,128};
    glGenTextures(1,&id);
    glBindTexture(GL_TEXTURE_2D,id);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,1,1,0,GL_RGBA,GL_UNSIGNED_BYTE,rgba);
    struct paint_texture *t = paint_texture_import(renderer,id,GL_TEXTURE_2D,1,1,true);
    assert(t);
    struct paint_texture_params q = {.texture=t,.dst={8,8,16,16},.src={0,0,1,1},.alpha=0.5f};
    paint_texture(renderer,&q);
    expect(12,12,0xff4000bf);
    paint_texture_destroy(t);
    t = paint_texture_import(renderer,id,GL_TEXTURE_2D,1,1,false);
    assert(t);
    q.texture = t;
    q.dst.x = 32;
    paint_texture(renderer,&q);
    expect(36,12,0xff400080);
    paint_texture_destroy(t);
    glDeleteTextures(1,&id);
    finish(f);
}

static void shadow_falloff(void) {
    struct fixture f = begin(transparent);
    struct paint_shadow_params s = {.box={16,16,32,32},.blur=8,.color=red};
    paint_shadow(renderer,&s);
    int previous = 255;
    for (int x = 47; x <= 57; x++) {
        int a = pixel(x,32) >> 24;
        assert(a <= previous);
        previous = a;
    }
    assert((pixel(49,32) >> 24) > 0);
    expect(57,32,0);
    assert((pixel(51,51) >> 24) < (pixel(51,32) >> 24));
    expect(54,54,0);
    uint32_t original = pixel(49,32);
    paint_clear(renderer,transparent);
    s.offset_x=5;
    s.offset_y=3;
    paint_shadow(renderer,&s);
    expect_value(pixel(54,35),original,54,35);
    expect(52,35,0xffff0000);
    expect(8,32,0);
    paint_clear(renderer,transparent);
    s = (struct paint_shadow_params){.box={16,16,32,32}, .blur=0, .spread=4,
        .radii={8,12,16,4}, .color=red, .clips_len=1,
        .clips={{{8,8,48,48},{16,16,16,16}}}};
    paint_shadow(renderer,&s);
    expect(12,32,0xffff0000);
    expect(11,32,0);
    expect(13,13,0);
    expect(32,32,0xffff0000);
    expect(51,51,0);
    finish(f);
}

static void fractional_edge(void) {
    struct fixture f = begin(transparent);
    struct paint_rect_params r = {.box={10.5f,8,20,40},.color=red};
    paint_rect(renderer,&r);
    expect(10,24,0x80800000);
    expect(30,24,0x80800000);
    expect(9,24,0);
    expect(31,24,0);
    for (int x=11;x<30;x++) expect(x,24,0xffff0000);
    finish(f);
}

static void output_transform(void) {
    for (int transform=0;transform<8;transform++) {
        struct fixture f = begin_size(80,64,blue,transform);
        int lw = transform & 1 ? 64 : 80, lh = transform & 1 ? 80 : 64;
        struct paint_rect_params r = {.box={0,0,16,24},.color=red};
        paint_rect(renderer,&r);
        for (int y=0;y<64;y++) for (int x=0;x<80;x++) {
            float u=(x+0.5f)/80, v=(y+0.5f)/64;
            source_point(&u,&v,transform);
            expect(x,y,u*lw<16 && v*lh<24 ? 0xffff0000 : 0xff0000ff);
        }
        finish(f);
    }
}

static void damage_scissor(void) {
    struct fixture f=begin(blue);
    assert(paint_end(renderer));
    struct paint_box damage[]={{4,8,12,24},{40,8,16,24}};
    assert(paint_begin(renderer,f.fbo,64,64,0,damage,2));
    paint_clear(renderer,transparent);
    struct paint_rect_params r={.box={0,0,64,64},.color={0.5f,0,0,0.5f}};
    paint_rect(renderer,&r);
    for (int y=0;y<64;y++) for (int x=0;x<64;x++) {
        bool damaged=y>=8 && y<32 && ((x>=4 && x<16)||(x>=40 && x<56));
        expect(x,y,damaged ? 0x80800000 : 0xff0000ff);
    }
    finish(f);
}

static void readback_roundtrip(void) {
    struct fixture f=begin(transparent);
    uint32_t src[16][19], dst[16][21];
    memset(src,0x42,sizeof(src));
    memset(dst,0x23,sizeof(dst));
    for (int y=0;y<16;y++) for (int x=0;x<16;x++)
        src[y][x]=0x80000000u | (uint32_t)(x*8)<<16 | (uint32_t)(y*8)<<8 | (uint32_t)(x+y)*4;
    struct paint_texture *t=paint_texture_upload(renderer,16,16,sizeof(src[0]),src);
    assert(t);
    struct paint_texture_params q={.texture=t,.dst={7,11,16,16},.src={0,0,16,16},.alpha=1};
    paint_texture(renderer,&q);
    assert(paint_readback(renderer,(struct paint_box){7,11,16,16},sizeof(dst[0]),dst));
    for (int y=0;y<16;y++) {
        for (int x=0;x<16;x++) expect_value(dst[y][x],src[y][x],x,y);
        for (int x=16;x<21;x++) assert(dst[y][x]==0x23232323);
    }
    paint_texture_destroy(t);
    finish(f);
}

static void target_readback(void) {
    struct fixture f = begin(transparent);
    struct paint_rect_params r = {.box = {8, 8, 16, 16}, .color = red};
    paint_rect(renderer, &r);
    assert(paint_end(renderer));
    uint32_t pixels[64][64];
    assert(paint_readback(renderer, (struct paint_box){0, 0, 64, 64},
        sizeof(pixels[0]), pixels));
    for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++)
        assert(pixels[y][x] == (x >= 8 && x < 24 && y >= 8 && y < 24
            ? 0xffff0000u : 0));
    paint_target_destroy(f.target);
}

static void end_reports_errors(void) {
    struct fixture f=begin(blue);
    expect(1,1,0xff0000ff);
    glEnable(0xffffffffu);
    assert(!paint_end(renderer));
    assert(paint_begin(renderer,f.fbo,64,64,0,NULL,0));
    expect(1,1,0xff0000ff);
    finish(f);
}

int main(void) {
    setvbuf(stdout,NULL,_IONBF,0);
    if (!init_context()) return 77;
    renderer=paint_create();
    assert(renderer);
#define RUN(fn) do { case_name=#fn; fn(); printf("PASS %s\n",case_name); } while (0)
    RUN(rect_square_corners);
    RUN(rect_rounded_corners);
    RUN(rect_fit_radii);
    RUN(border_ring);
    RUN(texture_backing_shared_arc);
    RUN(texture_backing_alpha);
    RUN(texture_under_one_clip);
    RUN(texture_under_two_clips);
    RUN(texture_under_circle_mask);
    RUN(rect_under_mask_and_rounded_clip);
    RUN(shared_mask_box);
    RUN(mask_straddling_box);
    RUN(texture_source_box_and_transform);
    RUN(texture_import);
    RUN(shadow_falloff);
    RUN(fractional_edge);
    RUN(output_transform);
    RUN(damage_scissor);
    RUN(readback_roundtrip);
    RUN(target_readback);
    RUN(end_reports_errors);
#undef RUN
    paint_destroy(renderer);
    finish_context();
    return 0;
}
