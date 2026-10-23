import Foundation

// Geometry of the anchored panel: where the window goes under its status
// item, and the one-piece outline of a rounded body with a pointer rising
// from its top edge. Foundation-only, so placement and outline are testable
// without a window server. Coordinates are AppKit's: y grows upward.

/// Spacing and silhouette proportions, in points.
struct PanelMetrics: Equatable {
    /// Body corner radius. Corners are continuous (squircle) curves.
    var cornerRadius: CGFloat = 24
    /// From the body's top edge to the top of the pointer.
    var pointerHeight: CGFloat = 11
    /// Half the width of the pointer's (unrounded) triangle at the body edge.
    var pointerHalfBase: CGFloat = 12
    /// Rounding of the pointer's tip.
    var apexRadius: CGFloat = 4
    /// Concave rounding where the pointer flows into the body's top edge.
    var shoulderRadius: CGFloat = 7
    /// Air between the bottom of the menu bar item and the pointer tip.
    var tipGap: CGFloat = 4
    /// Preferred distance from the sides of the visible screen.
    var screenMargin: CGFloat = 20
    /// The panel gives up side margin down to this before its pointer
    /// would stop reaching the status item; also the bottom margin.
    var minimumScreenMargin: CGFloat = 8

    static let standard = PanelMetrics()

    /// Body top edge to the bottom of the menu bar item.
    var bodyGap: CGFloat { tipGap + pointerHeight }

    /// How far a continuous corner reaches along each edge, for a body of
    /// `size` (the curve is shortened on bodies too small for the radius).
    func cornerExtent(bodySize size: CGSize) -> CGFloat {
        ContinuousCorner.extent * ContinuousCorner.radius(cornerRadius, fitting: size)
    }

    /// Shape of the pointer's flanks after its tip is rounded: the ideal
    /// triangle is raised by `overshoot` so the rounded tip sits exactly
    /// `pointerHeight` above the body.
    var pointer: PointerShape {
        // The rounded tip falls below the ideal apex by r(1/cosθ − 1), and θ
        // depends on the ideal height, so settle the two by iteration.
        var overshoot: CGFloat = 0
        for _ in 0..<12 {
            let angle = atan2(pointerHeight + overshoot, pointerHalfBase)
            overshoot = apexRadius * (1 / cos(angle) - 1)
        }
        let height = pointerHeight + overshoot, angle = atan2(height, pointerHalfBase)
        return PointerShape(idealHeight: height, angle: angle,
                            shoulderTangent: shoulderRadius * tan(angle / 2),
                            apexTangent: apexRadius * tan(angle),
                            flank: (height * height + pointerHalfBase * pointerHalfBase).squareRoot())
    }

    /// Half the pointer's footprint on the body's top edge, shoulders included.
    var pointerHalfFootprint: CGFloat { pointerHalfBase + pointer.shoulderTangent }

    /// Closest the pointer's centre may come to either side of the body, so
    /// its shoulders never run into a corner curve.
    func pointerInset(bodySize size: CGSize) -> CGFloat {
        cornerExtent(bodySize: size) + pointerHalfFootprint
    }

    struct PointerShape: Equatable {
        /// Height of the unrounded triangle.
        let idealHeight: CGFloat
        /// Flank angle from the horizontal.
        let angle: CGFloat
        /// Distance from each base corner along both edges where the shoulder curve starts and ends.
        let shoulderTangent: CGFloat
        /// Distance from the ideal apex along each flank where the tip curve starts and ends.
        let apexTangent: CGFloat
        /// Length of one flank of the unrounded triangle.
        let flank: CGFloat
    }
}

/// Window frame and pointer position for an anchored panel.
struct PanelPlacement: Equatable {
    /// Window frame in screen coordinates, aligned to device pixels.
    let frame: CGRect
    /// Pointer centre in window coordinates, aligned to device pixels.
    let pointerX: CGFloat

    /// Places a body of `bodySize` under `anchor` (the status item's screen
    /// rectangle) on a screen whose usable area is `visibleFrame`.
    ///
    /// The body is centred under the item and kept `screenMargin` from the
    /// sides. Near an edge the pointer slides along the body to stay on the
    /// item; if even that cannot reach, the body trades side margin (down to
    /// `minimumScreenMargin`) for an accurate pointer.
    init(anchor: CGRect, visibleFrame visible: CGRect, bodySize: CGSize, scale: CGFloat, metrics m: PanelMetrics = .standard) {
        let pixel = PixelGrid(scale: scale)
        let width = pixel.ceil(bodySize.width), bodyHeight = pixel.ceil(bodySize.height)
        let height = bodyHeight + m.pointerHeight
        let inset = min(m.pointerInset(bodySize: CGSize(width: width, height: bodyHeight)), width / 2)
        let target = anchor.midX

        var x: CGFloat
        let low = visible.minX + m.screenMargin, high = visible.maxX - m.screenMargin - width
        if high < low {
            // Narrower than the body plus margins: centre on the screen.
            x = visible.midX - width / 2
        } else {
            x = pixel.round(min(max(target - width / 2, low), high))
            // Round toward the item so the pointer still reaches it exactly.
            if target - x < inset {
                x = min(x, max(pixel.floor(target - inset), pixel.ceil(visible.minX + m.minimumScreenMargin)))
            }
            if target - x > width - inset {
                x = max(x, min(pixel.ceil(target - (width - inset)), pixel.floor(visible.maxX - m.minimumScreenMargin - width)))
            }
        }
        x = pixel.round(x)

        let top = pixel.round(anchor.minY - m.tipGap)
        let y = pixel.round(max(top - height, visible.minY + m.minimumScreenMargin))
        frame = CGRect(x: x, y: y, width: width, height: height)
        pointerX = min(max(pixel.round(target) - x, pixel.ceil(inset)), pixel.floor(width - inset))
    }

    /// Index of the screen showing `anchor`: the one containing its centre,
    /// otherwise the one it overlaps most.
    static func screenIndex(for anchor: CGRect, in screens: [CGRect]) -> Int? {
        let centre = CGPoint(x: anchor.midX, y: anchor.midY)
        if let index = screens.firstIndex(where: { $0.contains(centre) }) { return index }
        let overlaps = screens.enumerated().map { ($0.offset, $0.element.intersection(anchor)) }
            .filter { !$0.1.isNull && $0.1.width * $0.1.height > 0 }
        return overlaps.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }
}

/// Rounds to device pixels at a backing scale (1× and 2× screens).
struct PixelGrid {
    let scale: CGFloat
    init(scale: CGFloat) { self.scale = scale.isFinite && scale > 0 ? scale : 1 }
    func round(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
    func ceil(_ value: CGFloat) -> CGFloat { (value * scale - 0.001).rounded(.up) / scale }
    func floor(_ value: CGFloat) -> CGFloat { (value * scale + 0.001).rounded(.down) / scale }
}

/// A drawing command; converted to CGPath on macOS.
enum PathElement: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
    case close

    var point: CGPoint? {
        switch self {
        case .move(let p), .line(let p), .curve(let p, _, _): return p
        case .close: return nil
        }
    }
}

/// The panel's outline: continuous-corner body with an optional pointer.
enum PanelSilhouette {
    /// Outline in window coordinates. The body occupies `bodySize` from the
    /// origin; the pointer, centred at `pointerX`, rises `pointerHeight`
    /// above it. With no pointer the outline is the body alone.
    static func elements(bodySize size: CGSize, pointerX: CGFloat?, metrics m: PanelMetrics = .standard) -> [PathElement] {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return [] }
        let r = ContinuousCorner.radius(m.cornerRadius, fitting: size)
        let extent = ContinuousCorner.extent * r
        var path: [PathElement] = [.move(CGPoint(x: extent, y: h))]

        let inset = m.pointerInset(bodySize: size)
        if let pointerX, inset <= w - inset {
            path += pointer(at: min(max(pointerX, inset), w - inset), top: h, metrics: m)
        }
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: w, y: h), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1)),
            (CGPoint(x: w, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: -1, y: 0)),
            (CGPoint(x: 0, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1)),
            (CGPoint(x: 0, y: h), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0))
        ]
        for (corner, incoming, outgoing) in corners {
            path += ContinuousCorner.elements(corner: corner, incoming: incoming, outgoing: outgoing, radius: r)
        }
        path.append(.close)
        return path
    }

    /// Left shoulder, flank, rounded tip, flank and right shoulder, drawn
    /// left to right along the body's top edge at `top`.
    private static func pointer(at x: CGFloat, top: CGFloat, metrics m: PanelMetrics) -> [PathElement] {
        let shape = m.pointer, b = m.pointerHalfBase
        let up = CGPoint(x: cos(shape.angle), y: sin(shape.angle)), down = CGPoint(x: up.x, y: -up.y)
        let apex = CGPoint(x: x, y: top + shape.idealHeight)
        let leftBase = CGPoint(x: x - b, y: top), rightBase = CGPoint(x: x + b, y: top)

        // Circular fillets as cubic Béziers (handle 4/3·tan(turn/4)·r).
        let shoulderHandle = 4 / 3 * tan(shape.angle / 4) * m.shoulderRadius
        let apexHandle = 4 / 3 * tan(shape.angle / 2) * m.apexRadius

        let s0 = CGPoint(x: leftBase.x - shape.shoulderTangent, y: top)
        let s1 = leftBase + up * shape.shoulderTangent
        let a0 = apex - up * shape.apexTangent, a1 = apex + down * shape.apexTangent
        let t0 = rightBase - down * shape.shoulderTangent
        let t1 = CGPoint(x: rightBase.x + shape.shoulderTangent, y: top)
        return [
            .line(s0),
            .curve(to: s1, control1: s0 + CGPoint(x: shoulderHandle, y: 0), control2: s1 - up * shoulderHandle),
            .line(a0),
            .curve(to: a1, control1: a0 + up * apexHandle, control2: a1 - down * apexHandle),
            .line(t0),
            .curve(to: t1, control1: t0 + down * shoulderHandle, control2: t1 - CGPoint(x: shoulderHandle, y: 0))
        ]
    }
}

/// Apple-style continuous ("squircle") corner, the curve CALayer draws for
/// `cornerCurve = .continuous`, as three Béziers per corner (the widely
/// used iOS 7 rounded-rect fit). Offsets are in units of the radius.
enum ContinuousCorner {
    /// How far along each edge the curve starts, relative to the radius.
    static let extent: CGFloat = 1.52866483

    /// Radius shortened so two corners fit along the shorter side.
    static func radius(_ radius: CGFloat, fitting size: CGSize) -> CGFloat {
        max(0, min(radius, min(size.width, size.height) / 2 / extent))
    }

    // First half of the corner as (along incoming edge back from the
    // corner, along outgoing edge); the second half mirrors it.
    private static let start = (1.52866483 as CGFloat, 0 as CGFloat)
    private static let handle1 = (1.08849323 as CGFloat, 0 as CGFloat)
    private static let handle2 = (0.86840689 as CGFloat, 0 as CGFloat)
    private static let join = (0.66993427 as CGFloat, 0.06549600 as CGFloat)
    private static let arcStart = (0.63149399 as CGFloat, 0.07491100 as CGFloat)
    private static let arcHandle = (0.37282392 as CGFloat, 0.16905899 as CGFloat)

    /// Corner at `corner`, reached travelling along `incoming` and left
    /// along `outgoing` (unit axis vectors). Begins with a line to the
    /// curve's start, so consecutive corners join with straight edges.
    static func elements(corner: CGPoint, incoming u: CGPoint, outgoing v: CGPoint, radius r: CGFloat) -> [PathElement] {
        func p(_ offset: (CGFloat, CGFloat)) -> CGPoint { corner - u * (offset.0 * r) + v * (offset.1 * r) }
        func mirrored(_ offset: (CGFloat, CGFloat)) -> CGPoint { p((offset.1, offset.0)) }
        return [
            .line(p(start)),
            .curve(to: p(join), control1: p(handle1), control2: p(handle2)),
            .line(p(arcStart)),
            .curve(to: mirrored(arcStart), control1: p(arcHandle), control2: mirrored(arcHandle)),
            .line(mirrored(join)),
            .curve(to: mirrored(start), control1: mirrored(handle2), control2: mirrored(handle1))
        ]
    }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
