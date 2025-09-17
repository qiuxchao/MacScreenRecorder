# MacScreenRecorder（开发中 🛠️）

一个用 Swift 编写的简单而强大的 macOS 屏幕录制库。

## 功能特性

- 🎬 录制屏幕、摄像头、麦克风和系统音频。
- 🚀 简单且现代化的 Swift API。
- ⚙️ 在 macOS 12.3+ 上自动使用 `ScreenCaptureKit` 以获得最佳性能和功能。
- 在旧版系统上回退到 `CGDisplayStream`。
- 🎤 支持从麦克风捕获音频。
- 🎧 支持捕获系统音频输出（仅限 macOS 12.3+）。
- 📹 支持从摄像头捕获视频。
- 델 基于代理（Delegate）的成功和失败事件回调。
- 🛡 为摄像头和麦克风访问提供可靠的权限处理。

## 环境要求

- Xcode 13 或更高版本。
- Swift 5.5 或更高版本。

## 使用方法

这是一个如何使用 `MacScreenRecorder` 的基本示例。

首先，请确保在你的应用的 `Info.plist` 文件中启用“屏幕录制”、“麦克风”和“摄像头”权限，并添加相应的描述：

- `Privacy - Screen Recording Usage Description`
- `Privacy - Microphone Usage Description`
- `Privacy - Camera Usage Description`

然后，你可以像这样使用 `Recorder` 类：

```swift
import Cocoa
import AVFoundation
// 确保导入 MacScreenRecorder 模块
// import MacScreenRecorder

class ViewController: NSViewController, RecorderDelegate {

    private let recorder = Recorder()
    private var isRecording = false

    override func viewDidLoad() {
        super.viewDidLoad()
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
        // 获取输出文件的 URL
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let outputURL = downloadsURL.appendingPathComponent("recording-\(Date()).mov")

        do {
            // 开始录制屏幕和麦克风
            try recorder.start(
                outputURL: outputURL,
                screen: true,
                microphone: true,
                systemAudio: true, // 仅在 macOS 12.3+ 上有效
                camera: false
            )
            print("Started recording to \(outputURL)")
        } catch {
            print("Failed to start recording: \(error)")
            // 在你的应用中妥善处理错误
        }
    }

    private func stopRecording() {
        recorder.stop()
        print("Stopping recording...")
    }

    // MARK: - RecorderDelegate

    func recorder(_ recorder: Recorder, didFinishWritingFile fileURL: URL) {
        print("Finished writing file to: \(fileURL)")
        // 你现在可以打开文件、分享它等。
    }

    func recorder(_ recorder: Recorder, didFailWithError error: Error) {
        print("Recording failed with error: \(error)")
        // 处理错误，例如向用户显示警报
        DispatchQueue.main.async {
            self.isRecording = false
            // 更新 UI，例如按钮标题
        }
    }
}
```

## API 参考

### `Recorder`

用于管理录制的主类。

**属性**

- `delegate: RecorderDelegate?`: 用于接收录制事件的代理。

**方法**

- `init()`: 创建一个新的 `Recorder` 实例。
- `start(outputURL: URL, screen: Bool, microphone: Bool, systemAudio: Bool, camera: Bool) throws`: 使用指定的配置开始新的录制。
  - `outputURL`: 录制的视频文件的目标 URL。
  - `screen`: 是否录制主显示器。
  - `microphone`: 是否从默认麦克风录制音频。
  - `systemAudio`: 是否录制系统的音频输出。**需要 macOS 12.3 或更高版本。**
  - `camera`: 是否从默认摄像头录制视频。
- `stop()`: 停止当前的录制。结果将通过代理传递。

### `RecorderDelegate`

一个用于从 `Recorder` 接收反馈的协议。

**方法**

- `recorder(_ recorder: Recorder, didFinishWritingFile fileURL: URL)`: 当录制成功完成并且文件已保存时调用。
- `recorder(_ recorder: Recorder, didFailWithError error: Error)`: 如果在录制过程中发生错误，则调用此方法。

### `RecorderError`

一个表示可能发生的错误的枚举。

- `.unsupportedOS`: 当前操作系统版本不受支持。
- `.permissionDenied(String)`: 所需的权限（例如，麦克风或摄像头）被拒绝。
- `.internalError(String)`: 发生内部错误，例如未找到显示器。

## 注意事项

- **系统音频录制**: 捕获系统音频仅在 macOS 12.3 及更高版本上可行，因为它依赖于 `ScreenCaptureKit` 框架。如果你尝试在旧版操作系统上启用它，该库将抛出错误。
- **权限**: 你的应用程序必须具有屏幕录制、麦克风访问和摄像头访问的必要权限。如果未授予访问权限，该库将抛出 `permissionDenied` 错误。最佳实践是在你的应用的 `Info.plist` 文件中包含这些权限的使用说明。

## 在 Rust 中使用

`MacScreenRecorder` 框架通过一个稳定的 C-API 暴露了其核心功能，可以方便地在 Rust 或其他支持 C FFI 的语言中调用。

### 1. 编译框架

首先，你需要编译 Swift 项目以生成 `.framework` 文件。你可以使用 Xcode 或者通过命令行来完成。

使用 `xcodebuild` 命令进行编译 (推荐):

```sh
xcodebuild -scheme MacScreenRecorder -sdk macosx build
```

编译成功后，你可以在项目目录的 `build/Debug` 或 `build/Release` 文件夹下找到 `MacScreenRecorder.framework`。例如：`./build/Debug/MacScreenRecorder.framework`。

### 2. 设置 Rust 项目

接下来，设置你的 Rust 项目以链接到这个框架。

#### Cargo.toml

在你的 `Cargo.toml` 中添加 `build-dependencies`：

```toml
[package]
name = "recorder-test"
version = "0.1.0"
edition = "2021"

[build-dependencies]
cc = "1.0"
```

#### build.rs

在你的项目根目录下创建一个 `build.rs` 文件。这个脚本会告诉 `rustc` 如何找到并链接 `MacScreenRecorder.framework`。

**重要提示**: 请将 `FRAMEWORK_PATH` 修改为你本地 `MacScreenRecorder.framework` 所在的实际路径。

```rust
// build.rs
fn main() {
    // 告诉 cargo 在这个路径下寻找本地库
    // 请将此路径修改为你本地 MacScreenRecorder.framework 的父目录
    // 例如: "/path/to/your/project/build/Debug"
    const FRAMEWORK_PATH: &str = "/path/to/your/project/build/Debug";

    println!("cargo:rustc-link-search=framework={}", FRAMEWORK_PATH);
    println!("cargo:rustc-link-lib=framework=MacScreenRecorder");
}
```

### 3. Rust 代码示例

现在你可以在 Rust 代码中声明并调用 C-API 了。

#### 定义 C-API 接口

首先，你需要定义从 `CBridge.swift` 导出的 C 结构体和函数。

```rust
// src/main.rs

use std::ffi::{c_char, c_void, CStr};
use std::os::raw::c_int;

// Opaque pointer for the recorder instance
type RecorderRef = *mut c_void;
// Opaque pointer for C arrays
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
    pub count: i32,
    pub items: *mut CDisplay,
}

extern "C" {
    // Recorder lifecycle
    fn msr_recorder_create() -> RecorderRef;
    fn msr_recorder_destroy(recorder: RecorderRef);

    // Recording control
    fn msr_recorder_start(recorder: RecorderRef, options: *const CRecorderOptions) -> bool;
    fn msr_recorder_stop(recorder: RecorderRef);

    // Permissions
    fn msr_has_screen_recording_permission() -> bool;
    fn msr_request_screen_recording_permission();

    // Device lists
    fn msr_get_displays_list() -> OpaqueArrayRef;
    fn msr_free_displays_list(displays: OpaqueArrayRef);
}
```

#### 调用示例

下面是一个简单的 `main` 函数，演示了如何检查权限、获取显示器列表并开始录制。

```rust
// src/main.rs (continued)

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

        // 2. 获取显示器列表
        let displays_ptr = msr_get_displays_list();
        if displays_ptr.is_null() {
            eprintln!("未能获取显示器列表。");
            return;
        }

        let display_array = *(displays_ptr as *const CDisplayArray);
        println!("找到 {} 个显示器:", display_array.count);

        let displays = std::slice::from_raw_parts(display_array.items, display_array.count as usize);
        for display in displays {
            let name_str = CStr::from_ptr(display.name).to_string_lossy();
            println!("  - ID: {}, 名称: {}", display.id, name_str);
        }

        // 选择第一个显示器用于录制
        let main_display_id = displays.first().map_or(0, |d| d.id);

        // 释放显示器列表内存
        msr_free_displays_list(displays_ptr);

        // 3. 创建和配置 Recorder
        let recorder = msr_recorder_create();
        if recorder.is_null() {
            eprintln!("创建 recorder 失败。");
            return;
        }

        let output_path = std::ffi::CString::new("./recording.mov").unwrap();
        let options = CRecorderOptions {
            output_path: output_path.as_ptr(),
            frame_rate: 30,
            bitrate: 6_000_000,
            show_cursor: true,
            system_audio: true, // 仅在 macOS 12.3+ 有效
            display_id: main_display_id,
            crop_x: 0,
            crop_y: 0,
            crop_width: 0,  // 0 表示不裁剪
            crop_height: 0, // 0 表示不裁剪
            microphone_id: std::ptr::null(), // 不录制麦克风
        };

        // 4. 开始录制
        println!("开始录制... (持续 5 秒)");
        if msr_recorder_start(recorder, &options) {
            std::thread::sleep(std::time::Duration::from_secs(5));

            // 5. 停止录制
            msr_recorder_stop(recorder);
            println!("录制结束。文件已保存到 ./recording.mov");
        } else {
            eprintln!("录制启动失败。");
        }

        // 6. 销毁 Recorder
        msr_recorder_destroy(recorder);
    }
}
```
