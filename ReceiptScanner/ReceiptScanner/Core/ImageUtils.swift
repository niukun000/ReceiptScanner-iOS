import UIKit
import CoreGraphics

struct ImageUtils {
    nonisolated static func resizeImage(_ image: UIImage, maxDimension: CGFloat = 1200) -> UIImage {
        let size = image.size
        let widthRatio  = maxDimension / size.width
        let heightRatio = maxDimension / size.height
        guard widthRatio < 1.0 || heightRatio < 1.0 else { return image }
        
        let newScale = min(widthRatio, heightRatio)
        let newSize = CGSize(width: size.width * newScale, height: size.height * newScale)
        
        guard let cgImage = image.cgImage else { return image }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: Int(newSize.width), height: Int(newSize.height), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: newSize))
        
        if let scaledImage = context.makeImage() {
            return UIImage(cgImage: scaledImage, scale: image.scale, orientation: image.imageOrientation)
        }
        return image
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
