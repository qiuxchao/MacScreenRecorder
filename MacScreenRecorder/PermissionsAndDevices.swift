import Foundation
import AVFoundation
import CoreGraphics
import Darwin

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

extension Recorder {
    // MARK: - Permission checks & requests (moved)

    public static var hasScreenRecordingPermission: Bool {
        #if canImport(ScreenCaptureKit)
        if #available(macOS 12.3, *) {
            // 在同步函数中通过 Task + 信号量桥接 async 调用，避免直接 await 触发并发错误
            let sem = DispatchSemaphore(value: 0)
            var allowed: Bool = false
            Task.detached(priority: .userInitiated) {
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    allowed = true
                } catch {
                    allowed = false
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 0.5)
            return allowed
        }
        #endif
        let main = CGMainDisplayID()
        let queue = DispatchQueue(label: "com.example.recorder.permcheck")
        var hasPerm = true
        let sem = DispatchSemaphore(value: 0)
        let stream: CGDisplayStream?
        if #available(macOS 10.8, *) {
            // 动态查找 CGDisplayStreamCreateWithDispatchQueue，避免直接引用不可用的初始化器
            typealias CreateFn = @convention(c) (CGDirectDisplayID, Int, Int, Int32, CFDictionary?, DispatchQueue, @escaping CGDisplayStreamFrameAvailableHandler) -> Unmanaged<CGDisplayStream>?
            func dlsymFn(_ sym: String) -> UnsafeMutableRawPointer? {
                guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else { return nil }
                defer { dlclose(h) }
                return dlsym(h, sym)
            }
            if let createSym = dlsymFn("CGDisplayStreamCreateWithDispatchQueue"),
               let create = unsafeBitCast(createSym, to: CreateFn?.self) {
                let unmanaged = create(main, 1, 1, Int32(kCVPixelFormatType_32BGRA), nil, queue) { status, _, _, _ in
                    if status != .frameComplete {
                        hasPerm = false
                    }
                    sem.signal()
                }
                stream = unmanaged?.takeRetainedValue()
            } else {
                stream = nil
            }
        } else {
            stream = nil
        }
        if stream == nil { return false }
        typealias StartFn = @convention(c) (CGDisplayStream?) -> CGError
        typealias StopFn  = @convention(c) (CGDisplayStream?) -> CGError
        func dlsymFn(_ sym: String) -> UnsafeMutableRawPointer? {
            guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else { return nil }
            defer { dlclose(h) }
            return dlsym(h, sym)
        }
        if let s = dlsymFn("CGDisplayStreamStart"), let fn = unsafeBitCast(s, to: StartFn?.self) {
            _ = fn(stream)
        }
        _ = sem.wait(timeout: .now() + 0.5)
        if let s = dlsymFn("CGDisplayStreamStop"), let fn2 = unsafeBitCast(s, to: StopFn?.self) {
            _ = fn2(stream)
        }
        return hasPerm
    }

    public static var hasMicrophonePermission: Bool {
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public static func requestScreenRecordingPermission() {
        #if canImport(ScreenCaptureKit)
        if #available(macOS 12.3, *) {
            Task { 
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                } catch {
                    // Permission request failed, but that's expected if permission is denied
                }
            }
            return
        }
        #endif
        DispatchQueue.main.async {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                if let wsClass = NSClassFromString("NSWorkspace") as? NSObject.Type,
                   let shared = (wsClass as AnyObject).perform(NSSelectorFromString("sharedWorkspace"))?.takeUnretainedValue() {
                    _ = (shared as AnyObject).perform(NSSelectorFromString("openURL:"), with: url)
                } else {
                    _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [url.absoluteString])
                }
            }
        }
    }

    public static func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { ok in completion(ok) }
        } else {
            completion(status == .authorized)
        }
    }

    // MARK: - Device discovery (moved)

    public static func getDisplays() async -> [Any] {
        #if canImport(ScreenCaptureKit)
        if #available(macOS 12.3, *) {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) {
                return content.displays
            } else {
                return []
            }
        }
        #endif
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success else { return [] }
        var displays = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else { return [] }
        return displays
    }

    public static func getMicrophones() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone], mediaType: .audio, position: .unspecified)
        return session.devices
    }

    public static func getSpeakers() -> [AVCaptureDevice] {
        // Note: .builtInSpeaker is not available in AVCaptureDevice.DeviceType
        // Return empty array as speakers are typically output devices, not capture devices
        return []
    }
}
