import Foundation
import AVFoundation
import CoreGraphics

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

// MARK: - C-compatible Structs & Enums

/// Rust/C端传入的录制参数
@frozen
public struct CRecorderOptions {
    public var output_path: UnsafePointer<CChar>?
    public var bitrate: Int32
    public var frame_rate: Int32
    public var show_cursor: Bool
    public var system_audio: Bool

    // display_id: 0 表示主显示器
    public var display_id: UInt32
    public var crop_x: Int32
    public var crop_y: Int32
    public var crop_width: Int32
    public var crop_height: Int32

    public var microphone_id: UnsafePointer<CChar>?
}

/// 暴露给Rust/C的显示器信息
@frozen
public struct CDisplay {
    public var id: UInt32
    public var name: UnsafePointer<CChar>?
}

/// 暴露给Rust/C的麦克风信息
@frozen
public struct CMicrophone {
    public var id: UnsafePointer<CChar>?
    public var name: UnsafePointer<CChar>?
}

/// 暴露给Rust/C的显示器数组
@frozen
public struct CDisplayArray {
    public var count: Int32
    public var items: UnsafeMutablePointer<CDisplay>?
}

/// 暴露给Rust/C的麦克风数组
@frozen
public struct CMicrophoneArray {
    public var count: Int32
    public var items: UnsafeMutablePointer<CMicrophone>?
}

// MARK: - Recorder Lifecycle

/// 创建一个Recorder实例，并返回一个不透明指针
///
/// Rust端需要保存这个指针，并在后续操作中传递它。
/// @return 指向Recorder实例的不透明指针。如果创建失败则为nil。
@_cdecl("msr_recorder_create")
public func recorder_create() -> UnsafeMutableRawPointer? {
    let recorder = Recorder()
    return Unmanaged.passRetained(recorder).toOpaque()
}

/// 销毁通过 `recorder_create` 创建的Recorder实例
///
/// @param recorder_ptr `recorder_create`返回的不透明指针
@_cdecl("msr_recorder_destroy")
public func recorder_destroy(recorder_ptr: UnsafeMutableRawPointer?) {
    guard let recorder_ptr = recorder_ptr else { return }
    Unmanaged<Recorder>.fromOpaque(recorder_ptr).release()
}

// MARK: - Recording Control

/// 开始录制
///
/// @param recorder_ptr `recorder_create`返回的不透明指针
/// @param options_ptr 指向录制参数结构体的指针
/// @return 成功返回true，失败返回false
@_cdecl("msr_recorder_start")
public func recorder_start(recorder_ptr: UnsafeMutableRawPointer?, options_ptr: OpaquePointer?) -> Bool {
    guard let recorder_ptr = recorder_ptr, let options_ptr = options_ptr else { return false }
    let options = UnsafePointer<CRecorderOptions>(options_ptr)!.pointee
    let recorder = Unmanaged<Recorder>.fromOpaque(recorder_ptr).takeUnretainedValue()

    guard let outputPathCStr = options.output_path,
          let outputPath = String(cString: outputPathCStr, encoding: .utf8) else {
        return false
    }
    let outputURL = URL(fileURLWithPath: outputPath)

    var cropRect: CGRect? = nil
    if options.crop_width > 0 && options.crop_height > 0 {
        cropRect = CGRect(x: Int(options.crop_x), y: Int(options.crop_y), width: Int(options.crop_width), height: Int(options.crop_height))
    }

    var micDevice: AVCaptureDevice? = nil
    if let micIdCStr = options.microphone_id, let micId = String(cString: micIdCStr, encoding: .utf8) {
        micDevice = Recorder.getMicrophones().first { $0.uniqueID == micId }
    }

    do {
        var display: Any? = options.display_id
        #if canImport(ScreenCaptureKit)
        if #available(macOS 12.3, *) {
            let sem = DispatchSemaphore(value: 0)
            var displays: [Any] = []
            Task {
                displays = await Recorder.getDisplays()
                sem.signal()
            }
            sem.wait() // 等待异步获取Display列表完成
            if options.display_id != 0 {
                 display = displays.first { ($0 as? SCDisplay)?.displayID == options.display_id }
            } else {
                 display = displays.first
            }
        }
        #endif

        try recorder.start(
            outputURL: outputURL,
            bitrate: Int(options.bitrate),
            display: display,
            cropRect: cropRect,
            frameRate: Int(options.frame_rate),
            showCursor: options.show_cursor,
            microphoneDevice: micDevice,
            systemAudio: options.system_audio
        )
        return true
    } catch {
        print("[MacScreenRecorder-CBridge] Failed to start recording: \(error)")
        return false
    }
}

/// 停止录制
///
/// @param recorder_ptr `recorder_create`返回的不透明指针
@_cdecl("msr_recorder_stop")
public func recorder_stop(recorder_ptr: UnsafeMutableRawPointer?) {
    guard let recorder_ptr = recorder_ptr else { return }
    let recorder = Unmanaged<Recorder>.fromOpaque(recorder_ptr).takeUnretainedValue()
    recorder.stop()
}

// MARK: - Device and Permission Functions

/// 获取可用显示器列表
///
/// @return 指向CDisplayArray的指针，包含所有显示器信息。如果为nil则表示失败。使用后必须调用 `free_displays_list` 释放内存。
@_cdecl("msr_get_displays_list")
public func get_displays_list() -> OpaquePointer? {
    let sem = DispatchSemaphore(value: 0)
    var result: [Any] = []

    Task {
        result = await Recorder.getDisplays()
        sem.signal()
    }
    sem.wait() // 阻塞直到异步任务完成

    var displays = [CDisplay]()
    for item in result {
        var cDisplay: CDisplay?
        #if canImport(ScreenCaptureKit)
        if #available(macOS 12.3, *), let scDisplay = item as? SCDisplay {
            let name = "Display \(scDisplay.displayID) (\(scDisplay.width)x\(scDisplay.height))"
            cDisplay = CDisplay(id: scDisplay.displayID, name: strdup(name))
        }
        #endif
        
        if cDisplay == nil, let cgDisplayID = item as? CGDirectDisplayID {
             let name = "Display \(cgDisplayID)"
             cDisplay = CDisplay(id: cgDisplayID, name: strdup(name))
        }
        
        if let finalDisplay = cDisplay {
            displays.append(finalDisplay)
        }
    }

    let count = displays.count
    guard count > 0 else { return nil }
    
    let items_ptr = UnsafeMutablePointer<CDisplay>.allocate(capacity: count)
    items_ptr.initialize(from: displays, count: count)

    let array_ptr = UnsafeMutablePointer<CDisplayArray>.allocate(capacity: 1)
    array_ptr.initialize(to: CDisplayArray(count: Int32(count), items: items_ptr))

    return OpaquePointer(array_ptr)
}

/// 释放由 `get_displays_list` 创建的显示器列表指针
@_cdecl("msr_free_displays_list")
public func free_displays_list(array_ptr: OpaquePointer?) {
    guard let array_ptr = array_ptr else { return }
    let typed_array_ptr = UnsafeMutablePointer<CDisplayArray>(array_ptr)

    let displays = typed_array_ptr.pointee
    if let items = displays.items {
        for i in 0..<Int(displays.count) {
            if let name = items[i].name {
                free(UnsafeMutableRawPointer(mutating: name))
            }
        }
        items.deallocate()
    }
    
    typed_array_ptr.deallocate()
}

/// 获取可用麦克风列表
///
/// @return 指向CMicrophoneArray的指针，包含所有麦克风信息。如果为nil则表示失败。使用后必须调用 `free_microphones_list` 释放内存。
@_cdecl("msr_get_microphones_list")
public func get_microphones_list() -> OpaquePointer? {
    let mics = Recorder.getMicrophones()
    var cMics = [CMicrophone]()

    for mic in mics {
        cMics.append(CMicrophone(id: strdup(mic.uniqueID), name: strdup(mic.localizedName)))
    }

    let count = cMics.count
    guard count > 0 else { return nil }
    
    let items_ptr = UnsafeMutablePointer<CMicrophone>.allocate(capacity: count)
    items_ptr.initialize(from: cMics, count: count)

    let array_ptr = UnsafeMutablePointer<CMicrophoneArray>.allocate(capacity: 1)
    array_ptr.initialize(to: CMicrophoneArray(count: Int32(count), items: items_ptr))
    
    return OpaquePointer(array_ptr)
}

/// 释放由 `get_microphones_list` 创建的麦克风列表指针
@_cdecl("msr_free_microphones_list")
public func free_microphones_list(array_ptr: OpaquePointer?) {
    guard let array_ptr = array_ptr else { return }
    let typed_array_ptr = UnsafeMutablePointer<CMicrophoneArray>(array_ptr)

    let mics = typed_array_ptr.pointee
    if let items = mics.items {
        for i in 0..<Int(mics.count) {
            if let id = items[i].id {
                free(UnsafeMutableRawPointer(mutating: id))
            }
            if let name = items[i].name {
                free(UnsafeMutableRawPointer(mutating: name))
            }
        }
        items.deallocate()
    }

    typed_array_ptr.deallocate()
}

/// 检查是否具有屏幕录制权限
@_cdecl("msr_has_screen_recording_permission")
public func has_screen_recording_permission() -> Bool {
    return Recorder.hasScreenRecordingPermission
}

/// 检查是否具有麦克风权限
@_cdecl("msr_has_microphone_permission")
public func has_microphone_permission() -> Bool {
    return Recorder.hasMicrophonePermission
}

/// 请求屏幕录制权限（会弹出系统对话框）
@_cdecl("msr_request_screen_recording_permission")
public func request_screen_recording_permission() {
    Recorder.requestScreenRecordingPermission()
}

/// 请求麦克风权限（会弹出系统对话框）
/// 这是一个异步操作，调用后需要轮询 `has_microphone_permission` 来确认授权结果。
@_cdecl("msr_request_microphone_permission")
public func request_microphone_permission() {
    Recorder.requestMicrophonePermission { _ in
        // C API无法直接获得异步回调结果，调用方需要后续轮询权限状态
    }
}
