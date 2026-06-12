# LCARS favicon — integration

**Date** : 2026-04-21
**Dernière révision** : 2026-04-21
**Statut** : actif — sources SVG/PNG/ICO pour branding Gitea LCARS
**Référencé par** : `fleet/tooling/gitea-fleet-config.sh --doc` (procédure install)

## Two variants

- **`favicon-minimal.*`** — coude orange pur. Optimal à 16/32 px (onglet).
- **`favicon.*`** — coude + 2 pills d'accent (lavande + sand) dans l'espace intérieur. Rend mieux à 64 px et au-dessus.

## HTML head recommandé

```html
<!-- Onglet navigateur (multi-taille ICO) -->
<link rel="icon" href="/favicon-minimal.ico" sizes="any">

<!-- SVG natif (Chrome/Firefox/Edge modernes, scaling parfait) -->
<link rel="icon" type="image/svg+xml" href="/favicon-minimal.svg">

<!-- Apple touch icon (180x180 standard) -->
<link rel="apple-touch-icon" href="/favicon-180.png">

<!-- Web app manifest (PWA) -->
<link rel="manifest" href="/manifest.webmanifest">
```

## manifest.webmanifest

```json
{
  "name": "LCARS",
  "short_name": "LCARS",
  "icons": [
    { "src": "/favicon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/favicon-512.png", "sizes": "512x512", "type": "image/png" }
  ],
  "theme_color": "#FF9900",
  "background_color": "#0a0a0a",
  "display": "standalone"
}
```

## Tailles fournies

| Fichier | Usage |
|---|---|
| `favicon-minimal.ico` | `<link rel="icon">` principal (multi-taille 16/32/48/64) |
| `favicon-minimal.svg` | SVG natif browser moderne |
| `favicon-16.png` / `favicon-32.png` | Legacy explicite |
| `favicon-48.png` | Windows taskbar |
| `favicon-64.png` | Fine-tuned tab rendering |
| `favicon-180.png` | Apple touch icon |
| `favicon-192.png` / `favicon-512.png` | PWA manifest |
