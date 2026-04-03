# Lockscreen Background Image Support

**Branch:** `feat/lockscreen-bg-image`
**Status:** Hotové, testováno v nested sandbox

## Co bylo přidáno

Podpora pozadí obrázku pro lockscreen modul. Tapeta se zobrazuje pod
poloprůhledným overlayem s UI (hodiny, datum, heslo).

### Nové theme properties

```lua
-- v theme.lua:
theme.lockscreen_bg_image = "/path/to/wallpaper.jpg"
theme.lockscreen_bg_image_overlay = "#000000aa"  -- výchozí 67% černý overlay
```

Nebo přímo v `lockscreen.init()`:
```lua
require("lockscreen").init({
    bg_image = "/path/to/wallpaper.jpg",
    bg_image_overlay = "#000000bb",
})
```

### Jak to funguje

1. **Imagebox** (`wibox.widget.imagebox`) zobrazí tapetu jako base vrstvu
2. **Stack layout** (`wibox.layout.stack`) vrství: tapeta → overlay → UI
3. **Overlay** je `wibox.container.background` s poloprůhlednou barvou
4. **Wibox bg** nastaveno na `#00000000` (průhledné) když je tapeta aktivní

```
┌──────────────────────────┐
│  imagebox (wallpaper)    │  ← base layer
│  ┌────────────────────┐  │
│  │  overlay (#000000aa)│  │  ← dimming layer
│  │  ┌──────────────┐  │  │
│  │  │  clock/pass  │  │  │  ← UI on top
│  │  └──────────────┘  │  │
│  └────────────────────┘  │
└──────────────────────────┘
```

Multi-monitor: cover wiboxes (neinteraktivní obrazovky) dostávají stejnou
tapetu s overlayem přes `build_cover_layout()`.

## Bug fix: Lua `pairs()` a `nil` klíče

Hlavní bug — v tabulce `defaults` byly:
```lua
bg_image    = nil,
lock_screen = nil,
```

Lua `pairs()` **přeskakuje klíče s hodnotou `nil`** — klíč v tabulce
s `nil` hodnotou je ekvivalentní neexistujícímu klíči. Konfigurační
smyčka tedy nikdy nenavštívila `bg_image` a `beautiful.lockscreen_bg_image`
se nikdy nenačetlo.

**Fix:** Změna `nil` → `false`. `false` je falsy (funguje v `if` checks),
ale `pairs()` ho iteruje.

## Změněné soubory

| Soubor | Změna |
|--------|-------|
| `lua/lockscreen.lua` | bg_image/bg_image_overlay podpora, pairs() bugfix |
| `plans/somewm-one/themes/default/theme.lua` | `lockscreen_bg_image` pro tapetu z tagu 1 |

## Upstream relevance

`lua/lockscreen.lua` je čistě upstream kód — změna je plně zpětně kompatibilní.
Bez `lockscreen_bg_image` se lockscreen chová identicky jako předtím.

Pro upstream PR by stačil pouze `lua/lockscreen.lua` (ne theme.lua z somewm-one).

## Testování

Testováno v nested compositor sandbox (`WLR_BACKENDS=wayland`).
JPEG tapeta (906 KB) se správně načítá přes `gears.surface.load_uncached_silently()`.
