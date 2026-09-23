import AppKit
import SwiftUI

/// Which appearance the floating Context surfaces use.
///
/// `system` follows the current macOS appearance. Explicit `dark` and `light`
/// are literal overrides.
enum ContextAppearance: String, Codable, CaseIterable {
    case dark, light, system

    func resolved(against system: ColorScheme) -> ColorScheme {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return system
        }
    }
}

/// The visual constants shared by the Context pill, launch panel and status
/// mark. The configured colour is the light-appearance accent; dark appearance
/// lifts the same hue until it clears the charcoal surface.
enum ContextIdentity {
    static let defaultPrimary = "#5F46CA"
    static let radius: CGFloat = 6
    static let shadowOffset: CGFloat = 3

    static let lightSurface = NSColor(
        srgbRed: 0xF4 / 255, green: 0xF2 / 255, blue: 0xFD / 255, alpha: 1
    )
    static let darkSurface = NSColor(
        srgbRed: 0x28 / 255, green: 0x26 / 255, blue: 0x36 / 255, alpha: 1
    )

    /// `#RRGGBB`, normalised for display and comparison.
    static func normalised(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7, trimmed.first == "#",
              trimmed.dropFirst().allSatisfy({ $0.isHexDigit })
        else { return nil }
        return trimmed.uppercased()
    }

    static func nsColor(_ hex: String) -> NSColor {
        let effective = normalised(hex) ?? defaultPrimary
        let digits = effective.dropFirst()
        guard let value = UInt32(digits, radix: 16) else {
            return nsColor(defaultPrimary)
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Preserve the chosen hue while ensuring primary marks do not disappear
    /// into either Context surface. The configured value is left untouched
    /// whenever it already has 3:1 contrast; otherwise it moves toward the
    /// appearance's readable pole.
    static func accent(_ hex: String, dark: Bool) -> NSColor {
        let base = nsColor(hex).usingColorSpace(.sRGB) ?? nsColor(defaultPrimary)
        let surface = dark ? darkSurface : lightSurface
        if contrast(base, surface) >= 3 { return base }
        let pole = dark ? NSColor.white : NSColor.black
        for step in 1 ... 20 {
            let amount = CGFloat(step) / 20
            if let candidate = base.blended(withFraction: amount, of: pole),
               contrast(candidate, surface) >= 3 {
                return candidate
            }
        }
        return pole
    }

    /// Whichever neutral has more contrast with a filled accent. The accent is
    /// configurable, so its label cannot safely assume white or charcoal from
    /// the surrounding appearance alone.
    static func foreground(on color: NSColor) -> NSColor {
        contrast(.white, color) >= contrast(.black, color) ? .white : .black
    }

    private static func contrast(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let a = luminance(lhs)
        let b = luminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent)
            + 0.7152 * channel(rgb.greenComponent)
            + 0.0722 * channel(rgb.blueComponent)
    }
}

struct ContextTheme {
    let scheme: ColorScheme
    let primaryHex: String

    var dark: Bool { scheme == .dark }
    var foreground: Color { dark ? Color(hex: 0xEEEDFA) : Color(hex: 0x2D2848) }
    var muted: Color { dark ? Color(hex: 0xB3AEC9) : Color(hex: 0x6B6481) }
    var surface: Color { Color(nsColor: dark ? ContextIdentity.darkSurface : ContextIdentity.lightSurface) }
    var accent: Color { Color(nsColor: ContextIdentity.accent(primaryHex, dark: dark)) }
    /// Revision 09: a light graphic offset on charcoal, the original black
    /// offset on platinum. Both are opaque shapes with no blur.
    var hardShadow: Color {
        dark ? Color(red: 0.56, green: 0.54, blue: 0.65) : .black.opacity(0.8)
    }
    var edge: Color { foreground.opacity(0.65) }
    var controlFill: Color { foreground.opacity(dark ? 0.045 : 0.025) }
    var controlEdge: Color { muted.opacity(0.22) }
    /// Semantic warning colours stay amber/scarlet, but the platinum surface
    /// needs darker variants for 12-point text. These clear 4.5:1 there; dark
    /// appearance keeps the established Parrot colours.
    var caution: Color { dark ? Parrot.amber : Color(hex: 0x8A5A00) }
    var failure: Color { dark ? Parrot.scarlet : Color(hex: 0x9D3732) }
    /// Text set directly on the configurable accent.
    var onAccent: Color {
        let fill = ContextIdentity.accent(primaryHex, dark: dark)
        return Color(nsColor: ContextIdentity.foreground(on: fill))
    }
}

struct ContextSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let border: Color
    let theme: ContextTheme
    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(theme.hardShadow)
                    .offset(x: ContextIdentity.shadowOffset, y: ContextIdentity.shadowOffset)
                shape.fill(theme.surface)
            }
            .overlay(shape.strokeBorder(border, lineWidth: 1 / scale))
    }
}

extension View {
    func contextSurface<S: InsettableShape>(
        _ shape: S, border: Color, theme: ContextTheme
    ) -> some View {
        modifier(ContextSurface(shape: shape, border: border, theme: theme))
    }
}

private struct ContextPrimaryColorKey: EnvironmentKey {
    static let defaultValue = ContextIdentity.defaultPrimary
}

extension EnvironmentValues {
    var contextPrimaryColor: String {
        get { self[ContextPrimaryColorKey.self] }
        set { self[ContextPrimaryColorKey.self] = newValue }
    }
}

/// The compact Context/voice mark. A rounded open frame locates three voice
/// bars without turning into another microphone glyph or a signal-strength
/// staircase.
struct ContextVoiceMark: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 18
            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
            }
            var frame = Path()
            frame.move(to: CGPoint(x: 8 * scale, y: 3 * scale))
            frame.addLine(to: CGPoint(x: 5 * scale, y: 3 * scale))
            frame.addQuadCurve(
                to: CGPoint(x: 3 * scale, y: 5 * scale),
                control: CGPoint(x: 3 * scale, y: 3 * scale)
            )
            frame.addLine(to: CGPoint(x: 3 * scale, y: 13 * scale))
            frame.addQuadCurve(
                to: CGPoint(x: 5 * scale, y: 15 * scale),
                control: CGPoint(x: 3 * scale, y: 15 * scale)
            )
            frame.addLine(to: CGPoint(x: 8 * scale, y: 15 * scale))
            context.stroke(
                frame, with: .color(color),
                style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round)
            )
            for bar in [rect(9, 6, 2, 6), rect(12, 4, 2, 10), rect(15, 7, 2, 4)] {
                context.fill(
                    Path(roundedRect: bar, cornerRadius: scale), with: .color(color)
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

enum ContextStatusMark {
    enum State: Equatable {
        case idle, processing, recording, failure

        var accessibilityLabel: String {
            switch self {
            case .idle: return "\(AppVariant.displayName) idle"
            case .processing: return "\(AppVariant.displayName) processing"
            case .recording: return "\(AppVariant.displayName) recording"
            case .failure: return "\(AppVariant.displayName) needs attention"
            }
        }
    }

    /// Native 18-point status image. Idle release builds remain templates so
    /// macOS supplies the correct menu-bar colour in every appearance.
    static func image(
        state: State, primaryHex: String, dark: Bool, dev: Bool = AppVariant.isDev
    ) -> NSImage {
        let colour: NSColor
        let template: Bool
        switch state {
        case .idle:
            colour = dev ? ContextIdentity.accent(primaryHex, dark: dark) : .black
            template = !dev
        case .processing:
            colour = ContextIdentity.accent(primaryHex, dark: dark)
            template = false
        case .recording:
            colour = NSColor(srgbRed: 1, green: 0.56, blue: 0.05, alpha: 1)
            template = false
        case .failure:
            colour = NSColor(srgbRed: 0.90, green: 0.25, blue: 0.27, alpha: 1)
            template = false
        }

        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            let host = NSHostingView(rootView: ContextVoiceMark(color: Color(nsColor: colour)))
            host.frame = bounds
            guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
            host.cacheDisplay(in: bounds, to: rep)
            rep.draw(in: bounds)
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }
}

/// The actual generated menu-bar images, shown together by `--panel-sheet` at
/// their native 18-point size in both appearances.
struct ContextStatusMarkPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let primaryHex: String

    private let states: [ContextStatusMark.State] = [
        .idle, .processing, .recording, .failure,
    ]

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                VStack(spacing: 5) {
                    Image(nsImage: ContextStatusMark.image(
                        state: state, primaryHex: primaryHex,
                        dark: colorScheme == .dark, dev: false
                    ))
                    .frame(width: 18, height: 18)
                    Text(state.accessibilityLabel.replacingOccurrences(
                        of: "\(AppVariant.displayName) ", with: ""
                    ))
                    .font(.system(size: 9))
                }
            }
        }
        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
        .padding(12)
        .background(colorScheme == .dark ? Color(hex: 0x242424) : Color.white)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
