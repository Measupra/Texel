# Texel

On-device image upscaler for **Mac, iPhone and iPad**. Enlarge photos up to **8×** with AI that runs entirely on your device: no uploads, no accounts, no tracking.

## Features

- **AI upscaling** with three Real-ESRGAN models running on the Neural Engine and GPU through Core ML:
  - **Photo**: best quality for photos; rebuilds texture and removes JPEG noise.
  - **General**: several times faster, with medium denoising.
  - **Anime & art**: keeps flat colours and clean line art.
- **Up to 8×.** Above 4×, the AI runs a second pass instead of stretching the result.
- **Low-res detection.** Photos that were enlarged before are shrunk back to their real resolution and rebuilt from there.
- **Finishing controls:** Detail, Smooth and Sharp sliders that update instantly without re-running the AI.
- **Classic mode:** non-AI GPU upscaling with Metal shaders (FidelityFX FSR 1 EASU, detail refinement, RCAS sharpening).
- **Before/after compare** with a draggable divider, pinch or scroll zoom, and pan.
- Save to Photos, or export PNG, HEIC or JPEG.

## Requirements

- Xcode 16 or later (full Xcode, not just the Command Line Tools)
- macOS 14+ for the Mac app; iOS 17+ for iPhone and iPad

## Build

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). The scripts download it automatically.

**Mac app:**

```
bash build-mac.sh
open Texel.app
```

Or double-click `Rebuild Texel.command`.

**iPhone / iPad:**

```
bash build-ipa.sh
```

This creates `TexelPhone.xcodeproj`. Open it, select the **TexelPhone** scheme, set your team under Signing & Capabilities, plug in your device, and press Run.

**App Store** (needs a paid Apple Developer account):

```
UPLOAD=1 bash build-appstore.sh
```

This archives both apps under one bundle ID (Universal Purchase) and uploads them to App Store Connect.

## Project layout

| Path | What it is |
|---|---|
| `App/` | The SwiftUI interface shared by Mac and iPhone, plus the platform canvases |
| `Shared/` | The engines: Core ML AI upscaler, Metal compute pipeline, image I/O |
| `Models/` | The three Real-ESRGAN models in Core ML format |
| `Mac/` | Mac Info.plist and sandbox entitlements |
| `project.yml` | XcodeGen spec for the TexelPhone (iOS) and TexelMac (macOS) targets |

## Credits

The AI models are converted from [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) by Xintao Wang et al. and are distributed under the BSD 3-Clause License; see `Models/LICENSE-Real-ESRGAN.txt`. Classic mode includes a port of AMD FidelityFX Super Resolution 1 (EASU and RCAS).
