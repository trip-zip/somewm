# Backdrop Blur for Layer Surfaces (SceneFX)

**Status:** Reverted (2026-04-04) — caused stuttering on NVIDIA RTX 5070 Ti
**Reason:** Performance issues, blur re-applied on every wlr surface commit

## Overview

Working implementation of SceneFX backdrop blur for layer-shell surfaces
(Quickshell panels). Blur was auto-enabled for all `somewm-shell:*` namespaces.

Quickshell does NOT have native backdrop blur — its panels are plain Wayland
layer-shell surfaces. Blur must come from the compositor side via SceneFX.

## Files Modified (4 files, ~80 lines)

### 1. `somewm_types.h` — LayerSurface struct

Added `bool backdrop_blur` field:

```c
typedef struct LayerSurface {
    // ... existing fields ...
    struct wl_listener surface_commit;

    /* SceneFX effects */
    bool backdrop_blur;            /* Backdrop blur enabled (requires scenefx) */

    /* Lua object reference */
    struct layer_surface_t *lua_object;
} LayerSurface;
```

### 2. `objects/layer_surface.c` — Blur functions + Lua property

Three additions after the opacity code (~line 134):

```c
/*
 * Backdrop blur support for layer surfaces (SceneFX)
 */

/** Recursively apply backdrop blur to all buffer nodes in a scene tree. */
static void
ls_apply_backdrop_blur_to_tree(struct wlr_scene_node *node, bool enabled)
{
#ifdef HAVE_SCENEFX
    if (node->type == WLR_SCENE_NODE_BUFFER) {
        struct wlr_scene_buffer *buf = wlr_scene_buffer_from_node(node);
        wlr_scene_buffer_set_backdrop_blur(buf, enabled);
        if (enabled) {
            wlr_scene_buffer_set_backdrop_blur_optimized(buf, true);
            wlr_scene_buffer_set_backdrop_blur_ignore_transparent(buf, true);
        }
    } else if (node->type == WLR_SCENE_NODE_TREE) {
        struct wlr_scene_tree *tree = wlr_scene_tree_from_node(node);
        struct wlr_scene_node *child, *tmp;
        wl_list_for_each_safe(child, tmp, &tree->children, link) {
            ls_apply_backdrop_blur_to_tree(child, enabled);
        }
    }
#else
    (void)node;
    (void)enabled;
#endif
}

void
layer_surface_apply_backdrop_blur(layer_surface_t *ls)
{
    if (!ls || !ls->ls || !ls->ls->scene)
        return;

    bool enabled = ls->ls->backdrop_blur;

    ls_apply_backdrop_blur_to_tree(&ls->ls->scene->node, enabled);

    /* Also apply to popup tree */
    if (ls->ls->popups)
        ls_apply_backdrop_blur_to_tree(&ls->ls->popups->node, enabled);
}

static int
luaA_layer_surface_get_backdrop_blur(lua_State *L, layer_surface_t *ls)
{
    lua_pushboolean(L, ls->ls ? ls->ls->backdrop_blur : false);
    return 1;
}

static int
luaA_layer_surface_set_backdrop_blur(lua_State *L, layer_surface_t *ls)
{
    bool enabled = luaA_checkboolean(L, -1);
    if (ls->ls) {
        ls->ls->backdrop_blur = enabled;
        layer_surface_apply_backdrop_blur(ls);
    }
    luaA_object_push(L, ls);
    luaA_object_emit_signal(L, -1, "property::backdrop_blur", 0);
    lua_pop(L, 1);
    return 0;
}
```

Property registration in `layer_surface_class_setup()` (~line 721):

```c
luaA_class_add_property(&layer_surface_class, "backdrop_blur",
                        (lua_class_propfunc_t) luaA_layer_surface_set_backdrop_blur,
                        (lua_class_propfunc_t) luaA_layer_surface_get_backdrop_blur,
                        (lua_class_propfunc_t) luaA_layer_surface_set_backdrop_blur);
```

### 3. `objects/layer_surface.h` — Declaration

```c
void layer_surface_apply_backdrop_blur(layer_surface_t *ls);
```

### 4. `somewm.c` — Two changes

**a) Auto-enable in `createlayersurface()` (~line 1820):**

```c
/* Auto-enable backdrop blur for somewm-shell layer surfaces */
if (layer_surface->namespace &&
        strncmp(layer_surface->namespace, "somewm-shell:", 13) == 0) {
    l->backdrop_blur = true;
}
```

**b) Re-apply in `commitlayersurfacenotify()` (after opacity re-apply ~line 1512):**

```c
/* Re-apply backdrop blur after wlroots resets buffer state on commit */
if (l->backdrop_blur)
    layer_surface_apply_backdrop_blur(ls);
```

## Design Pattern

Mirrors the existing opacity implementation exactly:
- `ls_apply_opacity_to_tree()` → `ls_apply_backdrop_blur_to_tree()`
- `layer_surface_apply_opacity_to_scene()` → `layer_surface_apply_backdrop_blur()`
- Re-apply on every commit (wlroots resets buffer state)
- Lua getter/setter with `property::backdrop_blur` signal
- `#ifdef HAVE_SCENEFX` guard for vanilla wlroots compat

## Why It Stuttered

The blur was re-applied on **every single surface commit** via
`commitlayersurfacenotify()`. Quickshell surfaces commit frequently
(animations, hover states, content updates). Each re-apply walks the
entire scene tree recursively calling `wlr_scene_buffer_set_backdrop_blur()`.

Possible optimizations for next attempt:
1. **Skip redundant re-apply** — only call when blur state actually changes
   (check if buffers already have blur set before re-applying)
2. **Debounce** — don't re-apply on every commit, use a dirty flag + timer
3. **Apply once at map time** — if wlroots doesn't actually reset blur on
   commit (unlike opacity), the re-apply loop may be unnecessary
4. **SceneFX blur_data tuning** — adjust blur radius/passes for performance
   (`wlr_scene_set_blur_data()` in somewm.c setup)
5. **Test without NVIDIA** — the stutter might be NVIDIA-specific (GPU reset,
   DRM format issues, Vulkan allocator overhead)

## Build Verification

Both builds compiled cleanly with the implementation:
```bash
ninja -C build      # ASAN dev build — OK
ninja -C build-fx   # SceneFX production build — OK
```

## Lua API (when re-enabled)

```lua
-- From rc.lua or somewm-client eval:
for _, ls in ipairs(layer_surface.get()) do
    if ls.namespace and ls.namespace:match("^somewm%-shell:") then
        ls.backdrop_blur = true
    end
end
```
