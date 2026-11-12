<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="128" alt="Texel app icon">
</p>

<h1 align="center">Texel</h1>

<p align="center">
  <b>Small photo in. Stunning detail out.</b><br>
  On-device AI image upscaler for Mac, Windows, iPhone and iPad.
</p>

<p align="center">
  <a href="https://github.com/Measupra/Texel/releases/latest"><b>⬇ Download for Mac</b></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/Measupra/Texel/releases/latest"><b>⬇ Download for Windows</b></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/Measupra/Texel/releases/latest"><b>⬇ Download for iPhone</b></a>
</p>

Texel enlarges your photos up to **8×**, or cleans them up at the same size, with AI that runs entirely on your own device. No uploads, no accounts, no tracking.

## Install

### Mac

1. Download the **Mac .zip** file from the [latest release](https://github.com/Measupra/Texel/releases/latest).
2. Double-click it to unzip, and drag **Texel** into your **Applications** folder.
3. Open Texel.

If macOS says it can't verify Texel, go to **System Settings › Privacy & Security**, scroll down, click **Open Anyway** next to the message about Texel, and confirm. You only need to do this once.

Needs **macOS 14 Sonoma or later**. Works on Apple Silicon and Intel Macs.

### Windows

1. Download the **Windows .zip** file from the [latest release](https://github.com/Measupra/Texel/releases/latest).
2. Right-click it, choose **Extract All…**, and open the folder.
3. Double-click **Texel.exe**.

If Windows says "Windows protected your PC", click **More info**, then **Run anyway**. You only need to do this once.

Needs **Windows 10 or 11** (64-bit). A graphics card that supports DirectX 12 makes the AI much faster.

### iPhone and iPad

1. Download the **.ipa** file from the [latest release](https://github.com/Measupra/Texel/releases/latest) onto your computer.
2. Install a sideloading app such as [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io) on your Mac or PC.
3. Connect your iPhone or iPad, choose the .ipa file in the sideloading app, and sign in with your Apple ID when it asks.
4. On the device, go to **Settings › General › VPN & Device Management**, tap your Apple ID and choose **Trust**. If it asks for Developer Mode, turn that on under **Settings › Privacy & Security**.

With a free Apple ID the app stops opening after 7 days; install it again the same way to keep using it.

Needs **iOS 17 or iPadOS 17 or later**.

## How to use

1. Open an image, drag one onto the window, or paste one from the clipboard.
2. Click **Auto Fix**: Texel looks at the photo, works out what's wrong with it and picks the best settings for you.

   Or choose them yourself:
   - **Size:** **1×** keeps the size and just makes the image cleaner and sharper; **2× to 8×** enlarge it. The button next to the sizes fits the result to an exact size instead, such as **4K** or any number of pixels you type.
   - **Mode:** **AI** for the best results (**Photo**, **General** for speed, or **Anime** for drawings), or **Classic** for fast upscaling without AI.
3. Click **Upscale**.
4. Drag the divider to compare before and after. Scroll to zoom in.
5. Fine-tune the result. The sliders update instantly, without running the AI again.
6. Save it as PNG, JPEG, HEIC (Mac) or WebP (Windows), or copy it to paste into another app.

### Many images at once

1. Click **Batch** on the start screen and choose your images, or drag several onto the window together.
2. Pick the settings as usual, or turn on **Auto Fix each image** to let Texel choose for every image separately.
3. Click **Upscale**. Texel works through the list and saves each result into a **Texel** folder inside **Downloads** (you can change the folder). On iPhone and iPad they go to Photos.

## Features

- **AI upscaling** with three Real-ESRGAN models, running on your computer's graphics chip.
- **Auto Fix** detects blur, grain, JPEG blocks, pixelation, faces, and dark or dull lighting, then sets everything to suit. It goes gently on clean photos, so they keep their look.
- **Face restoration** redraws blurry faces with a dedicated face AI, with a strength slider so people still look like themselves.
- **Colour & light** automatically fixes exposure, contrast and colour, and adds clarity to texture like trees, hair and fabric.
- **Finishing sliders:**
  - **AI** blends the AI result with a plain enlargement, for a more natural look.
  - **Detail** adds back the original's fine texture.
  - **Smooth** evens out noise and blockiness.
  - **Sharp** sharpens edges.
- **Batch** upscales a whole set of images in one go and saves them for you.
- **Fit to a size:** aim for Full HD, 4K, 8K or a custom size instead of a plain 2× or 4×.
- **Copy and paste:** paste an image straight in, and copy the result straight out.
- **Remembers your settings** between launches, and shows how much time is left while it works.
- **Pixelated images** are spotted and rebuilt from their real resolution instead of being enlarged block by block.
- **Classic mode** offers fast GPU upscaling without AI (AMD FidelityFX Super Resolution 1, detail refinement and sharpening).
- **Before/after compare** with a draggable divider, zoom and pan.
- **Private:** everything happens on your own device.

## Credits

- The upscaling models are converted from [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) by Xintao Wang et al. (BSD 3-Clause License).
- Face restoration uses [GFPGAN](https://github.com/TencentARC/GFPGAN) v1.4 by Xintao Wang et al. (Apache License 2.0).
- On Windows, faces are found with [YuNet](https://github.com/opencv/opencv_zoo) by Shiqi Yu (MIT License).
- Classic mode includes a port of AMD FidelityFX Super Resolution 1.

The full licences are in the `Models` and `Windows/app/licenses` folders.
