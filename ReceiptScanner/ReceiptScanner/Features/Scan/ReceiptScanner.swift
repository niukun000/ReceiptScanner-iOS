import UIKit
@preconcurrency import Vision

enum ScannerError: Error {
    case recognitionFailed
    case invalidImage
}

actor ReceiptScanner {
    
    func scanForRawText(image: UIImage) async throws -> String {
        let uiOrientation = await MainActor.run { image.imageOrientation }
        let cgOrientation = CGImagePropertyOrientation(uiOrientation)
        
        guard let cgImage = image.cgImage else {
            throw ScannerError.invalidImage
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                
                var lines: [(text: String, y: CGFloat)] = []
                var fragments = observations.map { obs in
                    (text: obs.topCandidates(1).first?.string ?? "", box: obs.boundingBox, used: false)
                }.sorted { $0.box.minX < $1.box.minX }
                
                for i in 0..<fragments.count {
                    if fragments[i].used { continue }
                    var currentLine: [(text: String, box: CGRect)] = []
                    var lastBox = fragments[i].box
                    fragments[i].used = true
                    currentLine.append((fragments[i].text, fragments[i].box))
                    
                    var foundNeighbor = true
                    while foundNeighbor {
                        foundNeighbor = false
                        var bestNeighborIndex: Int? = nil
                        var closestDistance: CGFloat = CGFloat.greatestFiniteMagnitude

                        for j in 0..<fragments.count {
                            if fragments[j].used { continue }
                            let nextBox = fragments[j].box

                            if nextBox.minX >= lastBox.minX {
                                // 1. Calculate vertical overlap
                                let overlapMin = max(lastBox.minY, nextBox.minY)
                                let overlapMax = min(lastBox.maxY, nextBox.maxY)
                                let overlapHeight = max(0, overlapMax - overlapMin)
                                let minHeight = min(lastBox.height, nextBox.height)
                                
                                // 2. Calculate horizontal distance
                                let horizontalDist = nextBox.minX - lastBox.maxX
                                
                                // Stable vertical overlap: 40% height match
                                if overlapHeight > (minHeight * 0.4) {
                                    if horizontalDist < closestDistance {
                                        closestDistance = horizontalDist
                                        bestNeighborIndex = j
                                    }
                                }
                            }
                        }
                        
                        if let neighborIndex = bestNeighborIndex {
                            fragments[neighborIndex].used = true
                            currentLine.append((fragments[neighborIndex].text, fragments[neighborIndex].box))
                            lastBox = fragments[neighborIndex].box
                            foundNeighbor = true
                        }
                    }
                    
                    let avgY = currentLine.map { $0.box.midY }.reduce(0, +) / CGFloat(currentLine.count)
                    let lineText = currentLine.map { $0.text }.joined(separator: " ")
                    lines.append((text: lineText, y: avgY))
                }
                
                let sortedLines = lines.sorted { $0.y > $1.y }.map { $0.text }
                continuation.resume(returning: sortedLines.joined(separator: "\n"))
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation, options: [:])
            
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func scanAndParse(image: UIImage) async throws -> [ReceiptItemData] {
        let rawText = try await scanForRawText(image: image)
        return await ReceiptParser.parse(rawText: rawText).items
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
