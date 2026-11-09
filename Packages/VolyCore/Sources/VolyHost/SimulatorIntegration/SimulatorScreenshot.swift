import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VolyModels

/// Full-display capture through `simctl io screenshot` — the supported
/// path, independent of any agent, at the display's native pixel size.
public struct SimulatorScreenshot: Sendable {
    public enum ScreenshotError: Error, Equatable, LocalizedError {
        case simctlFailed(code: Int32, stderr: String)
        case noImageProduced
        case undecodable

        public var errorDescription: String? {
            switch self {
            case .simctlFailed(let code, let stderr):
                return "simctl screenshot failed (\(code)): \(stderr)"
            case .noImageProduced:
                return "simctl reported success but produced no image."
            case .undecodable:
                return "The captured image could not be decoded."
            }
        }
    }

    private static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    private let shell: ShellExecutor

    public init(shell: ShellExecutor = SystemShellExecutor()) {
        self.shell = shell
    }

    /// PNG bytes of the simulator's main display, in the framebuffer's own
    /// (device-native, i.e. portrait-up) orientation.
    public func capturePNG(deviceUDID: String) async throws -> Data {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voly-screenshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await shell.run(
            executable: Self.xcrun,
            arguments: ["simctl", "io", deviceUDID, "screenshot", "--type=png", file.path],
            environment: nil
        )
        guard result.exitCode == 0 else {
            throw ScreenshotError.simctlFailed(
                code: result.exitCode,
                stderr: (String(data: result.stderr, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        guard let data = try? Data(contentsOf: file), !data.isEmpty else {
            throw ScreenshotError.noImageProduced
        }
        return data
    }

    public struct UprightImage: Equatable, Sendable {
        public let png: Data
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    /// `simctl` returns the framebuffer as the device holds it (portrait-up),
    /// so a landscape interface comes out sideways. Turn it so the interface
    /// reads upright. Quarter turns only swap the pixel grid's axes — no
    /// resampling, the image stays at native resolution.
    public static func upright(png: Data, orientation: InterfaceOrientation) throws -> UprightImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ScreenshotError.undecodable }

        // Clockwise quarter turns to apply to the framebuffer image.
        let quarterTurns: Int
        switch orientation {
        case .portrait, .unknown: quarterTurns = 0
        case .landscapeLeft: quarterTurns = 1
        case .portraitUpsideDown: quarterTurns = 2
        case .landscapeRight: quarterTurns = 3
        }
        guard quarterTurns != 0 else {
            return UprightImage(png: png, pixelWidth: image.width, pixelHeight: image.height)
        }

        let swapsAxes = quarterTurns % 2 == 1
        let width = swapsAxes ? image.height : image.width
        let height = swapsAxes ? image.width : image.height
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ScreenshotError.undecodable }
        context.interpolationQuality = .none
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        // CoreGraphics angles are counter-clockwise in its y-up space.
        context.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
        context.draw(image, in: CGRect(
            x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
            width: CGFloat(image.width), height: CGFloat(image.height)
        ))
        guard let rotated = context.makeImage() else { throw ScreenshotError.undecodable }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { throw ScreenshotError.undecodable }
        CGImageDestinationAddImage(destination, rotated, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.undecodable }
        return UprightImage(png: output as Data, pixelWidth: width, pixelHeight: height)
    }
}
