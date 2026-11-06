#ifndef PAINT_TEST_CONTEXT_H
#define PAINT_TEST_CONTEXT_H
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static EGLDisplay paint_test_display;
static EGLContext paint_test_context;
static bool extension(const char *list, const char *name) {
    if (!list) return false;
    size_t n = strlen(name);
    const char *s = list;
    while ((s = strstr(s, name))) {
        if ((s == list || s[-1] == ' ') && (s[n] == ' ' || !s[n])) return true;
        s += n;
    }
    return false;
}

static bool init_context(void) {
    PFNEGLQUERYDEVICESEXTPROC devices_fn = (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC string_fn = (PFNEGLQUERYDEVICESTRINGEXTPROC)eglGetProcAddress("eglQueryDeviceStringEXT");
    PFNEGLGETPLATFORMDISPLAYEXTPROC display_fn = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLint count = 0;
    if (!devices_fn || !string_fn || !display_fn || !devices_fn(0, NULL, &count) || count < 1) {
        fprintf(stderr, "SKIP: EGL device enumeration unavailable (0x%x)\n", eglGetError());
        return false;
    }
    EGLDeviceEXT *devices = calloc((size_t)count, sizeof(*devices));
    assert(devices);
    if (!devices_fn(count, devices, &count)) {
        free(devices);
        fprintf(stderr, "SKIP: EGL device enumeration failed (0x%x)\n", eglGetError());
        return false;
    }
    bool prefer_software = getenv("PAINT_TEST_SOFTWARE") != NULL;
    for (int pass = 0; pass < (prefer_software ? 2 : 1); pass++) {
        for (int i = 0; i < count; i++) {
            const char *ext = string_fn(devices[i], EGL_EXTENSIONS);
            bool software = extension(ext, "EGL_MESA_device_software");
            if (prefer_software && software != (pass == 0)) continue;
            EGLDisplay d = display_fn(EGL_PLATFORM_DEVICE_EXT, devices[i], NULL);
            if (d == EGL_NO_DISPLAY || !eglInitialize(d, NULL, NULL)) {
                fprintf(stderr, "EGL device %d: initialization failed (0x%x)\n", i, eglGetError());
                continue;
            }
            if (!extension(eglQueryString(d, EGL_EXTENSIONS), "EGL_KHR_surfaceless_context")) {
                fprintf(stderr, "EGL device %d: missing EGL_KHR_surfaceless_context\n", i);
                eglTerminate(d);
                continue;
            }
            const EGLint attrs[] = {EGL_SURFACE_TYPE, 0, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
            EGLConfig config;
            EGLint configs = 0;
            const EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
            if (!eglBindAPI(EGL_OPENGL_ES_API) ||
                    !eglChooseConfig(d, attrs, &config, 1, &configs) || configs == 0) {
                fprintf(stderr, "EGL device %d: no GLES2 config (0x%x)\n", i, eglGetError());
                eglTerminate(d);
                continue;
            }
            EGLContext ctx = eglCreateContext(d, config, EGL_NO_CONTEXT, ctx_attrs);
            if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
                fprintf(stderr, "EGL device %d: context failed (0x%x)\n", i, eglGetError());
                if (ctx != EGL_NO_CONTEXT) eglDestroyContext(d, ctx);
                eglTerminate(d);
                continue;
            }
            paint_test_display = d;
            paint_test_context = ctx;
            const char *node = extension(ext, "EGL_EXT_device_drm_render_node") ?
                string_fn(devices[i], EGL_DRM_RENDER_NODE_FILE_EXT) : NULL;
            printf("EGL device %d: %s, node %s\nGL_RENDERER: %s\nGL_VERSION: %s\n", i,
                software ? "EGL_MESA_device_software" : "hardware", node ? node : "none",
                glGetString(GL_RENDERER), glGetString(GL_VERSION));
            free(devices);
            return true;
        }
    }
    free(devices);
    fprintf(stderr, "SKIP: no EGL device supplies a surfaceless GLES2 context\n");
    return false;
}


static void finish_context(void) {
    eglMakeCurrent(paint_test_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(paint_test_display, paint_test_context);
    eglTerminate(paint_test_display);
    eglReleaseThread();
}
#endif
