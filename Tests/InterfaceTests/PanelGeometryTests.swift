import XCTest
@testable import Zephyr

/// Placement and outline of the anchored panel. These cover geometry only:
/// rendering, shadow and real status-item positions need the Mac.
final class PanelPlacementTests: XCTestCase {
    private let m = PanelMetrics.standard
    /// 14" MacBook Pro: 38 pt notched menu bar.
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let body = CGSize(width: 344, height: 420)

    /// A status item 38 pt tall at the top of `screen`, centred on `midX`.
    private func item(_ midX: CGFloat, on screen: CGRect, width: CGFloat = 44) -> CGRect {
        CGRect(x: midX - width / 2, y: screen.maxY, width: width, height: 38)
    }
    private func place(_ anchor: CGRect, _ visible: CGRect, body: CGSize? = nil, scale: CGFloat = 2) -> PanelPlacement {
        PanelPlacement(anchor: anchor, visibleFrame: visible, bodySize: body ?? self.body, scale: scale)
    }
    private func onGrid(_ value: CGFloat, _ scale: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual((value * scale).rounded(), value * scale, accuracy: 1e-9, "\(value) is off the \(scale)× pixel grid", file: file, line: line)
    }

    func testSpacingIsGenerousButConnected() {
        XCTAssertTrue((14...18).contains(m.bodyGap), "Body sits \(m.bodyGap) pt below the item")
        XCTAssertTrue((18...24).contains(m.screenMargin))
        XCTAssertLessThanOrEqual(m.tipGap, 5, "The tip stays visibly attached to the menu bar")
        let shape = m.pointer
        XCTAssertGreaterThanOrEqual(shape.flank - shape.shoulderTangent - shape.apexTangent, 0, "Shoulder and tip curves must not overlap")
    }

    func testCentredUnderItemWithBodyBelowPointer() {
        let anchor = item(1022, on: laptop), p = place(anchor, laptop)
        XCTAssertEqual(p.frame, CGRect(x: 850, y: 944 - 4 - 431, width: 344, height: 431))
        XCTAssertEqual(p.pointerX, 172)
        XCTAssertEqual(p.frame.minX + p.pointerX, anchor.midX)
        XCTAssertEqual(anchor.minY - (p.frame.maxY - m.pointerHeight), m.bodyGap, "Body top edge below the item")
        XCTAssertEqual(p.frame.height - m.pointerHeight, body.height, "Content height is the body; the pointer is added on top")
    }

    /// Status items live near the right edge: the body stops at the margin
    /// and the pointer moves to the item instead of staying centred.
    func testPointerFollowsItemWhenBodyIsHeldInsideTheScreen() {
        let anchor = item(1400, on: laptop), p = place(anchor, laptop)
        XCTAssertEqual(p.frame.maxX, laptop.maxX - m.screenMargin)
        XCTAssertEqual(p.frame.minX + p.pointerX, 1400)
        XCTAssertNotEqual(p.pointerX, p.frame.width / 2)
    }

    /// Before the pointer would have to leave the item, the body gives up
    /// some margin (never below the minimum).
    func testBodyTradesMarginToKeepPointerOnItem() {
        let anchor = item(1450, on: laptop), p = place(anchor, laptop)
        let inset = m.pointerInset(bodySize: body)
        XCTAssertLessThan(laptop.maxX - p.frame.maxX, m.screenMargin)
        XCTAssertGreaterThanOrEqual(laptop.maxX - p.frame.maxX, m.minimumScreenMargin)
        XCTAssertEqual(p.frame.minX + p.pointerX, 1450, "Exact, not half a pixel short")
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 875), q = place(item(-1440 + 60, on: left), left)
        XCTAssertGreaterThanOrEqual(q.frame.minX - left.minX, m.minimumScreenMargin)
        XCTAssertEqual(q.frame.minX + q.pointerX, -1380, "Left edge, negative origin")
        XCTAssertLessThanOrEqual(p.pointerX, p.frame.width - inset)
    }

    /// An item hard against the edge: the pointer stops clear of the corner
    /// curve and the body still keeps the minimum margin.
    func testExtremeEdgeClampsPointerClearOfCorner() {
        for (midX, visible) in [(CGFloat(1500), laptop), (-1430, CGRect(x: -1440, y: 0, width: 1440, height: 875))] {
            let p = place(item(midX, on: visible), visible)
            let inset = m.pointerInset(bodySize: body)
            XCTAssertGreaterThanOrEqual(p.frame.minX - visible.minX, m.minimumScreenMargin - 0.5)
            XCTAssertLessThanOrEqual(p.frame.maxX, visible.maxX - m.minimumScreenMargin + 0.5)
            XCTAssertGreaterThanOrEqual(p.pointerX, inset)
            XCTAssertLessThanOrEqual(p.pointerX, p.frame.width - inset)
        }
    }

    /// Secondary displays left of or below the main one have negative origins.
    func testNegativeScreenOrigins() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let a = place(item(-300, on: left), left)
        XCTAssertEqual(a.frame.minX + a.pointerX, -300)
        XCTAssertEqual(a.frame.maxY, left.maxY - m.tipGap)

        let below = CGRect(x: -400, y: -1080, width: 1920, height: 1055)
        let b = place(item(-250, on: below), below)
        XCTAssertEqual(b.frame.minX, below.minX + m.screenMargin)
        XCTAssertEqual(b.frame.minX + b.pointerX, -250)
        XCTAssertEqual(b.frame.maxY, below.maxY - m.tipGap)
        XCTAssertLessThan(b.frame.minY, 0)
    }

    func testPixelAlignmentAtOneAndTwoTimes() {
        for scale: CGFloat in [1, 2, 3] {
            let anchor = CGRect(x: 1003.3, y: 944, width: 41.7, height: 38)
            let p = place(anchor, laptop, body: CGSize(width: 344, height: 401.3), scale: scale)
            for value in [p.frame.minX, p.frame.minY, p.frame.width, p.frame.height, p.pointerX] { onGrid(value, scale) }
            XCTAssertGreaterThanOrEqual(p.frame.height - m.pointerHeight, 401.3, "Rounding never crops content")
            XCTAssertEqual(p.frame.minX + p.pointerX, anchor.midX, accuracy: 0.5 / scale + 1e-9)
        }
    }

    /// Settings opening or closing changes only the height: the top edge,
    /// the horizontal position and the pointer stay put.
    func testResizingKeepsTopAndPointer() {
        let anchor = item(1300, on: laptop)
        let closed = place(anchor, laptop, body: CGSize(width: 344, height: 360))
        let open = place(anchor, laptop, body: CGSize(width: 344, height: 610))
        XCTAssertEqual(closed.frame.maxY, open.frame.maxY)
        XCTAssertEqual(closed.frame.minX, open.frame.minX)
        XCTAssertEqual(closed.pointerX, open.pointerX)
        XCTAssertEqual(open.frame.height - closed.frame.height, 250)
    }

    func testTallBodyStopsAtScreenBottom() {
        let short = CGRect(x: 0, y: 0, width: 1280, height: 600)
        let p = place(item(900, on: short), short, body: CGSize(width: 344, height: 700))
        XCTAssertEqual(p.frame.minY, short.minY + m.minimumScreenMargin)
        XCTAssertEqual(p.frame.height, 711, "Content is never compressed")
    }

    func testNarrowScreenCentresBody() {
        let narrow = CGRect(x: 100, y: 0, width: 360, height: 700)
        let p = place(item(420, on: narrow), narrow)
        XCTAssertEqual(p.frame.midX, narrow.midX)
        let inset = m.pointerInset(bodySize: body)
        XCTAssertTrue((inset...(p.frame.width - inset)).contains(p.pointerX))
    }

    func testScreenChoiceFollowsTheItem() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982), left = CGRect(x: -1920, y: -120, width: 1920, height: 1080)
        XCTAssertEqual(PanelPlacement.screenIndex(for: CGRect(x: -500, y: 922, width: 40, height: 38), in: [main, left]), 1)
        XCTAssertEqual(PanelPlacement.screenIndex(for: CGRect(x: 800, y: 944, width: 40, height: 38), in: [main, left]), 0)
        // Centre just off the top of the main screen: the larger overlap wins.
        XCTAssertEqual(PanelPlacement.screenIndex(for: CGRect(x: 800, y: 970, width: 40, height: 38), in: [main, left]), 0)
        XCTAssertNil(PanelPlacement.screenIndex(for: CGRect(x: 5000, y: 5000, width: 40, height: 38), in: [main, left]))
    }
}

final class PanelSilhouetteTests: XCTestCase {
    private let m = PanelMetrics.standard
    private let size = CGSize(width: 344, height: 420)

    private func points(_ path: [PathElement]) -> [CGPoint] {
        path.flatMap { element -> [CGPoint] in
            switch element {
            case .move(let p), .line(let p): return [p]
            case .curve(let p, let c1, let c2): return [c1, c2, p]
            case .close: return []
            }
        }
    }
    /// Densely sampled outline (curves evaluated, not just control points).
    private func samples(_ path: [PathElement]) -> [CGPoint] {
        var out: [CGPoint] = [], last = CGPoint.zero
        for element in path {
            switch element {
            case .move(let p), .line(let p): out.append(p); last = p
            case .curve(let p, let c1, let c2):
                for i in 1...16 {
                    let t = CGFloat(i) / 16, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    out.append(CGPoint(x: a * last.x + b * c1.x + c * c2.x + d * p.x, y: a * last.y + b * c1.y + c * c2.y + d * p.y))
                }
                last = p
            case .close: break
            }
        }
        return out
    }

    func testOutlineIsClosedAndStaysInsideTheWindow() {
        for pointerX: CGFloat? in [nil, 172, 60, 290] {
            let path = PanelSilhouette.elements(bodySize: size, pointerX: pointerX)
            guard case .move(let start)? = path.first, case .close? = path.last else { return XCTFail("Not a closed outline") }
            XCTAssertEqual(path.dropLast().last?.point, start, "Ends where it began")
            let top = size.height + (pointerX == nil ? 0 : m.pointerHeight)
            for p in samples(path) {
                XCTAssertTrue((-1e-6...(size.width + 1e-6)).contains(p.x) && (-1e-6...(top + 1e-6)).contains(p.y), "\(p) is outside the window")
            }
        }
    }

    /// The rounded tip reaches exactly the top of the window, where the
    /// placement put `tipGap` below the item.
    func testTipReachesPointerHeightAndIsCentred() {
        let path = PanelSilhouette.elements(bodySize: size, pointerX: 172)
        let highest = samples(path).max { $0.y < $1.y }!
        XCTAssertEqual(highest.y, size.height + m.pointerHeight, accuracy: 0.01)
        XCTAssertEqual(highest.x, 172, accuracy: 0.01)
        XCTAssertEqual(samples(PanelSilhouette.elements(bodySize: size, pointerX: nil)).map(\.y).max()!, size.height, accuracy: 1e-9)
    }

    func testPointerIsMirrorSymmetric() {
        let x: CGFloat = 200
        let raised = samples(PanelSilhouette.elements(bodySize: size, pointerX: x)).filter { $0.y > size.height + 1e-6 }
        XCTAssertFalse(raised.isEmpty)
        for p in raised {
            let mirror = CGPoint(x: 2 * x - p.x, y: p.y)
            XCTAssertTrue(raised.contains { abs($0.x - mirror.x) < 0.15 && abs($0.y - mirror.y) < 0.15 }, "No mirror for \(p)")
        }
    }

    /// Shoulders and tip join the straight flanks and the top edge without a
    /// kink, so the pointer reads as part of the body, not a pasted triangle.
    func testPointerFlowsSmoothlyIntoTheBody() {
        let path = PanelSilhouette.elements(bodySize: size, pointerX: 172)
        let first = path.firstIndex { if case .curve = $0 { return $0.point!.y > size.height } else { return false } }!
        // shoulder curve, flank line, tip curve, flank line, shoulder curve
        let segment = Array(path[(first - 1)...(first + 4)])
        var previous: CGPoint?, previousEnd = path[first - 2].point!
        for element in segment {
            let (inTangent, outTangent): (CGPoint, CGPoint)
            switch element {
            case .line(let p): inTangent = p.minus(previousEnd); outTangent = inTangent; previousEnd = p
            case .curve(let p, let c1, let c2): inTangent = c1.minus(previousEnd); outTangent = p.minus(c2); previousEnd = p
            default: continue
            }
            if let previous { XCTAssertEqual(previous.angle, inTangent.angle, accuracy: 1e-6, "Kink at \(previousEnd)") }
            previous = outTangent
        }
        XCTAssertEqual(previous!.angle, 0, accuracy: 1e-6, "Leaves along the top edge")
        // Shoulders meet the top edge level.
        let shoulder = path[first - 1]
        if case .curve(let p, let c1, _) = shoulder { XCTAssertEqual(c1.y, size.height); XCTAssertGreaterThan(p.y, size.height) }
    }

    func testPointerNeverEntersACornerCurve() {
        let extent = m.cornerExtent(bodySize: size)
        for x: CGFloat in [-50, 0, 20, 344, 400] {
            let raised = samples(PanelSilhouette.elements(bodySize: size, pointerX: x)).filter { $0.y > size.height + 1e-6 }
            XCTAssertGreaterThanOrEqual(raised.map(\.x).min()!, extent)
            XCTAssertLessThanOrEqual(raised.map(\.x).max()!, size.width - extent)
        }
    }

    func testContinuousCornersMatchTheBodyRadius() {
        let path = PanelSilhouette.elements(bodySize: size, pointerX: nil)
        let extent = ContinuousCorner.extent * m.cornerRadius
        XCTAssertEqual(path.first?.point, CGPoint(x: extent, y: size.height))
        // Each corner leaves its edges `extent` from the corner, and at 45°
        // sits where a circular corner of the same radius would (the same
        // visual radius as the layer-clipped content).
        let nearCorner = samples(path).filter { $0.x < extent && $0.y < extent }
        XCTAssertEqual(nearCorner.map { $0.x + $0.y }.min()!, m.cornerRadius * (2 - 2.squareRoot()), accuracy: 0.2)
        // A tiny body shortens the radius instead of folding the outline.
        let small = PanelSilhouette.elements(bodySize: CGSize(width: 40, height: 30), pointerX: nil)
        for p in points(small) { XCTAssertTrue((0...40).contains(p.x) && (0...30).contains(p.y)) }
    }
}

private extension CGPoint {
    func minus(_ other: CGPoint) -> CGPoint { CGPoint(x: x - other.x, y: y - other.y) }
    var angle: CGFloat { atan2(y, x) }
}
