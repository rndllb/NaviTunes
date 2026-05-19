# Lyra home screen icons (iOS 26)

Lyra can change the **logo color** from Settings → Accent, and iOS can change the **background** from system Light/Dark. Those are two separate mechanisms.

## How it works

| What changes | Mechanism | Who implements |
|--------------|-----------|----------------|
| Logo / accent color | Alternate app icon per preset | You ship `LyraIcon-*` assets; app calls `setAlternateIconName` |
| Background light vs dark | **Any** vs **Dark** appearance in each icon set | You ship two backgrounds per icon; **iOS switches automatically** (no Swift when user changes system appearance) |
| Home screen Tinted style | Optional **Tinted** grayscale slot | Optional asset; system tint from wallpaper |

**Default accent (`red`)** uses the primary **`AppIcon`** set (no alternate swap).

**All other accents** use alternate sets named exactly:

- `LyraIcon-pink`
- `LyraIcon-orange`
- `LyraIcon-yellow`
- `LyraIcon-green`
- `LyraIcon-teal`
- `LyraIcon-blue`
- `LyraIcon-indigo`
- `LyraIcon-purple`
- `LyraIcon-lightgray`

Code: `AppAlternateIconSync.swift` + `AppModel.syncHomeScreenIconForAccent()`.

Accent hex values: see earlier handoff or `AppAccentPreset` in `MusicDesignSystem.swift`.

---

## Xcode setup (LyraMusicHost target)

1. Add **`Assets.xcassets`** to `LyraMusicHost` if missing.
2. **Primary icon:** `AppIcon` — red logo (default accent), with **Any** + **Dark** appearances.
3. For each non-red accent, add an **iOS App Icon** set named `LyraIcon-{id}` (names above).
4. In each set (Attributes inspector):
   - **Platforms:** iOS
   - **iOS:** Single Size (1024) recommended
   - **Appearance:** add **Dark**
5. **Any (light):** light/neutral background plate + logo in that accent color.
6. **Dark:** dark background plate + **same** logo color (usually same hex as Any).
7. Build setting **Alternate App Icon Sets** is already set in `project.pbxproj` for the nine non-red icons.

### iOS 26 layered icons (recommended)

Use **Icon Composer** (Xcode 26): **File → New → App Icon**

- **Background layer:** light material / color for Any; darker background layer variant for Dark.
- **Foreground layer:** logo mark only (no baked shadow); tint/logo color = accent hex.
- Export `.icon` into the catalog or generate single-size PNGs per appearance.

Apple will composite layers with lighting on the Home Screen. See [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

### Flat PNG shortcut

One **1024×1024** per appearance per accent is enough if using Single Size:

- `LyraIcon-blue` → Any: light gray/white bg + blue logo  
- `LyraIcon-blue` → Dark: `#1C1C1E`-style bg + same blue logo  

---

## What you cannot do

- Tint the home screen icon from `MusicDesign.accent` at runtime without bundled art.
- Use in-app Light/Dark theme alone to change the icon — only **system** Light/Dark (asset **Dark** slot) or user Home Screen **Customize → Dark/Tinted**.

---

## Test on device

1. Build **LyraMusicHost** on a **physical iPhone** (simulator alternate icons are flaky).
2. Settings → Appearance → Accent → pick **Blue** → home screen icon should switch to `LyraIcon-blue` (brief system animation).
3. iOS **Settings → Display → Dark** → icon background should switch to the **Dark** slot without reopening Lyra.
4. Pick **Red** → icon returns to primary `AppIcon`.

If nothing changes, the matching `LyraIcon-*` set is missing from the asset catalog or misnamed.

## Icon Composer `.icon` files (current LyraMusicHost layout)

Icons live in `LyraMusicHost/LyraMusicHost/AppIcons/`:

| File | Role |
|------|------|
| `AppIcon.icon` | Default (red accent) |
| `LyraIcon-*.icon` | One per non-red accent |

**Spelling:** use `LyraIcon-lightgray` (American **gray**), not `lightgrey`.

Build settings: **App Icon Set Name** = `AppIcon`, **Include All App Icon Assets** = Yes, alternates listed in **Alternate App Icon Sets**.

`Info.plist` includes `CFBundleAlternateIcons` entries (required for `setAlternateIconName` with Icon Composer on some Xcode 26 builds).
