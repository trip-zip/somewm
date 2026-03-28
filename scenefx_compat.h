/*
 * scenefx_compat.h - Conditional include for wlroots scene graph
 *
 * When scenefx is available, use its extended scene API (rounded corners,
 * shadows, blur, opacity). Otherwise, fall back to vanilla wlroots scene API.
 * Both APIs are source-compatible — scenefx extends without replacing.
 */

#ifndef SCENEFX_COMPAT_H
#define SCENEFX_COMPAT_H

#ifdef HAVE_SCENEFX
#include <scenefx/types/wlr_scene.h>
#include <scenefx/render/fx_renderer/fx_renderer.h>
#else
#include <wlr/types/wlr_scene.h>
#endif

#endif /* SCENEFX_COMPAT_H */
