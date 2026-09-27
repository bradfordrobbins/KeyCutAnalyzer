import Foundation

enum Rasterizer {
    /// Even-odd fill. A pixel is set when its center lies inside the polygon.
    static func fill(polygon: [Point2D], width: Int, height: Int) -> BinaryImage {
        var pixels = [Bool](repeating: false, count: width * height)
        guard polygon.count >= 3, width > 0, height > 0 else {
            return BinaryImage(width: width, height: height, pixels: pixels)
        }

        for row in 0..<height {
            let scanY = Double(row) + 0.5
            var crossings: [Double] = []
            crossings.reserveCapacity(8)
            for index in 0..<polygon.count {
                let start = polygon[index]
                let end = polygon[(index + 1) % polygon.count]
                let y1 = start.y
                let y2 = end.y
                let straddles = (y1 <= scanY && y2 > scanY) || (y2 <= scanY && y1 > scanY)
                if !straddles { continue }
                let t = (scanY - y1) / (y2 - y1)
                crossings.append(start.x + t * (end.x - start.x))
            }
            crossings.sort()
            var pair = 0
            while pair + 1 < crossings.count {
                let left = crossings[pair]
                let right = crossings[pair + 1]
                // Centers with left <= x+0.5 <= right. Use a tiny inset so a center on an edge is stable.
                let first = Int(ceil(left - 0.5 - 1e-7))
                let last = Int(floor(right - 0.5 + 1e-7))
                if last >= first {
                    let clampedFirst = max(0, first)
                    let clampedLast = min(width - 1, last)
                    if clampedLast >= clampedFirst {
                        for column in clampedFirst...clampedLast {
                            pixels[row * width + column] = true
                        }
                    }
                }
                pair += 2
            }
        }
        return BinaryImage(width: width, height: height, pixels: pixels)
    }
}
