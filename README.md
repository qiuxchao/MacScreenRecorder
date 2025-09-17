# MacScreenRecorder（🛠️ 开发中）

一个用 Swift 编写的简单而强大的 macOS 屏幕录制库，并提供稳定的 C-API 以便在 Rust 等其他语言中使用。

## 🌟 功能特性

- 🎬 **多源录制**: 录制屏幕、麦克风和系统音频。
- 🚀 **代理模式 API**: 提供简单易用的 `RecorderDelegate` 协议来处理录制事件。
- ⚙️ **智能后端**: 在 macOS 12.3+ 上自动使用 `ScreenCaptureKit` 以获得最佳性能，并为旧版系统回退到 `CGDisplayStream`。
- 🦀 **Rust FFI**: 暴露了稳定的 C-API，可以轻松集成到 Rust 项目中。
- 🎤 **音频捕获**: 支持从指定麦克风和系统输出捕获音频（系统音频需要 macOS 12.3+）。
- 🛡 **权限辅助**: 提供静态方法来检查和请求屏幕录制及麦克风权限。
- 💻 **设备枚举**: 提供静态方法来获取显示器和麦克风列表。

## 📋 环境要求

- macOS 10.15 或更高版本
- Xcode 13 或更高版本
- Swift 5.5 或更高版本

_注意：系统音频录制和 `ScreenCaptureKit` 后端需要 macOS 12.3 或更高版本。_

## 🚀 使用方法 (Swift)

这是一个如何使用 `MacScreenRecorder` 的基本示例。

### 1. 配置 Info.plist

首先，请确保在你的应用的 `Info.plist` 文件中添加“屏幕录制”和“麦克风”的权限描述：

- `Privacy - Screen Recording Usage Description`
- `Privacy - Microphone Usage Description`

### 2. 录制代码示例

通过实现 `RecorderDelegate` 协议来接收录制完成或失败的事件。

```swift
import Cocoa
import AVFoundation
import MacScreenRecorder

class ViewController: NSViewController, RecorderDelegate {

    private let recorder = Recorder()
    private var isRecording = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // 设置代理以接收回调
        recorder.delegate = self
    }

    @IBAction func toggleRecording(_ sender: NSButton) {
        if isRecording {
            stopRecording()
            sender.title = "Start Recording"
        } else {
            startRecording()
            sender.title = "Stop Recording"
        }
        isRecording.toggle()
    }

    private func startRecording() {
        // 检查权限
        guard Recorder.hasScreenRecordingPermission else {
            print("错误：没有屏幕录制权限。")
            Recorder.requestScreenRecordingPermission()
            return
        }

        // 获取输出文件的 URL
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let outputURL = downloadsURL.appendingPathComponent("recording-\(Date().timeIntervalSince1970).mov")

        do {
            // 开始录制屏幕和默认麦克风
            try recorder.start(
                outputURL: outputURL,
                display: nil, // nil 表示主显示器
                microphoneDevice: AVCaptureDevice.default(for: .audio),
                systemAudio: true // 仅在 macOS 12.3+ 上有效
            )
            print("录制已开始，输出到: \(outputURL)")
        } catch {
            print("启动录制失败: \(error)")
            // 在你的应用中妥善处理错误
        }
    }

    private func stopRecording() {
        recorder.stop()
        print("正在停止录制...")
    }

    // MARK: - RecorderDelegate

    func recorder(_ recorder: Recorder, didFinishWritingFile fileURL: URL) {
        print("录制成功完成，文件已保存到: \(fileURL)")
        // 你现在可以打开文件、分享它等。
        DispatchQueue.main.async {
            self.isRecording = false
            // 更新 UI
        }
    }

    func recorder(_ recorder: Recorder, didFailWithError error: Error) {
        print("录制失败，错误: \(error)")
        // 处理错误，例如向用户显示警报
        DispatchQueue.main.async {
            self.isRecording = false
            // 更新 UI
        }
    }
}
```

## 📚 API 参考 (Swift)

### `Recorder`

用于管理录制的主类。

**属性**

- `delegate: RecorderDelegate?`: 用于接收录制事件的代理。

**实例方法**

- `init()`: 创建一个新的 `Recorder` 实例。
- `start(outputURL: URL, fileType: AVFileType, bitrate: Int, display: Any?, cropRect: CGRect?, frameRate: Int, showCursor: Bool, microphoneDevice: AVCaptureDevice?, systemAudio: Bool) throws`: 使用指定的配置开始新的录制。
  - `outputURL`: 录制的视频文件的目标 URL。
  - `display`: 要录制的显示器。可以是 `SCDisplay` (macOS 12.3+) 或 `CGDirectDisplayID`。传 `nil` 则使用主显示器。
  - `microphoneDevice`: 要录制的 `AVCaptureDevice` 麦克风实例。
  - `systemAudio`: 是否录制系统的音频输出。**需要 macOS 12.3 或更高版本。**
- `stop()`: 停止当前的录制。结果将通过代理异步传递。

**静态方法**

- `hasScreenRecordingPermission: Bool`: 检查是否具有屏幕录制权限。
- `requestScreenRecordingPermission()`: 请求屏幕录制权限。
- `hasMicrophonePermission: Bool`: 检查是否具有麦克风权限。
- `requestMicrophonePermission(completion: @escaping (Bool) -> Void)`: 请求麦克风权限。
- `getDisplays() async -> [Any]`: 异步获取可用显示器列表。
- `getMicrophones() -> [AVCaptureDevice]`: 获取可用麦克风列表。

### `RecorderDelegate`

一个用于从 `Recorder` 接收反馈的协议。

- `recorder(_ recorder: Recorder, didFinishWritingFile fileURL: URL)`: 当录制成功完成并且文件已保存时调用。
- `recorder(_ recorder: Recorder, didFailWithError error: Error)`: 如果在录制过程中发生错误，则调用此方法。

## 🦀 在 Rust 中使用

`MacScreenRecorder` 框架通过一个稳定的 C-API 暴露了其核心功能。

### 1. 编译框架

使用 `xcodebuild` 命令编译 Swift 项目以生成 `.framework` 文件。

```sh
xcodebuild -scheme MacScreenRecorder -sdk macosx build -configuration Release
```

编译成功后，你可以在项目目录的 `build/Release` 文件夹下找到 `MacScreenRecorder.framework`。

### 2. 设置 Rust 项目

#### Cargo.toml

在你的 `Cargo.toml` 中添加 `build-dependencies`：

```toml
[package]
name = "recorder-test"
version = "0.1.0"
edition = "2021"

[dependencies]
libc = "0.2"

[build-dependencies]
cc = "1.0"
```

#### build.rs

在你的项目根目录下创建一个 `build.rs` 文件，以链接 `MacScreenRecorder.framework`。

**重要提示**: 设置环境变量 `MAC_SCREEN_RECORDER_FRAMEWORK_PATH` 指向框架所在的目录（例如 `/path/to/your/project/build/Release`）。

```rust
// build.rs
use std::env;

fn main() {
    let framework_path = env::var("MAC_SCREEN_RECORDER_FRAMEWORK_PATH")
        .expect("环境变量 MAC_SCREEN_RECORDER_FRAMEWORK_PATH 未设置。");

    println!("cargo:rustc-link-search=framework={}", framework_path);
    println!("cargo:rustc-link-lib=framework=MacScreenRecorder");
}
```

### 3. Rust 代码示例

以下是在 Rust 中调用 C-API 的示例。

```rust
// src/main.rs

use std::ffi::{c_char, c_void, CStr, CString};
use std::os::raw::c_int;

// 为 recorder 实例和 C 数组定义不透明指针
type RecorderRef = *mut c_void;
type OpaqueArrayRef = *mut c_void;

#[repr(C)]
pub struct CRecorderOptions {
    pub output_path: *const c_char,
    pub bitrate: i32,
    pub frame_rate: i32,
    pub show_cursor: bool,
    pub system_audio: bool,
    pub display_id: u32,
    pub crop_x: i32,
    pub crop_y: i32,
    pub crop_width: i32,
    pub crop_height: i32,
    pub microphone_id: *const c_char,
}

#[repr(C)]
pub struct CDisplay {
    pub id: u32,
    pub name: *const c_char,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub scale: f64,
}

#[repr(C)]
#[derive(Debug)]
pub struct CDisplayArray {
    pub count: c_int,
    pub items: *mut CDisplay,
}

extern "C" {
    // Recorder 生命周期
    fn msr_recorder_create() -> RecorderRef;
    fn msr_recorder_destroy(recorder: RecorderRef);

    // 录制控制
    fn msr_recorder_start(recorder: RecorderRef, options: *const CRecorderOptions) -> bool;
    fn msr_recorder_stop(recorder: RecorderRef);

    // 权限
    fn msr_has_screen_recording_permission() -> bool;
    fn msr_request_screen_recording_permission();
    fn msr_has_microphone_permission() -> bool;
    fn msr_request_microphone_permission();

    // 设备列表
    fn msr_get_displays_list() -> OpaqueArrayRef;
    fn msr_free_displays_list(displays: OpaqueArrayRef);
    fn msr_get_microphones_list() -> OpaqueArrayRef;
    fn msr_free_microphones_list(microphones: OpaqueArrayRef);
}

fn main() {
    unsafe {
        // 1. 检查并请求权限
        if !msr_has_screen_recording_permission() {
            println!("请求屏幕录制权限...");
            msr_request_screen_recording_permission();
            // 在实际应用中，这里需要等待用户授权
            std::thread::sleep(std::time::Duration::from_secs(5));
            if !msr_has_screen_recording_permission() {
                eprintln!("获取屏幕录制权限失败。");
                return;
            }
        }
        println!("已获取屏幕录制权限。");

        // 2. 获取并选择显示器
        let displays_ptr = msr_get_displays_list();
        if displays_ptr.is_null() {
            eprintln!("未能获取显示器列表。");
            return;
        }
        let display_array = *(displays_ptr as *const CDisplayArray);
        let main_display_id = if display_array.count > 0 {
            let first_display = *display_array.items;
            first_display.id
        } else {
            0 // 回退到主显示器ID
        };
        msr_free_displays_list(displays_ptr);

        // 3. 创建 Recorder
        let recorder = msr_recorder_create();
        if recorder.is_null() {
            eprintln!("创建 recorder 失败。");
            return;
        }

        let output_path = CString::new("./recording.mov").unwrap();
        let options = CRecorderOptions {
            output_path: output_path.as_ptr(),
            frame_rate: 30,
            bitrate: 6_000_000,
            show_cursor: true,
            system_audio: true, // 仅在 macOS 12.3+ 有效
            display_id: main_display_id,
            crop_x: 0, crop_y: 0, crop_width: 0, crop_height: 0,
            microphone_id: std::ptr::null(), // 传 null 使用默认麦克风
        };

        // 4. 开始和停止录制
        println!("开始录制... (持续 5 秒)");
        if msr_recorder_start(recorder, &options) {
            std::thread::sleep(std::time::Duration::from_secs(5));
            msr_recorder_stop(recorder);
            println!("录制结束。文件已保存到 ./recording.mov");
        } else {
            eprintln!("录制启动失败。");
        }

        // 5. 销毁 Recorder
        msr_recorder_destroy(recorder);
    }
}
```

## ⚠️ 注意事项

- **系统音频录制**: 捕获系统音频仅在 macOS 12.3 及更高版本上可行，因为它依赖于 `ScreenCaptureKit` 框架。
- **权限**: 你的应用程序必须具有屏幕录制和麦克风访问的必要权限。请务必在 `Info.plist` 文件中包含使用说明。

## 📄 许可证

[MIT](LICENSE)
