import SwiftUI
import PhotosUI
import PDFKit

@MainActor
@Observable
class ScannerViewModel {
    var selectedImage: UIImage?
    var recognizedText: String = ""
    var parsedReceipt: ParsedReceipt?
    var isScanning = false
    var errorMessage: String?
    
    func processPDF(data: Data) {
        self.isScanning = true
        self.errorMessage = nil
        self.selectedImage = nil // Reset preview for PDF
        
        Task.detached(priority: .userInitiated) {
            guard let pdfDocument = PDFDocument(data: data) else {
                await MainActor.run {
                    self.errorMessage = "Could not read PDF file."
                    self.isScanning = false
                }
                return
            }
            
            let scanner = ReceiptScanner()
            var combinedText = ""
            var firstPageImage: UIImage?
            
            for i in 0..<pdfDocument.pageCount {
                guard let page = pdfDocument.page(at: i) else { continue }
                
                // Render PDF page to a UIImage
                let pageRect = page.bounds(for: .mediaBox)
                let renderer = UIGraphicsImageRenderer(size: pageRect.size)
                let image = renderer.image { ctx in
                    UIColor.white.set()
                    ctx.fill(pageRect)
                    ctx.cgContext.translateBy(x: 0.0, y: pageRect.size.height)
                    ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
                    ctx.cgContext.drawPDFPage(page.pageRef!)
                }
                
                if i == 0 { firstPageImage = image }
                
                do {
                    let pageText = try await scanner.scanForRawText(image: image)
                    combinedText += pageText + "\n"
                } catch {
                    print("Error scanning page \(i): \(error)")
                }
            }
            
            let parsed = await ReceiptParser.parse(rawText: combinedText)
            await MainActor.run {
                self.selectedImage = firstPageImage // Use first page as preview
                self.recognizedText = combinedText
                self.parsedReceipt = parsed
                self.isScanning = false
            }
        }
    }
    
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
