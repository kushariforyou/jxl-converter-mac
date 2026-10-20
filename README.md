# JXL Converter for Mac

A native macOS app for batch-converting images to **JPEG XL** (`.jxl`).

- Drag in images or whole folders: JPEG, PNG, GIF, HEIC, TIFF, WebP, AVIF, BMP, RAW and more
- **Add Folder** asks whether to include subfolders and which file types to pick up (JPEG, PNG, HEIC, RAW, …), with a live count of matching images
- Drop images or folders on the Dock icon to add them
- **Lossless** checkbox: JPEGs are repacked losslessly (about 20% smaller, restorable bit-for-bit); other formats are pixel-perfect
- Lossy mode with a quality slider, plus an effort slider for speed vs. size
- **Preserve EXIF & XMP metadata** (camera info, GPS, dates, rotation, file timestamps), or strip it
- **Keep original if JPEG XL is larger**: discards outputs that grew (common for HEIC)
- Live "space saved" total that counts up as each file finishes, with per-file savings
- Converts several files in parallel; originals are never modified

Looking for Windows? See [jxl-converter-windows](https://github.com/kushariforyou/jxl-converter-windows).

## Install

1. Download `JXL-Converter-Mac.zip` from [Releases](../../releases), unzip it and move **JXL Converter.app** to Applications.
2. Install the encoder and metadata tool with [Homebrew](https://brew.sh):
   ```bash
   brew install jpeg-xl exiftool
   ```
3. The app isn't notarized, so on first launch macOS will block it. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/JXL Converter.app"
   ```

Requires macOS 14 or later on Apple Silicon.

## Build from source

Needs Xcode (for SwiftUI's macros):

```bash
./build.sh
```

The app is written to `build/JXL Converter.app`.

## How it works

The app uses [`cjxl`](https://github.com/libjxl/libjxl) from libjxl for encoding. Formats `cjxl` can't read (HEIC, TIFF, WebP, RAW, …) are decoded with Apple's ImageIO first, and their metadata is copied with [ExifTool](https://exiftool.org).
