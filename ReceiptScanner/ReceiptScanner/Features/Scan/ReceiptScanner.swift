import UIKit
@preconcurrency import Vision

enum ScannerError: Error {
    case recognitionFailed
    case invalidImage
}

actor ReceiptScanner {
    
    struct TextFragment {
        let text: String
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomLeft: CGPoint
        let bottomRight: CGPoint
        let center: CGPoint
        let angle: CGFloat // in radians
        let confidence: Float
        var used: Bool = false
        
        init(obs: VNRecognizedTextObservation) {
            let candidate = obs.topCandidates(1).first
            self.text = candidate?.string ?? ""
            self.confidence = candidate?.confidence ?? 1.0
            self.topLeft = obs.topLeft
            self.topRight = obs.topRight
            self.bottomLeft = obs.bottomLeft
            self.bottomRight = obs.bottomRight
            
            // Calculate center
            self.center = CGPoint(
                x: (topLeft.x + topRight.x + bottomLeft.x + bottomRight.x) / 4,
                y: (topLeft.y + topRight.y + bottomLeft.y + bottomRight.y) / 4
            )
            
            // Calculate angle based on the baseline (bottomLeft to bottomRight)
            self.angle = atan2(bottomRight.y - bottomLeft.y, bottomRight.x - bottomLeft.x)
        }
    }
    
    func scanForRawText(image: UIImage) async throws -> String {
        let cgOrientation = await MainActor.run {
            CGImagePropertyOrientation(image.imageOrientation)
        }
        
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
                
                var fragments = observations.map { TextFragment(obs: $0) }
                // Sort left-to-right to find neighbors
                fragments.sort { $0.center.x < $1.center.x }
                
                var reconstructedLines: [(text: String, sortY: CGFloat)] = []
                
                // Calculate average angle to help with top-to-bottom sorting later
                let avgAngle = fragments.count > 0 ? 
                    fragments.map { $0.angle }.reduce(0, +) / CGFloat(fragments.count) : 0
                
                for i in 0..<fragments.count {
                    if fragments[i].used { continue }
                    
                    var currentLine: [TextFragment] = []
                    var pivot = fragments[i]
                    fragments[i].used = true
                    currentLine.append(pivot)
                    
                    var foundNeighbor = true
                    while foundNeighbor {
                        foundNeighbor = false
                        var bestNeighborIndex: Int? = nil
                        var minDistance: CGFloat = CGFloat.greatestFiniteMagnitude
                        
                        for j in 0..<fragments.count {
                            if fragments[j].used { continue }
                            let candidate = fragments[j]
                            
                            // 1. Check if candidate is to the right of the pivot
                            if candidate.center.x > pivot.topRight.x - 0.01 {
                                
                                // 2. Calculate vertical offset relative to pivot's angled baseline
                                // Line equation from pivot center with pivot angle: 
                                // dy * (x - x0) - dx * (y - y0) = 0 where (dx, dy) is the angle vector
                                let dx = cos(pivot.angle)
                                let dy = sin(pivot.angle)
                                
                                // Point-to-line distance (vertical offset from the pivot's baseline)
                                let verticalOffset = abs(dy * (candidate.center.x - pivot.center.x) - dx * (candidate.center.y - pivot.center.y))
                                
                                // 3. Threshold: offset should be less than ~50% of pivot's height
                                let pivotHeight = sqrt(pow(pivot.topLeft.x - pivot.bottomLeft.x, 2) + pow(pivot.topLeft.y - pivot.bottomLeft.y, 2))
                                
                                if verticalOffset < (pivotHeight * 0.6) {
                                    let dist = candidate.center.x - pivot.center.x
                                    if dist < minDistance {
                                        minDistance = dist
                                        bestNeighborIndex = j
                                    }
                                }
                            }
                        }
                        
                        if let neighborIndex = bestNeighborIndex {
                            fragments[neighborIndex].used = true
                            currentLine.append(fragments[neighborIndex])
                            pivot = fragments[neighborIndex]
                            foundNeighbor = true
                        }
                    }
                    
                    let lineText = currentLine.map { $0.text }.joined(separator: " ")
                    let avgConfidence = currentLine.map { $0.confidence }.reduce(0, +) / Float(currentLine.count)
                    
                    // To sort lines top-to-bottom even when angled:
                    // Project the average center of the line onto a vector perpendicular to the avgAngle
                    let lineAvgX = currentLine.map { $0.center.x }.reduce(0, +) / CGFloat(currentLine.count)
                    let lineAvgY = currentLine.map { $0.center.y }.reduce(0, +) / CGFloat(currentLine.count)
                    
                    // Rotated Y coordinate: y' = y*cos(theta) - x*sin(theta)
                    // This gives us a stable "top-to-bottom" value regardless of receipt rotation
                    let sortY = lineAvgY * cos(avgAngle) - lineAvgX * sin(avgAngle)
                    
                    reconstructedLines.append((text: lineText, sortY: sortY))
                }
                
                // Sort lines from top (high sortY) to bottom (low sortY)
                // Note: Vision Y is 0 at bottom, 1 at top. So higher sortY is "further up".
                let sortedLines = reconstructedLines.sorted { $0.sortY > $1.sortY }.map { $0.text }
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
