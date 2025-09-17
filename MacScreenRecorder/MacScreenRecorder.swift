//
// Recorder.swift
// Fixed for SCShareableContent / SCStreamOutput / CGDisplayStream issues
//

import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import CoreMedia
import Darwin // for dlsym/dlopen

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

// MARK: - Public API

public enum RecorderError: Error {
    case unsupportedOS
    case permissionDenied(String)
    case internalError(String)
}

public protocol RecorderDelegate: AnyObject {
    func recorder(_ recorder: Recorder, didFinishWritingFile fileURL: URL)
    func recorder(_ recorder: Recorder, didFailWithError error: Error)
}

public final class Recorder {
    public weak var delegate: RecorderDelegate?

    private var implementation: RecorderImpl?

    public init() {}



    public func start(
        outputURL: URL,
        fileType: AVFileType = .mov,
        bitrate: Int = 6_000_000,
        // screen options
        display: Any? = nil, // SCDisplay (>=12.3) or CGDirectDisplayID (legacy)
        cropRect: CGRect? = nil, // x,y,width,height in screen coords
        frameRate: Int = 30,
        showCursor: Bool = true,
        // audio options
        microphoneDevice: AVCaptureDevice? = nil,
        systemAudio: Bool = false
    ) throws {
        if microphoneDevice != nil {
            try AudioManager.requestMicrophonePermissionIfNeeded()
        }

        // Ensure outputURL is usable; if not, fall back to temporary directory.
        func safeOutputURL(_ url: URL) -> URL {
            let fm = FileManager.default
            let dir = url.deletingLastPathComponent()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
                if isDir.boolValue && fm.isWritableFile(atPath: dir.path) {
                    return url
                }
            } else {
                // Try to create directory
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
                    if fm.isWritableFile(atPath: dir.path) { return url }
                } catch {
                    // ignore and fall back
                }
            }
            // Fallback to temporary directory with same filename
            let tempDir = fm.temporaryDirectory
            let fallback = tempDir.appendingPathComponent(url.lastPathComponent)
            return fallback
        }

#if canImport(ScreenCaptureKit)
        // Compiling with modern SDK.
        if #available(macOS 12.3, *) {
            // Running on modern OS, use modern API.
            let safeURL = safeOutputURL(outputURL)
            let impl = SCRecorderImpl(outputURL: safeURL, fileType: fileType, bitrate: bitrate)
            impl.delegate = self
            try impl.start(display: display as? SCDisplay, cropRect: cropRect, frameRate: frameRate, showCursor: showCursor, microphoneDevice: microphoneDevice, systemAudio: systemAudio)
            implementation = impl
            return
        } else {
            // Running on older OS, but compiled with modern SDK.
            // The legacy implementation is not compiled. We cannot proceed.
            throw RecorderError.unsupportedOS
        }
#else
        // Compiling with legacy SDK. SCRecorderImpl is not available.
        // We must use LegacyRecorderImpl.
        if systemAudio {
            throw RecorderError.internalError("System audio recording requires macOS 12.3 or newer.")
        }
        let safeURL = safeOutputURL(outputURL)
        let impl = LegacyRecorderImpl(outputURL: safeURL, fileType: fileType, bitrate: bitrate)
        impl.delegate = self
        let displayID = (display as? CGDirectDisplayID) ?? CGMainDisplayID()
        try impl.start(displayID: displayID, cropRect: cropRect, frameRate: frameRate, showCursor: showCursor, microphoneDevice: microphoneDevice)
        implementation = impl
        return
#endif
    }

    public func stop() {
        implementation?.stop()
        implementation = nil
    }
}

fileprivate protocol RecorderImpl: AnyObject {
    var delegate: Recorder? { get set }
    func stop()
}

fileprivate extension Recorder {
    func forwardFinishedWriting(url: URL) { delegate?.recorder(self, didFinishWritingFile: url) }
    func forwardError(_ error: Error) { delegate?.recorder(self, didFailWithError: error) }
}

// MARK: - Simple AVAssetWriter wrapper

fileprivate final class SimpleAssetWriter {
    private let writer: AVAssetWriter
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    // Pixel buffer adaptor for more reliable video append
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelBufferAttributes: [String: Any]?

    // Expose writer status for diagnostics
    var currentStatus: AVAssetWriter.Status { writer.status }

    // Expose whether inputs were added (for debugging)
    var hasVideoInput: Bool { videoInput != nil }
    var hasAudioInput: Bool { audioInput != nil }

    private let defaultBitrate: Int

    init(outputURL: URL, fileType: AVFileType = .mov, defaultBitrate: Int = 6_000_000) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        self.defaultBitrate = defaultBitrate
        // We defer calling startWriting() and startSession() until the first sample buffer arrives.
        // This ensures that we can add inputs after initialization but before writing begins.
    }

    func configureVideo(width: Int, height: Int, bitrate: Int = 6_000_000, fps: Int = 30) {
        let usedBitrate = (bitrate == 6_000_000) ? self.defaultBitrate : bitrate
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: usedBitrate,
                AVVideoExpectedSourceFrameRateKey: fps
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) { writer.add(input); videoInput = input }
    }

    func configureAudio(sampleRate: Double = 44100.0, channels: Int = 1) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 128000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        if writer.canAdd(input) { writer.add(input); audioInput = input }
    }

    func startIfNeeded(at time: CMTime) {
        // If writer is idle, start writing and begin a session at the given time.
        // This is called upon receiving the first sample buffer for any stream.
        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: time)
        }
    }

    // Attempt to add a video input using the source format as a hint.
    // Returns true if an input was successfully added.
    func addVideoInputIfNeeded(sourceFormat: CMFormatDescription?) -> Bool {
        if videoInput != nil { return true }

        // Define output settings for H.264 compression, deriving dimensions from the source format.
        var settings: [String: Any]?
        if let fmt = sourceFormat, CMFormatDescriptionGetMediaType(fmt) == kCMMediaType_Video {
            let videoDesc = fmt as! CMVideoFormatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(videoDesc)
            settings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dims.width),
                AVVideoHeightKey: Int(dims.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: self.defaultBitrate, // 6 Mbps
                    AVVideoExpectedSourceFrameRateKey: 30,
                ]
            ]
        }

        let input: AVAssetWriterInput
        if let hint = sourceFormat {
            // Provide both output settings for compression and a source hint for format negotiation.
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: hint)
        } else {
            // Fallback for video without a format hint (less common).
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        }
        input.expectsMediaDataInRealTime = true

        // Prepare pixel buffer adaptor attributes for BGRA pixel format.
        // Extract width/height from the CMVideoFormatDescription if possible.
        var pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if let fmt = sourceFormat, CMFormatDescriptionGetMediaType(fmt) == kCMMediaType_Video {
            let videoDesc = fmt as! CMVideoFormatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(videoDesc)
            pbAttrs[kCVPixelBufferWidthKey as String] = Int(dims.width)
            pbAttrs[kCVPixelBufferHeightKey as String] = Int(dims.height)
        }

        let canAdd = writer.canAdd(input)
        if canAdd {
            writer.add(input)
            videoInput = input
            // create adaptor
            pixelBufferAttributes = pbAttrs
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                                      sourcePixelBufferAttributes: pixelBufferAttributes)
        }
        return canAdd
    }

    // Attempt to add an audio input using the provided audio format hint.
    func addAudioInputIfNeeded(formatDesc: CMAudioFormatDescription?) -> Bool {
        if audioInput != nil { return true }
        let settings: [String: Any]? = nil
        let input: AVAssetWriterInput
        if let hint = formatDesc {
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: hint)
        } else {
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        }
        input.expectsMediaDataInRealTime = true
        let canAdd = writer.canAdd(input)
        if canAdd {
            writer.add(input)
            audioInput = input
        }
        return canAdd
    }

    func appendVideo(sampleBuffer: CMSampleBuffer) -> Bool {
        // Try to use pixel buffer adaptor if available
        if let adaptor = pixelBufferAdaptor, let input = videoInput {
            if writer.status == .unknown {
                startIfNeeded(at: sampleBuffer.presentationTimeStamp)
            }
            guard input.isReadyForMoreMediaData else { return false }

            // Extract CVPixelBuffer from sample buffer
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let pts = sampleBuffer.presentationTimeStamp
                return adaptor.append(pb, withPresentationTime: pts)
            } else {
                return false
            }
        }

        // Fallback to previous behavior
        guard let input = videoInput else { return false }

        if writer.status == .unknown {
            startIfNeeded(at: sampleBuffer.presentationTimeStamp)
        }

        guard input.isReadyForMoreMediaData else {
            return false
        }

        return input.append(sampleBuffer)
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) -> Bool {
        guard let input = audioInput, input.isReadyForMoreMediaData else { return false }
        if writer.status == .unknown {
            startIfNeeded(at: sampleBuffer.presentationTimeStamp)
        }
        return input.append(sampleBuffer)
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        // If the writer is not in the writing state, it's an error.
        // Check for the .failed status and report the underlying error if available.
        guard writer.status == .writing else {
            if writer.status == .failed, let e = writer.error {
                completion(.failure(e))
            } else {
                // If status is unknown, completed, or cancelled, it's an invalid state to be in when finish() is called.
                // The most likely cause is that start() was never called or it was stopped before any data arrived.
                writer.cancelWriting() // Ensure we don't leave a file handle open.
                let error = RecorderError.internalError("Recording was stopped before any data could be captured. Status: \(writer.status.rawValue)")
                completion(.failure(error))
            }
            return
        }

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting {
            switch self.writer.status {
            case .completed:
                completion(.success(self.writer.outputURL))
            case .failed:
                completion(.failure(self.writer.error ?? RecorderError.internalError("Writer failed with an unknown error.")))
            default:
                completion(.failure(RecorderError.internalError("Writer finished with an unexpected status: \(self.writer.status.rawValue)")))
            }
        }
    }

    @available(macOS 10.15, *)
    func finish() async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            finish { result in
                continuation.resume(with: result)
            }
        }
    }
}

// MARK: - ScreenCaptureKit implementation (macOS 12.3+)

#if canImport(ScreenCaptureKit)
@available(macOS 12.3, *)
fileprivate final class SCRecorderImpl: NSObject, RecorderImpl {
    weak var delegate: Recorder?
    private let writer: SimpleAssetWriter

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var micAudioEngine: AVAudioEngine?

    private enum State { case idle, recording, stopping, stopped }
    private var state = State.idle

    private class StreamOutput: NSObject, SCStreamOutput {
        let handler: (CMSampleBuffer, SCStreamOutputType) -> Void
        init(handler: @escaping (CMSampleBuffer, SCStreamOutputType) -> Void) {
            self.handler = handler
        }
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
            handler(sampleBuffer, outputType)
        }
    }

    init(outputURL: URL, fileType: AVFileType = .mov, bitrate: Int = 6_000_000) {
        do { writer = try SimpleAssetWriter(outputURL: outputURL, fileType: fileType, defaultBitrate: bitrate) }
        catch { fatalError("AssetWriter init failed: \(error)") }
        super.init()
    }

    func start(display: SCDisplay?, cropRect: CGRect?, frameRate: Int, showCursor: Bool, microphoneDevice: AVCaptureDevice?, systemAudio: Bool) throws {
        guard state == .idle else { return }
        state = .recording

        // Prepare audio input if requested
        if microphoneDevice != nil || systemAudio { writer.configureAudio() }

        let startTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return Result<Void, Error>.success(()) }
            do {
                let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let targetDisplay = display ?? availableContent.displays.first
                guard let display = targetDisplay else {
                    throw RecorderError.internalError("No displays found")
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.showsCursor = showCursor
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                if let rect = cropRect {
                    config.sourceRect = rect
                    config.width = Int(rect.width)
                    config.height = Int(rect.height)
                } else {
                    config.width = display.width
                    config.height = display.height
                }

                let output = StreamOutput { [weak self] sample, type in
                    guard let self = self, self.state == .recording else { return }
                    switch type {
                    case .screen:
                        if !self.writer.hasVideoInput {
                            _ = self.writer.addVideoInputIfNeeded(sourceFormat: CMSampleBufferGetFormatDescription(sample))
                        }
                        self.writer.startIfNeeded(at: sample.presentationTimeStamp)
                        _ = self.writer.appendVideo(sampleBuffer: sample)
                    case .audio:
                        if !self.writer.hasAudioInput {
                            guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
                            _ = self.writer.addAudioInputIfNeeded(formatDesc: fmt as CMAudioFormatDescription)
                        }
                        self.writer.startIfNeeded(at: sample.presentationTimeStamp)
                        _ = self.writer.appendAudio(sampleBuffer: sample)
                    @unknown default:
                        break
                    }
                }
                self.streamOutput = output

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                let outputQueue = DispatchQueue(label: "com.example.recorder.scstream.output")
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
                if systemAudio { try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: outputQueue) }

                try await stream.startCapture()
                self.stream = stream

                if let mic = microphoneDevice { try self.startMicrophoneCapture(device: mic) }

                return Result<Void, Error>.success(())
            } catch {
                return Result<Void, Error>.failure(error)
            }
        }

        // Synchronously wait up to 5 seconds for the task to complete (or fail).
        let sem = DispatchSemaphore(value: 0)
        var taskResult: Result<Void, Error>?
        Task {
            taskResult = await startTask.value
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + 5.0)
        if waitResult == .success {
            if let res = taskResult {
                switch res {
                case .success(()): break
                case .failure(let e):
                    state = .stopped
                    throw e
                }
            }
        } else {
            // Timed out — let background task continue running.
        }
    }

    func stop() {
        guard state == .recording else { return }
        state = .stopping

        Task {
            // This is a workaround for a race condition where the stream
            // might not have fully stopped before the writer is finished.
            // A small delay can help ensure all pending buffers are processed.
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

            try? await stream?.stopCapture()
            micAudioEngine?.stop()

            do {
                let url = try await writer.finish()
                await MainActor.run {
                    self.delegate?.forwardFinishedWriting(url: url)
                }
            } catch {
                await MainActor.run {
                    self.delegate?.forwardError(error)
                }
            }

            self.streamOutput = nil
            self.stream = nil
            self.state = .stopped
        }
    }
    
    // Helper to stringify writer status
    private func writerStatusString(_ status: AVAssetWriter.Status) -> String {
        switch status {
        case .unknown: return "unknown"
        case .writing: return "writing"
        case .completed: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        @unknown default: return "other"
        }
    }

    private func startMicrophoneCapture(device: AVCaptureDevice) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self = self, self.state == .recording else { return }
            if let sb = AudioConverter.sampleBuffer(from: buffer, at: time) {
                _ = self.writer.appendAudio(sampleBuffer: sb)
            }
        }
        try engine.start()
        micAudioEngine = engine
    }

}
#endif

// MARK: - Legacy implementation (CGDisplayStream) for macOS < 12.3 or fallback

#if !canImport(ScreenCaptureKit)
fileprivate final class LegacyRecorderImpl: NSObject, RecorderImpl {
    weak var delegate: Recorder?

    private var displayStream: CGDisplayStream?
    private var micAudioEngine: AVAudioEngine?

    private let writer: SimpleAssetWriter

    init(outputURL: URL, fileType: AVFileType = .mov, bitrate: Int = 6_000_000) {
        do { writer = try SimpleAssetWriter(outputURL: outputURL, fileType: fileType, defaultBitrate: bitrate) }
        catch { fatalError("AssetWriter init failed: \(error)") }
        super.init()
    }

    func start(displayID: CGDirectDisplayID = CGMainDisplayID(), cropRect: CGRect? = nil, frameRate: Int = 30, showCursor: Bool = true, microphoneDevice: AVCaptureDevice? = nil) throws {
        let w = cropRect != nil ? Int(cropRect!.width) : Int(CGDisplayPixelsWide(displayID))
        let h = cropRect != nil ? Int(cropRect!.height) : Int(CGDisplayPixelsHigh(displayID))
        writer.configureVideo(width: w, height: h, fps: frameRate)
        if microphoneDevice != nil { writer.configureAudio() }

        startDisplayStream(displayID: displayID, cropRect: cropRect, frameRate: frameRate, showCursor: showCursor)
        if let mic = microphoneDevice { try startMicrophoneCapture(device: mic) }
    }

    func stop() {
        stopDisplayStreamIfNeeded()
        micAudioEngine?.stop()
        writer.finish { [weak self] res in
            guard let self = self else { return }
            switch res {
            case .success(let url): DispatchQueue.main.async { self.delegate?.forwardFinishedWriting(url: url) }
            case .failure(let e): DispatchQueue.main.async { self.delegate?.forwardError(e) }
            }
        }
    }

    private func startDisplayStream(displayID: CGDirectDisplayID, cropRect: CGRect?, frameRate: Int, showCursor: Bool) {
        if #available(macOS 12.3, *) {
            let error = RecorderError.internalError("CGDisplayStream is not available on this version of macOS. Use ScreenCaptureKit.")
            self.delegate?.forwardError(error)
        } else {
            let queue = DispatchQueue(label: "cg.display.stream")
            let width = cropRect != nil ? Int(cropRect!.width) : Int(CGDisplayPixelsWide(displayID))
            let height = cropRect != nil ? Int(cropRect!.height) : Int(CGDisplayPixelsHigh(displayID))

            var props: CFDictionary? = nil
            var dict: [CFString: Any] = [:]
            dict[kCGDisplayStreamSourceRect] = cropRect as Any
            dict[kCGDisplayStreamMinimumFrameTime] = 1.0 / Double(frameRate)
            props = dict as CFDictionary

            displayStream = CGDisplayStream(dispatchQueueDisplay: displayID,
                                            outputWidth: width,
                                            outputHeight: height,
                                            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
                                            properties: props,
                                            queue: queue) { [weak self] status, displayTime, frameSurface, updateRef in
                guard let self = self else { return }
                guard status == .frameComplete else { return }
                guard let iosurface = frameSurface else { return }

                var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
                let err = CVPixelBufferCreateWithIOSurface(
                    kCFAllocatorDefault,
                    iosurface,
                    nil,
                    &unmanagedPixelBuffer
                )

                guard err == kCVReturnSuccess, let pixelBuffer = unmanagedPixelBuffer?.takeRetainedValue() else { return }

                if let sample = SampleBufferUtils.sampleBuffer(from: pixelBuffer, presentationTime: displayTime) {
                    _ = self.writer.appendVideo(sampleBuffer: sample)
                }
            }

            startDisplayStreamIfNeeded()
        }
    }

    private typealias CGDisplayStreamStartFunc = @convention(c) (CGDisplayStream?) -> CGError
    private typealias CGDisplayStreamStopFunc  = @convention(c) (CGDisplayStream?) -> CGError

    private func startDisplayStreamIfNeeded() {
        guard let stream = displayStream else { return }
        if let sym = dlsymRTLD("CGDisplayStreamStart") {
            let fn = unsafeBitCast(sym, to: CGDisplayStreamStartFunc.self)
            _ = fn(stream)
        }
    }

    private func stopDisplayStreamIfNeeded() {
        guard let stream = displayStream else { return }
        if let sym = dlsymRTLD("CGDisplayStreamStop") {
            let fn = unsafeBitCast(sym, to: CGDisplayStreamStopFunc.self)
            _ = fn(stream)
        }
    }

    private func dlsymRTLD(_ symbol: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW) else { return nil }
        defer { dlclose(handle) }
        return dlsym(handle, symbol)
    }

    private func startMicrophoneCapture(device: AVCaptureDevice) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self = self else { return }
            if let sb = AudioConverter.sampleBuffer(from: buffer, at: time) {
                _ = self.writer.appendAudio(sampleBuffer: sb)
            }
        }
        try engine.start()
        micAudioEngine = engine
    }

}
#endif

// MARK: - SampleBuffer helpers

fileprivate enum SampleBufferUtils {
    static func sampleBuffer(from pixelBuffer: CVPixelBuffer, presentationTime: UInt64) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let err = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
        guard err == noErr, let fd = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime.invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(presentationTime), timescale: 1_000_000_000),
                                        decodeTimeStamp: CMTime.invalid)
        var sampleBuffer: CMSampleBuffer?
        let createErr = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                                 imageBuffer: pixelBuffer,
                                                                 formatDescription: fd,
                                                                 sampleTiming: &timing,
                                                                 sampleBufferOut: &sampleBuffer)
        if createErr != noErr { return nil }
        return sampleBuffer
    }
}

fileprivate enum AudioConverter {
    static func sampleBuffer(from buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> CMSampleBuffer? {
        let abl = buffer.audioBufferList.pointee
        let mBuffers = abl.mBuffers
        guard let data = mBuffers.mData else { return nil }
        let dataSize = Int(mBuffers.mDataByteSize)

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: nil,
                                                        blockLength: dataSize,
                                                        blockAllocator: nil,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: dataSize,
                                                        flags: 0,
                                                        blockBufferOut: &blockBuffer)
        guard status == noErr, let bb = blockBuffer else { return nil }

        status = CMBlockBufferReplaceDataBytes(with: data, blockBuffer: bb, offsetIntoDestination: 0, dataLength: dataSize)
        if status != noErr { return nil }

        var asbd = buffer.format.streamDescription.pointee
        var formatDesc: CMAudioFormatDescription?
        status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                asbd: &asbd,
                                                layoutSize: 0,
                                                layout: nil,
                                                magicCookieSize: 0,
                                                magicCookie: nil,
                                                extensions: nil,
                                                formatDescriptionOut: &formatDesc)
        guard status == noErr, let fd = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(time.sampleTime), timescale: CMTimeScale(time.sampleRate)),
                                        decodeTimeStamp: CMTime.invalid)
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                      dataBuffer: bb,
                                      dataReady: true,
                                      makeDataReadyCallback: nil,
                                      refcon: nil,
                                      formatDescription: fd,
                                      sampleCount: CMItemCount(buffer.frameLength),
                                      sampleTimingEntryCount: 1,
                                      sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 0,
                                      sampleSizeArray: nil,
                                      sampleBufferOut: &sampleBuffer)
        if status != noErr { return nil }
        return sampleBuffer
    }
}

// MARK: - Permission helpers

fileprivate enum AudioManager {
    static func requestMicrophonePermissionIfNeeded() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in granted = ok; sem.signal() }
            sem.wait()
            if !granted { throw RecorderError.permissionDenied("Microphone access denied") }
        } else if status == .denied || status == .restricted {
            throw RecorderError.permissionDenied("Microphone access denied")
        }
    }
}

// Await a Task<Result<T, Error>> with a timeout (seconds). Returns the Result if completed within timeout, otherwise nil.
fileprivate func awaitTaskWithTimeout<T>(task: Task<Result<T, Error>, Never>, timeout: TimeInterval) async -> Result<T, Error>? {
    let nanoseconds = UInt64(timeout * 1_000_000_000)
    let timeoutTask = Task.detached { () -> Void in
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // Race the tasks: whichever completes first.
    let group = DispatchGroup()
    var result: Result<T, Error>?
    group.enter()
    Task {
        let r = await task.value
        result = r
        group.leave()
    }
    // Wait up to timeout using DispatchSemaphore to bridge async -> sync inside this helper.
    let sem = DispatchSemaphore(value: 0)
    Task {
        group.wait()
        sem.signal()
    }
    let waitResult = sem.wait(timeout: .now() + timeout)
    // cancel timeoutTask
    timeoutTask.cancel()
    return waitResult == .success ? result : nil
}
