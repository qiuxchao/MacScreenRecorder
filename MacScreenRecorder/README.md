# MacScreenRecorder

轻量 macOS 屏幕 + 音频录制库（兼容新/旧 macOS）。本 README 概述库提供的公共 API、使用示例、兼容性与权限说明。

## 特性（已实现）

- 查询与请求权限：
  - Recorder.hasScreenRecordingPermission (Bool)
  - Recorder.requestScreenRecordingPermission()
  - Recorder.hasMicrophonePermission (Bool)
  - Recorder.requestMicrophonePermission(completion: (Bool) -> Void)
- 设备枚举：
  - Recorder.getDisplays() -> [SCDisplay | CGDirectDisplayID]
  - Recorder.getMicrophones() -> [AVCaptureDevice]
  - Recorder.getSpeakers() -> [AVCaptureDevice]
- 支持按显示器 / 指定坐标 (x,y) 与尺寸 (width,height) 裁剪录制
- 支持指定帧率 (frameRate)
- 支持指定麦克风设备（可选）进行录音；若未指定但启用麦克风则使用系统默认麦克风
- 支持输出格式：.mov 与 .mp4（通过 AVFileType 参数）
- 支持自定义视频比特率（bitrate）
- 不再支持摄像头录制（相关代码已移除）

## 快速开始

1. 请求或检查权限（屏幕录制与麦克风）

- 检查屏幕录制权限：
  let ok = Recorder.hasScreenRecordingPermission
- 请求屏幕录制权限（在旧版 macOS 会打开系统设置）：
  Recorder.requestScreenRecordingPermission()
- 检查/请求麦克风：
  let micOk = Recorder.hasMicrophonePermission
  Recorder.requestMicrophonePermission { granted in ... }

2. 枚举设备（可选）

- 显示器列表：
  let displays = Recorder.getDisplays()
- 麦克风 / 扬声器列表：
  let mics = Recorder.getMicrophones()

3. 调用录制
   示例：录制指定显示器、裁剪区域、30fps、输出 mp4、6Mbps，比特率，自定义麦克风设备：

```swift
let recorder = Recorder()
recorder.delegate = self
let output = URL(fileURLWithPath: "/path/to/out.mp4")
try recorder.start(
    outputURL: output,
    fileType: .mp4,
    bitrate: 6_000_000,
    display: selectedDisplay,          // SCDisplay or CGDirectDisplayID
    cropRect: CGRect(x: 100, y: 100, width: 1280, height: 720),
    frameRate: 30,
    showCursor: true,
    microphoneDevice: selectedMic,     // optional, pass nil to use default
    systemAudio: false                 // only effective on macOS >= 12.3
)
// Stop:
recorder.stop()
```

## API 说明（重点）

- Recorder.start(
  outputURL: URL,
  fileType: AVFileType = .mov,
  bitrate: Int = 6_000_000,
  display: Any? = nil,
  cropRect: CGRect? = nil,
  frameRate: Int = 30,
  showCursor: Bool = true,
  microphoneDevice: AVCaptureDevice? = nil,
  systemAudio: Bool = false
  ) throws

说明：

- display: 在 macOS >=12.3 为 SCDisplay（来自 Recorder.getDisplays()），在旧系统为 CGDirectDisplayID。
- cropRect: 屏幕坐标系的 CGRect（x,y,width,height）。若为 nil，录制整屏。
- microphoneDevice: 可选；传 nil 表示使用系统默认麦克风（如果 microphone 开启）。
- systemAudio: 仅在 macOS >=12.3 并使用 ScreenCaptureKit 时生效；旧系统会报错或忽略。

- 权限相关：
  - Recorder.hasScreenRecordingPermission 在 >=12.3 通过 ScreenCaptureKit 检测；在 <12.3 通过创建短时 CGDisplayStream 来探测（尽量准确）。若无权限，请调用 Recorder.requestScreenRecordingPermission() 引导用户授权。
  - Recorder.requestScreenRecordingPermission()：在旧版 macOS 会尝试打开“系统设置 → 隐私与安全 → 屏幕录制”页面，引导用户手动授权。

## 兼容性说明

- macOS >= 12.3 (推荐)
  - 支持 ScreenCaptureKit，能够枚举 SCDisplay、录制屏幕与系统音频（systemAudio）。
- macOS < 12.3 (legacy)
  - 使用 CGDisplayStream 实现屏幕捕获，支持指定 displayID、裁剪、帧率、麦克风录音。
  - 不支持系统音频捕获（systemAudio），也无法枚举 SCDisplay 类型。
  - requestScreenRecordingPermission 无法直接弹出授权对话（已实现为打开系统设置引导）。

## 限制与建议

- 如果需要录制系统输出音频（扬声器），在旧系统上请使用虚拟音频设备（例如 BlackHole、Soundflower 等）把系统输出路由到输入设备，然后选择该输入作为 microphoneDevice。
- 本库默认使用 H.264 编码与 AAC 音频；可通过 fileType 参数选择 .mov/.mp4（注意：容器差异可能影响兼容性）。
- 本库已移除摄像头录制支持；如需要摄像头，请在外部合成视频流后写入最终文件。

## 错误处理

- RecorderError.unsupportedOS：在编译的 SDK 与运行时系统不匹配且无法提供所需功能时返回。
- RecorderError.permissionDenied(...)：权限被拒绝。
- RecorderError.internalError(...)：内部错误或不支持的组合（例如在旧 macOS 启用 systemAudio）。

## 示例：列举显示器并录制主显示器 60fps

```swift
let displays = Recorder.getDisplays()
let main = displays.first // SCDisplay or CGDirectDisplayID
try recorder.start(
    outputURL: URL(fileURLWithPath: "out.mov"),
    fileType: .mov,
    bitrate: 8_000_000,
    display: main,
    frameRate: 60,
    showCursor: true,
    microphoneDevice: nil,
    systemAudio: false
)
```

## 结束语

我已在代码中实现以上功能并在注释内标注了与 macOS 版本相关的限制。如果需要，我可以继续：

- 增加更详尽的单元/集成测试用例；
- 添加示例 macOS app（演示 UI 选择显示器/设备并开始录制）；
- 集成虚拟音频设备的说明或小脚本以检测常见虚拟驱动（如 BlackHole）。
