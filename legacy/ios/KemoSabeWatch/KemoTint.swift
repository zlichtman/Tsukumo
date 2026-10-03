import CoreGraphics
import Foundation

/// Recolors Kemo's watch frames to the iPhone's character palette with the same
/// per-pixel formula as the iPhone's `kemoPlate` shader (KemoArtwork.metal).
/// watchOS has no Metal or SwiftUI shaders. The frames are rendered untinted, as
/// the iPhone draws Apricot, which is exactly what the shader recolors.
/// Also compiled into the iOS unit tests, which compare it with the real shader.
enum KemoTint {
    /// A gamma-encoded sRGB color, the space SwiftUI shaders work in by default.
    struct RGB: Equatable, Sendable {
        var r: Float, g: Float, b: Float
        init(r: Float, g: Float, b: Float) { self.r = r; self.g = g; self.b = b }
        /// "EF705B" or "#EF705B"; nil when malformed.
        init?(hex: String) {
            let digits = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            r = Float((value >> 16) & 0xFF) / 255
            g = Float((value >> 8) & 0xFF) / 255
            b = Float(value & 0xFF) / 255
        }
        /// WCAG relative luminance.
        var luminance: Float {
            func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        /// WCAG contrast ratio, from 1 to 21.
        func contrast(with other: RGB) -> Float {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        func mixed(with other: RGB, _ amount: Float) -> RGB {
            RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
        }
    }

    /// Recolors premultiplied RGBA8 pixels in place.
    static func recolor(_ pixels: UnsafeMutableBufferPointer<UInt8>, body: RGB, accent: RGB) {
        // The shader's reference cream and coral, so Apricot maps to itself.
        let bodyR = body.r / 0.965, bodyG = body.g / 0.91, bodyB = body.b / 0.82
        var i = 0
        while i + 3 < pixels.count {
            let alpha = Float(pixels[i + 3]) / 255
            if alpha > 0 {
                let scale = 1 / (255 * alpha)
                let r = min(1, Float(pixels[i]) * scale), g = min(1, Float(pixels[i + 1]) * scale), b = min(1, Float(pixels[i + 2]) * scale)
                // Saturated coral paint takes the accent; everything else takes the body color.
                let coral = smoothstep(0.25, 0.43, r - g)
                let light = r / 0.97
                pixels[i] = channel(r * bodyR + (accent.r * light - r * bodyR) * coral, alpha)
                pixels[i + 1] = channel(g * bodyG + (accent.g * light - g * bodyG) * coral, alpha)
                pixels[i + 2] = channel(b * bodyB + (accent.b * light - b * bodyB) * coral, alpha)
            }
            i += 4
        }
    }
    /// A recolored copy of an untinted frame, or nil if it can't be drawn.
    static func recolored(_ image: CGImage, body: RGB, accent: RGB) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        recolor(UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: context.bytesPerRow * height),
                body: body, accent: accent)
        return context.makeImage()
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
    private static func channel(_ value: Float, _ alpha: Float) -> UInt8 {
        UInt8((min(1, max(0, value)) * alpha * 255).rounded())
    }
}
