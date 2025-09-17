import XCTest
import ScreenCaptureKit
import AVFoundation
@testable import MacScreenRecorder

// 让测试类遵循 RecorderDelegate 协议
final class MacScreenRecorderTests: XCTestCase, RecorderDelegate {

    var recorder: Recorder!
    var finishExpectation: XCTestExpectation!
    var failureExpectation: XCTestExpectation!
    var outputURL: URL!
    var callbackOnMainThread: Bool?

    // setUpWithError(): 在每个测试用例运行前，这个方法会创建一个 Recorder 实例，设置其代理为测试类本身。同时，它会在用户的桌面上创建一个 "test" 目录，并为录屏文件生成一个唯一的输出路径。
    override func setUpWithError() throws {
        try super.setUpWithError()
        recorder = Recorder()
        recorder.delegate = self
        
        // 获取用户的桌面目录
        guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            XCTFail("Could not find Desktop directory.")
            return
        }
        
        // 在桌面上创建一个"test"目录（如果不存在）
        let outputDir = desktopURL.appendingPathComponent("test")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)
        
        // 在测试目录中创建一个唯一的URL
        let fileName = "test-recording-\(UUID().uuidString).mp4"
        outputURL = outputDir.appendingPathComponent(fileName)
        
        callbackOnMainThread = nil
    }
    
    // 为需要录屏的测试创建期望的辅助方法
    func setupRecordingExpectations() {
        finishExpectation = expectation(description: "Recording finished successfully and the delegate was called.")
        failureExpectation = expectation(description: "Recording failed and the delegate was called.")
        // 我们期望失败期望不被满足，所以将其反转
        failureExpectation.isInverted = true
    }

    // tearDownWithError(): 在每个测试用例结束后，清理所有实例和变量，确保测试之间相互独立。
    override func tearDownWithError() throws {
        recorder = nil
        finishExpectation = nil
        failureExpectation = nil
        outputURL = nil
        callbackOnMainThread = nil
        try super.tearDownWithError()
    }
    
    // 测试辅助方法 - 这个测试不需要录屏
    func testPermissionsAndDevices() async throws {
        print("开始测试辅助方法")
        let hasMicrophonePermission = Recorder.hasMicrophonePermission
        print("是否有麦克风权限：\(hasMicrophonePermission)")
        if !hasMicrophonePermission {
            Recorder.requestMicrophonePermission { granted in
                print("麦克风权限请求结果：\(granted)")
            }
        }
        let hasScreenRecordingPermission = Recorder.hasScreenRecordingPermission
        print("是否有录屏权限：\(hasMicrophonePermission)")
        if !hasScreenRecordingPermission {
            Recorder.requestScreenRecordingPermission()
        }
        let displays = await Recorder.getDisplays()
        for display in displays {
            if #available(macOS 12.3, *), let scDisplay = display as? SCDisplay {
                print("SCDisplay: \(scDisplay.displayID) \(scDisplay.frame)")
                // 在这里使用 scDisplay，它已经是 SCDisplay 类型了
            }
        }
        
        // 只要上面的 print 语句不崩溃，测试就视为通过。
        // 添加一个断言以明确表示测试成功。
        XCTAssertTrue(true, "此断言用于确认测试方法已成功执行完毕。")
    }

    // 基本成功路径：默认参数启动录屏并停止，产生文件
    func testScreenRecording_StartsAndStops_CreatesFile() async throws {
        setupRecordingExpectations()
        
        let displays = await Recorder.getDisplays()
        guard !displays.isEmpty else {
            XCTFail("No displays found to perform a recording test.")
            return
        }
        
        print("Starting recording to: \(outputURL.path)")
        // 使用第一个可用的显示器进行测试
        try recorder.start(outputURL: outputURL, fileType: .mp4, display: displays[0], cropRect: CGRect(x: 0, y: 0, width: 200, height: 200) )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            print("Stopping recording...")
            self?.recorder.stop()
        }
        
        await fulfillment(of: [finishExpectation, failureExpectation], timeout: 20.0)
        // 如库未承诺主线程回调，可放宽为非强制断言或在实现中统一派发到主线程
        XCTAssertEqual(callbackOnMainThread, true, "期望委托在主线程回调（若库未承诺主线程，请在实现中统一派发或放宽断言）")
    }

    // 验证产物可被 AVAsset 播放并且有合理时长
    func test_outputPlayableAndDuration() async throws {
        setupRecordingExpectations()
        
        let playableURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("playable-\(UUID().uuidString).mov")
        outputURL = playableURL

        try recorder.start(outputURL: outputURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.recorder.stop() }
        await fulfillment(of: [finishExpectation, failureExpectation], timeout: 20.0)

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(CMTimeGetSeconds(duration) > 0.5, "期望录制时长 > 0.5s，实际 \(CMTimeGetSeconds(duration))")
        
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable, "产物应可播放")
    }

    // MARK: - RecorderDelegate 方法

    func recorder(_ recorder: Recorder, didFinishWritingFile fileURL: URL) {
        print("Delegate callback: didFinishWritingFile to \(fileURL.path)")
        callbackOnMainThread = Thread.isMainThread

        // 断言来自委托的URL是我们期望的那个（不同用例会改写 outputURL）
        XCTAssertEqual(fileURL, outputURL)
        
        // 断言文件确实被创建了
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        XCTAssertTrue(fileExists, "The recorded file should exist at the specified path.")
        
        if finishExpectation != nil {
            finishExpectation.fulfill()
        }
    }

    func recorder(_ recorder: Recorder, didFailWithError error: Error) {
        // 若用例未显式期望失败，这里应使测试失败
        if failureExpectation != nil && failureExpectation.isInverted {
            XCTFail("Recorder failed unexpectedly with error: \(error)")
        }
        if failureExpectation != nil {
            failureExpectation.fulfill()
        }
    }
}