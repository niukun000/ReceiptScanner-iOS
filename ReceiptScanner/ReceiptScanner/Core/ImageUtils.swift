import UIKit
import CoreGraphics

struct ImageUtils {
    /// Downscales for OCR without destroying legibility of long receipts.
    /// Caps the SHORT side (text width drives OCR accuracy) and separately
    /// caps the long side so extreme captures don't blow up memory.
    nonisolated static func resizeImage(_ image: UIImage, maxShortSide: CGFloat = 1200, maxLongSide: CGFloat = 4800) -> UIImage {
        let size = image.size
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)

        let scale = min(maxShortSide / shortSide, maxLongSide / longSide, 1.0)
        guard scale < 1.0 else { return image }

        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true // receipts have no transparency; avoids alpha overhead
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    
    /// Rotates an image by a specific number of degrees.
    /// Useful for testing OCR robustness against tilted receipts.
    static func rotateImage(_ image: UIImage, degrees: CGFloat) -> UIImage {
        let radians = degrees * .pi / 180
        let newSize = CGRect(origin: .zero, size: image.size)
            .applying(CGAffineTransform(rotationAngle: radians))
            .integral.size
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { context in
            let origin = CGPoint(x: newSize.width / 2.0, y: newSize.height / 2.0)
            context.cgContext.translateBy(x: origin.x, y: origin.y)
            context.cgContext.rotate(by: radians)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
        }
    }
}
