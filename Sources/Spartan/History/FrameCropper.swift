import CoreVideo
import CoreGraphics
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

enum FrameCropper {
    /// Returns PNG bytes of the buffer region covering `normalizedRect`
    /// (Vision bottom-left normalized) plus `padding` pixels on each side.
    /// `padding` is in buffer pixels (not points) — cosmetic, so the slight
    /// Retina inflation is fine.
    static func png(
        from buffer: CVPixelBuffer,
        normalizedRect: CGRect,
        padding: CGFloat = 16
    ) -> Data? {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &cgImage)
        guard let cgImage else { return nil }

        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let pad = padding * 2
        var rect = CGRect(
            x: normalizedRect.minX * w - pad,
            y: (1 - normalizedRect.maxY) * h - pad,
            width: normalizedRect.width * w + pad * 2,
            height: normalizedRect.height * h + pad * 2
        )
        rect = rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width > 1, rect.height > 1,
              let cropped = cgImage.cropping(to: rect) else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cropped, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
