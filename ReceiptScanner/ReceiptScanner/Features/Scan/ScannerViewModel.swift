import SwiftUI
import PhotosUI

@MainActor
@Observable
class ScannerViewModel {
    var selectedImage: UIImage?
    var recognizedText: String = ""
    var parsedReceipt: ParsedReceipt?
    var isScanning = false
    var errorMessage: String?
    
    func processImage(_ image: UIImage) {
        self.isScanning = true
        self.errorMessage = nil
        
        Task.detached(priority: .userInitiated) {
            let resized = ImageUtils.resizeImage(image)
            let scanner = ReceiptScanner()
            do {
                let rawText = try await scanner.scanForRawText(image: resized)
                let parsed = await ReceiptParser.parse(rawText: rawText)
                await MainActor.run {
                    self.selectedImage = resized
                    self.recognizedText = rawText
                    self.parsedReceipt = parsed
                    self.isScanning = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isScanning = false
                }
            }
        }
    }
}
