import CoreVideo
import CoreGraphics
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

enum FrameCropper {
    /// One full-frame decode, off the main actor. Call once per settle and
    /// share the result across all passage crops — the decode is the
    /// expensive step (full multi-megapixel conversion).
    static func image(from buffer: CVPixelBuffer) async -> CGImage? {
        await Task.detached(priority: .utility) {
            var cgImage: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &cgImage)
            return cgImage
        }.value
    }

    /// PNG bytes of the region covering `normalizedRect` (Vision bottom-left
    /// normalized) plus `padding` pixels each side; crop + encode run off the
    /// main actor.
    static func png(
        from image: CGImage?,
        normalizedRect: CGRect,
        padding: CGFloat = 16
    ) async -> Data? {
        guard let image else { return nil }
        return await Task.detached(priority: .utility) {
            encode(image: image, normalizedRect: normalizedRect, padding: padding)
        }.value
    }

    private static func encode(
        image: CGImage,
        normalizedRect: CGRect,
        padding: CGFloat
    ) -> Data? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let pad = padding * 2
        var rect = CGRect(
            x: normalizedRect.minX * w - pad,
            y: (1 - normalizedRect.maxY) * h - pad,
            width: normalizedRect.width * w + pad * 2,
            height: normalizedRect.height * h + pad * 2
        )
        rect = rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width > 1, rect.height > 1,
              let cropped = image.cropping(to: rect) else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cropped, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
