# jotto brand

Logo v1 and colour v1, decided 2026-10-31. Design boards: Paper file "jotto", page "Brand".

| Path | What |
|------|------|
| `logo/final/` | Final art. Use these files, not anything in `logo/out/` (explorations). |
| `color/tokens.json`, `color/tokens.css` | Colour scales and roles, light and dark |
| `page/index.html` | Prototype of the neethan.com/jotto project page: tap the dot, gadgets you don't need, a day on the wrist; WebGL particles. Objects come from `page/build.mjs` (anatomy kit) → `page/art.js`, `page/iso.css`. Serve `brand/` and open `/page/`. |
| `elements/out/` | Isometric illustrations for the site, empty states, onboarding |

## Regenerate

```sh
python3 -m venv --system-site-packages brand/.venv && brand/.venv/bin/pip install -r brand/requirements.txt
brand/.venv/bin/python brand/logo/final.py   # wordmarks, app icons, favicons
python3 -I brand/color/build.py              # colour tokens, with a contrast check
node brand/elements/build.mjs --dark         # illustrations (needs the anatomy skill kit)
node brand/page/build.mjs                    # project-page objects (needs the anatomy skill kit)
```

## Apps

Already wired in `apple/Apps/`:

- iOS icon: `apple/Apps/iOS/AppIcon.icon`, a copy of `logo/final/AppIcon.icon` (Icon Composer format). The system renders Liquid Glass and the dark, tinted and clear looks from it; previews in `logo/out/liquid/`. In dark the ground goes ink, the dot takes the orange and the bar turns white.
- Watch icon: `AppIcon.appiconset` with `icon-watch-1024.png`, opaque, full bleed; watchOS crops it to a circle.
- `AccentColor`: iOS `#D03B00` light / `#FF4F00` dark (it tints text, so light mode uses the readable orange); watch `#FF4F00`.
- `BrandOrange`: `#FF4F00` everywhere. For fills that mean "live": the record button, the recording badge.

After regenerating, copy `AppIcon.icon` and `icon-watch-1024.png` into the apps again.

## Product page

There is no standalone site. jotto gets one page at `neethan.com/jotto`, which
must look like jotto, not like the rest of neethan.com: scope its styles to the
page and use only the tokens here.

```html
<link rel="icon" href="/jotto/favicon.ico" sizes="32x32">
<link rel="icon" href="/jotto/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/jotto/apple-touch-icon.png">
<meta name="theme-color" content="#FFFFFF" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0A0A0A" media="(prefers-color-scheme: dark)">
```

Serve `favicon.ico`, `favicon.svg` and `apple-touch-icon.png` from `logo/final/`
under `/jotto/`, and import `color/tokens.css`. Wordmark: `wordmark.svg` on
light, `wordmark-dark.svg` on dark (its `aria-label` is "jotto").

## Colour rules

- Orange means live or "do this": the dot, the record button, the one primary action. One orange thing per screen.
- Text in orange: `--accent-text` (orange-600 on light, 500 on dark). Large text (24px, or 19px bold, and up) may use `--accent-text-large`, the brand orange.
- Transcripts stay in the ink steps; status colours (error, warning, success) come from the platform.
