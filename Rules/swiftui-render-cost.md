# Rendering cost on scroll paths

Applies to all Swift UI code in `Sources/VellumMusicKit/`. Read together with
`Rules/swiftui-body-cost.md`.

## Lazy containers are the default

Any `ForEach` that can exceed one screenful goes in `LazyVStack` / `LazyHStack` /
`LazyVGrid` — never `VStack` / `HStack`. A plain stack builds every row up front, including
artwork, context menus and swipe actions. This applies to horizontal shelves too: a plugin
discography can be 100+ cards.

Very long lists need a render window on top of laziness — see `rowRenderLimit` +
`extendRowRenderWindow` in `ServerPlaylistViews`. If you add a second rendering path to a
list that already has a window, that path needs the window too.

## No live blur or mask on anything that scrolls

A live `.blur(radius:)` re-runs every frame of **every** animation, including unrelated ones
(the mini player opening was re-blurring the artist hero). Pre-rasterize instead:

```swift
// ❌ re-blurs on every frame
image.resizable().scaledToFill().blur(radius: 30)

// ✅ blur once into a CGImage, then composite
ArtworkGaussianBlur.cgImage(from: source, radius: radius)
```

Use `ArtworkGaussianBlur` for artwork washes, or flatten a small blurred subtree with
`.drawingGroup()` (see `HomeTopPickArtworkBleed`).

Prefer `.clipShape` over `.mask` — a mask allocates an offscreen alpha composite per
instance, which is expensive when dozens are on screen at once.

## Artwork

Always go through `AlbumArtworkView`. It resolves `DecodedArtworkCache` **synchronously** so
cached art paints immediately with no placeholder; only genuine network loads shimmer and
fade in. Pass a `maxDecodePixels` that matches the displayed size — don't decode a 768px
bitmap for a 56px row.

Loading placeholders (`MusicShimmerSurface`) animate forever while mounted, so they must
never appear for art that is already cached.
