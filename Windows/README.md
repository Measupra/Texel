# Texel for Windows

The Windows version of Texel, built with Electron. It has the same interface and features as the Mac and iPhone apps: AI upscaling (1× to 8×, or fitted to a size such as 4K), Auto Fix, batch upscaling, the Finish and Enhance sliders, face restoration, colour and light, Classic mode, copy and paste, and the before/after compare view.

## Run it

Download `Texel-Windows-0.2.zip`, unzip it anywhere, and double-click **Texel.exe**. Nothing needs installing.

Windows may show "Windows protected your PC" the first time, because the app isn't signed with a Windows code-signing certificate. Click **More info**, then **Run anyway**.

## How it works on Windows

- The AI models are the same as on the Mac (Real-ESRGAN Photo, General and Anime, and GFPGAN for faces), converted to ONNX with 8-bit weights.
- They run on the graphics card through WebGPU (ONNX Runtime Web). If there's no suitable graphics card, Texel uses the processor instead, which is much slower.
- Faces are found with YuNet (OpenCV Zoo).
- Classic mode uses WebGL 2: AMD FidelityFX Super Resolution 1 in 2× steps, detail refinement and RCAS sharpening.

## Build it yourself

Needs Node.js 20 or later.

```
npm install
npm start        # run from source
npm run dist     # makes dist/Texel-Windows-<version>.zip
```

`npm run dist` works on Windows, macOS or Linux.

## Files

| Path | What it is |
|---|---|
| `main.js`, `preload.js` | The window, file dialogs and the private `app://` origin |
| `app/index.html`, `app/styles.css`, `app/js/` | The interface |
| `app/engine/` | Upscaling, finishing, faces, colour, Auto Fix and Classic, run in a background worker |
| `app/models/` | The ONNX models |
| `app/vendor/ort/` | ONNX Runtime Web (WebGPU build) |
| `app/licenses/` | Licences for the models, runtime and font |
