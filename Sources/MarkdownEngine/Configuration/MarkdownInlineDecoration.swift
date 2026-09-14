import AppKit

public struct MarkdownInlineDecoration: Sendable {
    public struct Stop: Sendable {
        public let color: NSColor
        public let location: CGFloat
        public init(_ color: NSColor, at location: CGFloat) {
            self.color = color
            self.location = location
        }
    }
    public let background: [Stop]
    public let foreground: [Stop]
    public let fontSize: CGFloat
    public let lineHeight: CGFloat
    public let horizontalPadding: CGFloat
    public let cornerRadius: CGFloat

    public init(background: [Stop], foreground: [Stop], fontSize: CGFloat,
                lineHeight: CGFloat, horizontalPadding: CGFloat, cornerRadius: CGFloat) {
        self.background = background
        self.foreground = foreground
        self.fontSize = max(1, fontSize)
        self.lineHeight = lineHeight
        self.horizontalPadding = horizontalPadding
        self.cornerRadius = cornerRadius
    }

    func draw(_ stops: [Stop], in context: CGContext, bounds: CGRect) {
        let colors = stops.map { ($0.color.usingColorSpace(.sRGB) ?? $0.color).cgColor }
        let locations = stops.map(\.location)
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
              colors: colors as CFArray, locations: locations) else { return }
        context.drawLinearGradient(gradient,
            start: CGPoint(x: bounds.midX, y: bounds.minY),
            end: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
    }
}
