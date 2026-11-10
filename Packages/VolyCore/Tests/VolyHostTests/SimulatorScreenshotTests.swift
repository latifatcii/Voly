import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import VolyModels
@testable import VolyHost

final class SimulatorScreenshotTests: XCTestCase {
    /// 2×3 "framebuffer" (portrait): each pixel a distinct gray so every
    /// rotation is unambiguous. Row-major from the top-left.
    private let source: [[UInt8]] = [
        [10, 20],
        [30, 40],
        [50, 60],
    ]

    private func png(_ rows: [[UInt8]]) throws -> Data {
        let width = rows[0].count, height = rows.count
        var bytes: [UInt8] = []
        for row in rows { for value in row { bytes += [value, value, value, 255] } }
        let context = try XCTUnwrap(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixels(_ png: Data) throws -> [[UInt8]] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (0..<image.height).map { y in (0..<image.width).map { x in bytes[(y * image.width + x) * 4] } }
    }

    func test_portrait_and_unknown_pass_the_capture_through_untouched() throws {
        let data = try png(source)
        for orientation in [InterfaceOrientation.portrait, .unknown] {
            let upright = try SimulatorScreenshot.upright(png: data, orientation: orientation)
            XCTAssertEqual(upright.png, data)
            XCTAssertEqual([upright.pixelWidth, upright.pixelHeight], [2, 3])
        }
    }

    func test_landscapeRight_turns_the_framebuffer_counter_clockwise() throws {
        // Verified against a real simulator: with a landscapeRight interface
        // the framebuffer shows the UI turned clockwise.
        let upright = try SimulatorScreenshot.upright(png: try png(source), orientation: .landscapeRight)
        XCTAssertEqual([upright.pixelWidth, upright.pixelHeight], [3, 2])
        XCTAssertEqual(try pixels(upright.png), [
            [20, 40, 60],
            [10, 30, 50],
        ])
    }

    func test_landscapeLeft_turns_the_framebuffer_clockwise() throws {
        let upright = try SimulatorScreenshot.upright(png: try png(source), orientation: .landscapeLeft)
        XCTAssertEqual(try pixels(upright.png), [
            [50, 30, 10],
            [60, 40, 20],
        ])
    }

    func test_upsideDown_is_a_half_turn_at_the_same_size() throws {
        let upright = try SimulatorScreenshot.upright(png: try png(source), orientation: .portraitUpsideDown)
        XCTAssertEqual([upright.pixelWidth, upright.pixelHeight], [2, 3])
        XCTAssertEqual(try pixels(upright.png), [
            [60, 50],
            [40, 30],
            [20, 10],
        ])
    }

    func test_undecodable_input_is_an_error_not_a_crash() {
        XCTAssertThrowsError(try SimulatorScreenshot.upright(png: Data("nope".utf8), orientation: .landscapeLeft)) { error in
            XCTAssertEqual(error as? SimulatorScreenshot.ScreenshotError, .undecodable)
        }
    }

    func test_capture_uses_simctl_io_screenshot_for_that_device() async throws {
        final class FakeSimctl: ShellExecutor, @unchecked Sendable {
            var arguments: [String] = []
            var exitCode: Int32 = 0
            func run(executable: URL, arguments: [String], environment: [String: String]?) async throws -> ShellResult {
                self.arguments = arguments
                if exitCode == 0, let path = arguments.last { try Data("png-bytes".utf8).write(to: URL(fileURLWithPath: path)) }
                return ShellResult(exitCode: exitCode, stdout: Data(), stderr: Data("No devices are booted.\n".utf8))
            }
        }
        let shell = FakeSimctl()
        let data = try await SimulatorScreenshot(shell: shell).capturePNG(deviceUDID: "SIM-9")
        XCTAssertEqual(data, Data("png-bytes".utf8))
        XCTAssertEqual(Array(shell.arguments.prefix(5)), ["simctl", "io", "SIM-9", "screenshot", "--type=png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: shell.arguments.last!), "temp file is cleaned up")

        shell.exitCode = 164
        do {
            _ = try await SimulatorScreenshot(shell: shell).capturePNG(deviceUDID: "SIM-9")
            XCTFail("expected simctlFailed")
        } catch {
            XCTAssertEqual(
                error as? SimulatorScreenshot.ScreenshotError,
                .simctlFailed(code: 164, stderr: "No devices are booted.")
            )
        }
    }
}
