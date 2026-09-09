# DepthVision3D

DepthVision3D 是一个运行在 iPhone 端的 2D → 3D 实验项目。它使用 **Depth Anything V2 Small（Core ML）** 估计相对深度，再通过 **Metal** 生成左右眼并排（Side-by-Side，SBS）内容，并可在手机端预览或输出到 View1 眼镜外屏。

> 深度推理和 SBS 合成都在 iPhone 上完成，眼镜端当前负责显示结果，并不在眼镜上运行模型。

## 主要功能

### 图片转换

- 从系统图册选择图片，或使用 App 内置示例。
- 将 HEIF、HDR、Display-P3 等图片统一转换为标准动态范围的 8-bit 图像，减少解码和 Metal 纹理加载失败。
- 使用 Depth Anything V2 生成相对深度结果。
- 使用 Metal 生成左右眼 SBS 立体图。
- 支持调节立体强度和聚焦平面。
- 支持预览、分享，并将结果同步显示到已连接的 View1。

### 视频转换

- 支持从系统图册选择视频，图册选择器只显示视频。
- 保留文件导入入口，便于 V2/V3 使用完全相同的测试文件进行对比。
- 逐帧生成 SBS 视频，每 3 帧更新一次深度，并进行时序平滑。
- 视频处理阶段先生成无声 H.264 SBS MP4，再在第二阶段封装原视频音轨，避免音频和逐帧推理互相阻塞。
- 支持手机与 View1 共用同一个 `AVPlayer` 播放转换结果。
- 支持取消正在进行的图册读取、逐帧转换或音频封装，并清理未完成的临时文件。

### View1 外屏输出

- 识别 1920×1080 和 3840×1080、60 Hz 的外接屏幕模式。
- 无法自动识别时，可在手机端点击“确认为 View1”。
- 支持显示 SBS 图片和播放 SBS 视频。
- View1 断开并重新连接后，可恢复最近请求的图片或视频内容。
- 视频声音由 iOS 音频路由决定，可能从 iPhone、蓝牙设备或其他系统选择的输出设备播放。

## 处理流程

### 图片

```text
图册图片 / 内置示例
        ↓
标准动态范围与尺寸归一化
        ↓
Depth Anything V2 相对深度推理
        ↓
Metal 左右眼视差合成
        ↓
手机预览 / 分享 / View1 SBS 输出
```

### 视频

```text
图册视频 / 文件视频
        ↓
AVAssetReader 逐帧读取
        ↓
V2 深度推理 + 时序平滑
        ↓
Metal SBS 合成 + H.264 写入
        ↓
封装原视频音轨
        ↓
手机与 View1 共用 AVPlayer 播放
```

## 参数说明

- **立体强度**：控制左右眼画面的最大水平视差。数值越大，立体感越明显，但过大可能造成重影、边缘拉伸或观看不适。
- **聚焦平面**：决定深度值处于哪个位置时左右眼画面不发生位移。它会改变哪些内容看起来位于屏幕前方或后方。

## 环境要求

- iOS 17.0 或更高版本。
- 支持 Metal 的 iPhone 或 iOS 模拟器。
- 建议使用当前版本 Xcode 打开 `DepthVision3D.xcodeproj`。
- 测试 View1 输出需要真实 iPhone、View1 眼镜及对应的外接显示连接方式。

项目已包含编译后的 `DepthAnythingV2SmallF16.mlmodelc`，正常运行不需要下载模型或安装额外的 Swift Package。

## 运行方法

1. 克隆仓库：

   ```bash
   git clone https://github.com/TaoF2002/DepthVision3D.git
   ```

2. 使用 Xcode 打开 `DepthVision3D.xcodeproj`。
3. 在项目的 Signing & Capabilities 中选择自己的开发团队，并按需修改 Bundle Identifier。
4. 选择 iPhone 或模拟器后运行。
5. 图片测试：选择“图片”，导入图片后点击“生成立体图”。
6. 视频测试：选择“视频”，从图册或文件导入视频并等待转换完成。

模拟器会使用 CPU 执行 Core ML 推理，速度可能较慢；iPhone 真机会使用系统可用的 CPU、GPU 或 Neural Engine。

## View1 测试建议

1. 先在 iPhone 上启动 App，再连接 View1。
2. 等待“View1 眼镜输出”区域显示已连接；若外屏显示为未知设备，可点击“确认为 View1”。
3. 转换一张图片，检查左右眼顺序、立体强度、聚焦平面和画面边缘。
4. 转换一个带声音的短视频，检查手机预览、View1 画面、播放同步和声音路由。
5. 断开并重新连接 View1，检查最近内容能否恢复。

与 V3 方案对比时，建议双方使用同一个文件导入视频，并统一输入素材、SBS 左右眼顺序、输出分辨率、立体强度及聚焦平面。

## 当前实现与限制

- Depth Anything V2 输出的是归一化后的相对深度，不是以米为单位的真实深度。
- 输出属于基于深度视差生成的 2.5D SBS 内容，不是包含物体背面几何信息的完整 3D 模型。
- `DepthRelief` 当前复用 V2 和 Metal 管线，并使用更强的视差参数；它不是已经确认的公司专有 Depth Relief 算法。
- 图片最长边会限制为 1280 像素；视频单眼宽度最高为 960 像素，最终输出宽度为单眼画面的两倍。
- 视频每 3 帧更新一次深度，性能更好，但快速运动场景可能出现深度变化滞后或闪烁。
- 常见 AAC 音轨可以直接封装进 MP4；部分 MOV/PCM 或特殊音频格式可能需要额外转码。
- 当前 View1 连接代码仍使用部分已被新 iOS SDK 标记为弃用的 `UIScreen` 外屏 API。它们目前仍可编译运行，但最终兼容性需要在真实 View1 设备上验证。

## 核心文件

- [`DepthEstimator.swift`](DepthVision3D/DepthEstimator.swift)：加载 Core ML 模型并生成相对深度。
- [`StereoRenderer.swift`](DepthVision3D/StereoRenderer.swift)：使用 Metal 生成左右眼 SBS 图片或视频帧。
- [`ProcessingService.swift`](DepthVision3D/ProcessingService.swift)：图片归一化、深度推理和立体合成流程。
- [`VideoConverter.swift`](DepthVision3D/VideoConverter.swift)：视频读帧、推理、写入、取消和音轨封装。
- [`AppViewModel.swift`](DepthVision3D/AppViewModel.swift)：手机端任务状态和图片、视频处理入口。
- [`CinemaSession.swift`](DepthVision3D/ios_View1Cinema_View1Cinema_Playback_CinemaSession.swift)：手机与 View1 共用的播放及展示状态。
- [`ExternalDisplayManager.swift`](DepthVision3D/ios_View1Cinema_View1Cinema_ExternalDisplay_ExternalDisplayManager.swift)：外接屏幕检测、确认、连接和重连。
- [`ExternalRootView.swift`](DepthVision3D/ios_View1Cinema_View1Cinema_ExternalDisplay_ExternalRootView.swift)：View1 外屏显示界面。
- [`DepthProcessor.swift`](DepthVision3D/DepthProcessor.swift)：公司 View1 接口与现有 V2 管线之间的兼容层。
