# Depth Vision 3D for iOS

一个完全端侧运行的 iOS 示例项目：

- 图片：Depth Anything V2 Small（Core ML）生成相对深度，Metal 合成左右眼 SBS 立体图。
- 视频：逐帧运行同一 Core ML 模型，每 3 帧更新深度并做指数时序滤波，Metal 合成 SBS MP4。
- 模拟器：Apple Silicon Mac 上使用 CPU + GPU；真机使用 Core ML 的全部可用计算单元。

## 运行

1. 用 Xcode 26 或更高版本打开 `DepthVision3D.xcodeproj`。
2. 选择任意 iOS 17+ 模拟器。
3. 点击 Run。
4. 图片页可使用“内置示例”，不依赖模拟器照片库。
5. 视频页通过文件选择器选择一个短 MP4/MOV 文件。

官方 `DepthAnythingV2SmallF16.mlpackage` 已包含在 `DepthVision3D/Resources/Models`，无需额外下载或安装 Swift Package。

## 说明

Depth Anything V2 默认输出相对视差，不是有真实米制尺度的深度。本项目输出的是适合平面屏幕/VR 播放的 2.5D SBS 内容，并不是包含物体背面几何的完整 3D 模型。

视频演示导出不复制音轨，重点展示端侧深度推理、时序平滑和 Metal SBS 合成链路。
