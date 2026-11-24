import CoreImage
import Foundation

/// Draws a QR code in a terminal, for pairing from the command line until
/// the menu bar app exists.
public enum TerminalQRCode {
    /// One row of `true` (dark) and `false` (light) per line of the code,
    /// with a light border around it, as scanners expect.
    public static func modules(for text: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }

        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(
            image, toBitmap: &pixels, rowBytes: width * 4, bounds: extent,
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let code = (0..<height).map { row in
            (0..<width).map { column in pixels[(row * width + column) * 4] < 128 }
        }
        // A light margin of our own: without one, a code drawn against a
        // dark terminal cannot be read.
        let margin = 2
        let emptyRow = [Bool](repeating: false, count: width + 2 * margin)
        let side = [Bool](repeating: false, count: margin)
        return [[Bool]](repeating: emptyRow, count: margin)
            + code.map { side + $0 + side }
            + [[Bool]](repeating: emptyRow, count: margin)
    }

    /// The code as lines of text. Colours are set explicitly, so it reads
    /// the same on a light and on a dark terminal.
    public static func lines(for text: String) -> [String]? {
        guard let modules = modules(for: text) else { return nil }
        let light = "\u{1B}[47m  "
        let dark = "\u{1B}[40m  "
        let reset = "\u{1B}[0m"
        return modules.map { row in row.map { $0 ? dark : light }.joined() + reset }
    }
}
