# Jotto brand

Logo v1 and colour v1, decided 2026-10-31. Design boards: Paper file "jotto", page "Brand".

| Path | What |
|------|------|
| `logo/final/` | Final art. Use these files, not anything in `logo/out/` (explorations). |
| `color/tokens.json`, `color/tokens.css` | Colour scales and roles, light and dark |
| `elements/out/` | Isometric illustrations for the site, empty states, onboarding |

## Regenerate

```sh
python3 -m venv --system-site-packages brand/.venv && brand/.venv/bin/pip install -r brand/requirements.txt
brand/.venv/bin/python brand/logo/final.py   # wordmarks, app icons, favicons
python3 -I brand/color/build.py              # colour tokens, with a contrast check
node brand/elements/build.mjs --dark         # illustrations (needs the anatomy skill kit)
```

## Apps

Already wired in `apple/Apps/{iOS,Watch}/Assets.xcassets`:

- `AppIcon`: `icon-ios-1024.png` / `icon-watch-1024.png`, opaque, full bleed. The system applies the mask.
- `AccentColor`: iOS `#D03B00` light / `#FF4F00` dark (it tints text, so light mode uses the readable orange); watch `#FF4F00`.
- `BrandOrange`: `#FF4F00` everywhere. For fills that mean "live": the record button, the recording badge.

After replacing an icon in `logo/final/`, copy it into the asset catalogs again.

## Website

```html
<link rel="icon" href="/favicon.ico" sizes="32x32">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<meta name="theme-color" content="#FFFFFF" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0A0A0A" media="(prefers-color-scheme: dark)">
```

Copy `favicon.ico`, `favicon.svg` and `apple-touch-icon.png` from `logo/final/` to the site root, and import `color/tokens.css`. Wordmark: `wordmark.svg` on light, `wordmark-dark.svg` on dark (its `aria-label` is "jotto").

## Colour rules

- Orange means live or "do this": the dot, the record button, the one primary action. One orange thing per screen.
- Text in orange: `--accent-text` (orange-600 on light, 500 on dark). Large text (24px, or 19px bold, and up) may use `--accent-text-large`, the brand orange.
- Transcripts stay in the ink steps; status colours (error, warning, success) come from the platform.
