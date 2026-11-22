import Foundation
import CoreGraphics
@preconcurrency import Vision

nonisolated struct TextFragment: Sendable {
    let text: String
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint
    let center: CGPoint
    let angle: CGFloat // in radians
    let confidence: Float

    init(obs: VNRecognizedTextObservation) {
        let candidate = obs.topCandidates(1).first
        self.init(
            text: candidate?.string ?? "",
            topLeft: obs.topLeft,
            topRight: obs.topRight,
            bottomLeft: obs.bottomLeft,
            bottomRight: obs.bottomRight,
            confidence: candidate?.confidence ?? 1.0
        )
    }

    init(text: String, topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint, confidence: Float = 1.0) {
        self.text = text
        self.confidence = confidence
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight

        self.center = CGPoint(
            x: (topLeft.x + topRight.x + bottomLeft.x + bottomRight.x) / 4,
            y: (topLeft.y + topRight.y + bottomLeft.y + bottomRight.y) / 4
        )

        // Baseline angle from bottomLeft -> bottomRight
        self.angle = atan2(bottomRight.y - bottomLeft.y, bottomRight.x - bottomLeft.x)
    }
}

/// One visual row of a receipt: fragments that share roughly the same vertical
/// position, pre-sorted left-to-right by reading order.
nonisolated struct TextRow: Sendable {
    let fragments: [TextFragment]

    var text: String { fragments.map(\.text).joined(separator: " ") }
}

nonisolated enum TextGeometry {
    /// Groups fragments into visual rows using vertical (Y) proximity only —
    /// row membership is decided independently of left-to-right order, which is
    /// applied afterward, within each row. This is the key structural fix over
    /// the old greedy nearest-neighbor-to-the-right walk, which coupled both
    /// decisions into one traversal and could jump across rows when column gaps
    /// were irregular.
    static func groupIntoRows(_ fragments: [TextFragment]) -> [TextRow] {
        guard !fragments.isEmpty else { return [] }

        let avgAngle = fragments.map(\.angle).reduce(0, +) / CGFloat(fragments.count)

        struct Positioned {
            let fragment: TextFragment
            let rowY: CGFloat
            let height: CGFloat
        }

        let positioned: [Positioned] = fragments.map { f in
            // Rotation-corrected Y: stable top-to-bottom ordering regardless of receipt skew.
            let rowY = f.center.y * cos(avgAngle) - f.center.x * sin(avgAngle)
            let height = sqrt(pow(f.topLeft.x - f.bottomLeft.x, 2) + pow(f.topLeft.y - f.bottomLeft.y, 2))
            return Positioned(fragment: f, rowY: rowY, height: height)
        }

        // Document-wide median height, not a per-pivot height, so one anomalously
        // small/large fragment (a lone digit, a logo) can't distort its own
        // row-membership threshold — this is what caused a name/price split
        // across two rows under the old per-pivot-relative threshold.
        let sortedHeights = positioned.map(\.height).sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]
        let bandFactor: CGFloat = 0.6
        let maxSpanFactor: CGFloat = 1.2

        // Vision's Y=0 is at the bottom, 1 at the top, so higher rowY is further up.
        let sorted = positioned.sorted { $0.rowY > $1.rowY }

        var rows: [[Positioned]] = []
        var currentRow: [Positioned] = []
        var runningSumY: CGFloat = 0
        var currentMinY: CGFloat = 0
        var currentMaxY: CGFloat = 0

        for item in sorted {
            if currentRow.isEmpty {
                currentRow = [item]
                runningSumY = item.rowY
                currentMinY = item.rowY
                currentMaxY = item.rowY
                continue
            }

            let runningMeanY = runningSumY / CGFloat(currentRow.count)
            let newMinY = min(currentMinY, item.rowY)
            let newMaxY = max(currentMaxY, item.rowY)
            let withinBand = abs(item.rowY - runningMeanY) <= medianHeight * bandFactor
            let withinSpan = (newMaxY - newMinY) <= medianHeight * maxSpanFactor

            if withinBand && withinSpan {
                currentRow.append(item)
                runningSumY += item.rowY
                currentMinY = newMinY
                currentMaxY = newMaxY
            } else {
                rows.append(currentRow)
                currentRow = [item]
                runningSumY = item.rowY
                currentMinY = item.rowY
                currentMaxY = item.rowY
            }
        }
        if !currentRow.isEmpty { rows.append(currentRow) }

        // Rows already fall out top-to-bottom from the sort above; sort each
        // row's fragments left-to-right for reading order.
        return rows.map { row in
            TextRow(fragments: row.map(\.fragment).sorted { $0.center.x < $1.center.x })
        }
    }

    /// Normalizes a captured price string: "," or " " as decimal separator -> ".",
    /// trailing "-" as a negative-amount marker.
    static func parsePriceToken(_ raw: String) -> Double? {
        var str = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let isNegative = str.hasSuffix("-")
        if isNegative { str = String(str.dropLast()) }
        guard let value = Double(str) else { return nil }
        return isNegative ? -value : value
    }
}
