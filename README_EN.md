# DepthVision3D

[简体中文](README.md) | **English**

DepthVision3D is an experimental on-device 2D-to-3D app for iPhone. It uses **Depth Anything V2 Small (Core ML)** to estimate relative depth, then generates left/right Side-by-Side (SBS) content with **Metal**. Results can be previewed on the phone or presented on a View1 external display.

> Depth inference and SBS rendering both run on the iPhone. The glasses currently display the generated result and do not run the model themselves.

## Features

### Image Conversion

- Select an image from the system photo library or use the built-in sample.
- Convert HEIF, HDR, Display-P3, and other images to a standard-range 8-bit representation to reduce decoding and Metal texture-loading failures.
- Generate relative depth with Depth Anything V2.
- Generate left/right SBS images with Metal.
- Aspect-fit each eye into a 1920×1080 region and produce a fixed 3840×1080 Full-SBS image. Black bars are added when necessary to prevent stretching.
- Choose Soft 3D, Standard 3D, or Immersive 3D from a preset menu. Each preset sets stereo strength, convergence plane, maximum parallax, and depth curve; all four parameters can also be fine-tuned manually.
- Preview and share the result, or present it on a connected View1.
- Display timing for engine preparation, image normalization, V2 inference, Metal SBS rendering, output layout, and the total conversion.

### Video Conversion

- Select videos from the system photo library; the picker only displays videos.
- Keep the file-import option so V2 and V3 can be compared with exactly the same test file.
- Generate SBS video frame by frame, updating depth every three frames with temporal smoothing.
- Read and apply the video's orientation transform, aspect-fit each eye into a 1920×1080 region, and produce a fixed 3840×1080 Full-SBS H.264 MP4.
- Add black bars based on the source aspect ratio for landscape, portrait, square, and ultrawide videos instead of stretching them to fill the frame.
- First produce a silent H.264 SBS MP4, then attach the original audio track in a second pass to prevent audio back-pressure from blocking per-frame inference.
- Share one `AVPlayer` between the phone and View1 for converted-video playback.
- Cancel photo-library loading, frame conversion, or audio packaging, and clean up incomplete temporary files.
- Display timing for frame reading/decoding, orientation and scaling, V2 inference, Metal rendering, 3840×1080 layout, encoding, audio packaging, total processing, and effective processing frame rate.

### View1 External Display

- Recognize 1920×1080 and 3840×1080 external-display modes at 60 Hz.
- Manually confirm an unrecognized external display as View1 from the phone.
- Present SBS images and play SBS videos.
- Restore the most recently requested image or video after View1 disconnects and reconnects.
- Let iOS audio routing determine whether video sound plays through the iPhone, a Bluetooth device, or another system-selected output.

## Processing Pipeline

### Images

```text
Photo-library image / Built-in sample
        ↓
Standard-range and size normalization
        ↓
Aspect-fit into the 518×392 model input and remove depth padding
        ↓
Depth Anything V2 relative-depth inference
        ↓
Metal left/right disparity rendering
        ↓
Aspect-fit each eye into 1920×1080 and fill unused areas with black
        ↓
Phone preview / Share / View1 SBS output
```

### Videos

```text
Photo-library video / File-based video
        ↓
AVAssetReader frame extraction with orientation transform
        ↓
V2 depth inference + temporal smoothing
        ↓
Metal SBS rendering
        ↓
Aspect-fit into a 3840×1080 Full-SBS canvas and encode as H.264
        ↓
Attach the original audio track
        ↓
Shared AVPlayer playback on the phone and View1
```

## Output Size and Aspect Ratio

The current implementation treats the View1 3D mode as a **3840×1080 Full-SBS** output, with a **1920×1080** region for each eye. Source content always uses aspect fit. Unused areas are filled with black pixels, so the player or external-display device does not need to correct the aspect ratio by stretching the image.

| Source aspect ratio | Approximate content size per eye | Automatic black bars |
| --- | ---: | --- |
| 16:9 | 1920×1080 | None |
| 4:3 | 1440×1080 | 240 px on each side |
| 1:1 | 1080×1080 | 420 px on each side |
| 9:16 | 608×1080 | About 656 px on each side |
| 21:9 | 1920×823 | About 128 px at the top and bottom |

> The 3840×1080 Full-SBS format, left/right eye order, and View1 3D-mode switching behavior still need to be verified against the company's device specification and real View1 hardware.

## Parameters

- **Stereo Strength:** Controls horizontal disparity between the left- and right-eye images. Higher values produce a stronger 3D effect but can also cause ghosting, edge stretching, or visual discomfort.
- **Convergence Plane:** Selects the depth value at which the left- and right-eye images have zero displacement. It affects which content appears in front of or behind the screen plane.
- **Maximum Parallax:** Limits total binocular displacement as a percentage of the width of one eye's content region, preventing extreme depth values from creating excessive disparity.
- **Depth Curve:** Adjusts intermediate depth separation. Values above 1 suppress the middle depth range for a softer result, while values below 1 emphasize it for a more immersive result. The convergence plane and both depth endpoints remain unchanged.

| 3D mode | Stereo strength | Convergence plane | Maximum parallax | Depth curve |
| --- | ---: | ---: | ---: | ---: |
| Soft 3D | 1.5% | 0.50 | 1.5% | 1.20 |
| Standard 3D | 2.5% | 0.50 | 2.5% | 1.00 |
| Immersive 3D | 4.0% | 0.50 | 3.5% | 0.80 |

After selecting a preset, any parameter can still be fine-tuned with its slider. Manual adjustment changes the mode label to “Custom”; selecting a preset again restores that preset's default values.

## Performance Metrics

After an image or video conversion completes, the app displays a performance report at the bottom of the page and prints the same report to the Xcode console. The report can be selected and copied for comparing the simulator, different iPhones, source resolutions, and frame rates.

- Image metrics cover engine preparation, normalization, V2 depth inference, Metal SBS rendering, depth preview and fixed-canvas layout.
- Video metrics cover engine initialization, asset loading, pipeline preparation, frame read/decoding waits, orientation and scaling, V2 inference, Metal SBS rendering, fixed-canvas layout, encoding waits and writes, encoding finalization, and audio packaging.
- “Encoding wait and append” measures time spent waiting for the encoder to accept frames and submitting them. Hardware encoding can run concurrently, so this value is not the encoder's complete execution time.
- Total time also includes task scheduling, buffer allocation, progress callbacks, and other small unlisted costs, so the individual measurements are not expected to add up exactly to the total.

## Requirements

- iOS 17.0 or later.
- An iPhone or iOS Simulator with Metal support.
- The current version of Xcode is recommended for opening `DepthVision3D.xcodeproj`.
- Testing View1 output requires a physical iPhone, View1 glasses, and the corresponding external-display connection method.

The compiled `DepthAnythingV2SmallF16.mlmodelc` model is included in the project. Normal use does not require downloading a model or installing additional Swift packages.

## Getting Started

1. Clone the repository:

   ```bash
   git clone https://github.com/TaoF2002/DepthVision3D.git
   ```

2. Open `DepthVision3D.xcodeproj` in Xcode.
3. Select your development team under Signing & Capabilities and change the Bundle Identifier if necessary.
4. Select an iPhone or simulator and run the app.
5. Image test: select “Image,” import an image, and tap “Generate Stereo Image.”
6. Video test: select “Video,” import a video from Photos or Files, and wait for conversion to complete.

The simulator runs Core ML inference on the CPU and may be slow. On a physical iPhone, the system can use the available CPU, GPU, or Neural Engine.

## View1 Testing

1. Launch the app on the iPhone before connecting View1.
2. Wait for the View1 external-display section to report a connection. If the display is unknown, tap “Confirm as View1.”
3. Convert an image and check eye order, stereo strength, convergence plane, and object edges.
4. Convert a short video with audio and check the phone preview, View1 image, playback synchronization, and audio routing.
5. Disconnect and reconnect View1, then verify that the most recent content is restored.

When comparing against a V3 implementation, use the same file-based video in both versions and keep the source asset, SBS eye order, output resolution, stereo strength, and convergence plane consistent.

## Current Implementation and Limitations

- Depth Anything V2 produces normalized relative depth, not real-world depth measured in meters.
- The output is depth-driven 2.5D SBS content, not a complete 3D model containing occluded geometry or the backs of objects.
- `DepthRelief` currently reuses the V2 and Metal pipeline with stronger disparity parameters; it is not a confirmed proprietary Depth Relief algorithm.
- Images are limited to a 1920-pixel longest side before stereo rendering. Final image and video results are fixed at 3840×1080, with a 1920×1080 canvas for each eye.
- Portrait source content occupies a relatively narrow region in the model's fixed landscape 518×392 input. Small-object depth accuracy may therefore be lower than with landscape content.
- Video currently uses H.264 at an average bit rate of about 16.6 Mbps. Compression quality for high-frame-rate or high-motion content still needs to be verified on real hardware.
- Video depth is updated every three frames for better performance, but fast-moving scenes may show depth lag or flicker.
- Common AAC tracks can be attached directly to MP4. Some MOV/PCM or unusual audio formats may require transcoding.
- HEIF, HDR, and Display-P3 images are converted to standard-range 8-bit images for Core ML and Metal compatibility, so the full HDR range and wide-gamut color are not preserved.
- The current View1 connection code still uses some `UIScreen` external-display APIs marked as deprecated by newer iOS SDKs. They still compile and run, but final compatibility must be verified on physical View1 hardware.

## Future Improvements

- Continue calibrating the three 3D presets against real View1 viewing results, and evaluate video-stability and output-quality profiles.
- Keep V2 as the stable baseline while evaluating Depth Anything V3 Small Core ML as an optional experimental engine. Before integration, verify its input/output contract, depth direction, minimum OS version, ANE compatibility, performance, and license.
- Add separate fast-preview and final-View1 output profiles so parameter tuning does not require repeatedly generating full 3840×1080 output.
- Evaluate scaling directly during video decoding, combining Core Image/Metal intermediate stages, caching depth textures, and dynamically adjusting depth-inference intervals based on motion.
- Measure conversion time, peak memory, thermal behavior, and file size for videos of different lengths and frame rates on physical iPhones before choosing default resolution, bit rate, and inference frequency.

## Key Files

- [`DepthEstimator.swift`](DepthVision3D/DepthEstimator.swift): Loads the Core ML model and produces relative depth using aspect-fitted model input with depth-padding removal.
- [`StereoRenderer.swift`](DepthVision3D/StereoRenderer.swift): Generates left/right SBS images or video frames with Metal.
- [`ProcessingService.swift`](DepthVision3D/ProcessingService.swift): Handles image normalization, depth inference, stereo rendering, and fixed View1 canvas layout.
- [`VideoConverter.swift`](DepthVision3D/VideoConverter.swift): Handles video orientation correction, frame reading, inference, fixed-canvas encoding, cancellation, and audio packaging.
- [`AppViewModel.swift`](DepthVision3D/AppViewModel.swift): Manages phone-side task state, performance reports, and image/video processing entry points.
- [`CinemaSession.swift`](DepthVision3D/ios_View1Cinema_View1Cinema_Playback_CinemaSession.swift): Maintains shared playback and presentation state for the phone and View1.
- [`ExternalDisplayManager.swift`](DepthVision3D/ios_View1Cinema_View1Cinema_ExternalDisplay_ExternalDisplayManager.swift): Detects, confirms, connects, and reconnects external displays.
- [`ExternalRootView.swift`](DepthVision3D/ios_View1Cinema_View1Cinema_ExternalDisplay_ExternalRootView.swift): Provides the View1 external-display UI.
- [`DepthProcessor.swift`](DepthVision3D/DepthProcessor.swift): Adapts the existing V2 pipeline to the View1-facing API.
