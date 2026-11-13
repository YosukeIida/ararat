import AppKit

/// The sidebar's grain: white specks whose alpha is `clamp(1.4·N − 0.35)` of a two-octave value
/// noise. The mock draws it as an SVG `feTurbulence` (fractalNoise, baseFrequency 0.85, two
/// octaves, stitched over the whole sidebar) under a `feColorMatrix` that keeps the colour white
/// and puts the noise in alpha (`reports/design-u20/generators/uifull-f/common.py`).
///
/// The strength is the layer's opacity, `Look.grain`: the tile carries none of its own, so
/// `opacity = grain` reproduces the mock at every percentage. How strong each percent looks is
/// the owner's to tune on the real app (§7: one gain, starting at 1).
///
/// The values here are the mock's visual values, not our structural 8 pt sizes.
enum LookGrainTile {
    /// The lattice's pitch. The mock's `baseFrequency="0.85"` gives features of about 1.18 pt;
    /// 1.2 pt keeps a whole number of cells in the tile.
    static let cell: Double = 1.2
    /// The tile's side in points: 100 cells of 1.2 pt. The lattice wraps at the edge, so the
    /// repeat has no seam.
    static let pointSize: CGFloat = 120
    /// The mock's alpha rule, and the field statistics that put its output on the mock's own mean
    /// (0.35) and standard deviation (0.16).
    static let alphaScale = 1.4
    static let alphaOffset = 0.35
    static let fieldMean = 0.5
    static let fieldDeviation = 0.16 / 1.4

    /// The mock's `feColorMatrix`: the noise `field` in 0…1 becomes the white specks' alpha.
    static func alpha(of field: Double) -> Double {
        min(1, max(0, alphaScale * field - alphaOffset))
    }

    /// One representation at `scale` pixels per point (1 → 120 px, 2 → 240 px), 120 pt large; the
    /// generator draws the same field at either pitch, so the features stay 1.2 pt on screen.
    static func tile(pointSize: CGFloat = LookGrainTile.pointSize, scale: CGFloat) -> NSImage {
        let side = pixels(pointSize: pointSize, scale: scale)
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
                                            bytesPerRow: side * 4, bitsPerPixel: 32),
              let bytes = bitmap.bitmapData else { return image }
        bitmap.size = NSSize(width: pointSize, height: pointSize)
        let values = field(pointSize: pointSize, scale: scale)
        for index in 0..<(side * side) {
            bytes[index * 4] = 255
            bytes[index * 4 + 1] = 255
            bytes[index * 4 + 2] = 255
            bytes[index * 4 + 3] = UInt8((alpha(of: values[index]) * 255).rounded())
        }
        image.addRepresentation(bitmap)
        return image
    }

    /// The noise at one sample per pixel, row-major from the top-left, normalised over the whole
    /// tile to `fieldMean` and `fieldDeviation` — that is what makes the alpha land on the mock's
    /// 0.35 and 0.16 whatever the lattice happens to draw.
    static func field(pointSize: CGFloat = LookGrainTile.pointSize, scale: CGFloat) -> [Double] {
        let side = pixels(pointSize: pointSize, scale: scale)
        let cells = max(2, Int((Double(pointSize) / cell).rounded()))
        let coarse = lattice(cells: cells, seed: 0x4152_4152)
        let fine = lattice(cells: cells * 2, seed: 0x4E4F_4953)
        let pitch = Double(pointSize) / Double(side)
        var values = [Double](repeating: 0, count: side * side)
        var sum = 0.0
        var squares = 0.0
        for y in 0..<side {
            let v = (Double(y) + 0.5) * pitch
            for x in 0..<side {
                let u = (Double(x) + 0.5) * pitch
                let first = value(coarse, cells: cells, u: u / cell, v: v / cell)
                let second = value(fine, cells: cells * 2, u: u / (cell / 2), v: v / (cell / 2))
                // The mock's fractalNoise halves each octave's amplitude: two parts coarse, one fine.
                let noise = (2 * first + second) / 3
                values[y * side + x] = noise
                sum += noise
                squares += noise * noise
            }
        }
        let count = Double(side * side)
        let mean = sum / count
        let deviation = max(1e-9, (squares / count - mean * mean).squareRoot())
        let gain = fieldDeviation / deviation
        for index in values.indices { values[index] = fieldMean + (values[index] - mean) * gain }
        return values
    }

    /// `cells × cells` random values in 0…1 from the LCG the old tile used, so the grain is the
    /// same in every launch, machine and test run.
    static func lattice(cells: Int, seed: UInt32) -> [Double] {
        var state = seed
        var values = [Double](repeating: 0, count: cells * cells)
        for index in values.indices {
            state = state &* 1664525 &+ 1013904223
            values[index] = Double((state >> 8) & 0xFFFF) / 65535
        }
        return values
    }

    /// Smoothed value noise. The lattice wraps at its edge, so the tile's two sides continue into
    /// each other and the repeat shows no seam.
    static func value(_ lattice: [Double], cells: Int, u: Double, v: Double) -> Double {
        let x = u.rounded(.down)
        let y = v.rounded(.down)
        let fx = u - x
        let fy = v - y
        let sx = fx * fx * (3 - 2 * fx)
        let sy = fy * fy * (3 - 2 * fy)
        let ix = Int(x)
        let iy = Int(y)
        func sample(_ i: Int, _ j: Int) -> Double {
            lattice[((j % cells) + cells) % cells * cells + ((i % cells) + cells) % cells]
        }
        let top = sample(ix, iy) * (1 - sx) + sample(ix + 1, iy) * sx
        let bottom = sample(ix, iy + 1) * (1 - sx) + sample(ix + 1, iy + 1) * sx
        return top * (1 - sy) + bottom * sy
    }

    static func pixels(pointSize: CGFloat, scale: CGFloat) -> Int {
        max(1, Int((pointSize * max(0.5, scale)).rounded()))
    }
}
