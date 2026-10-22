import AppKit
import XCTest
@testable import Zephyr

@MainActor final class PercentSliderTests: XCTestCase {
    func testLayerContentSurvivesZeroSizeThenLayout() {
        _ = NSApplication.shared
        let control = PercentSlider(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSView(frame: window.contentView!.bounds)
        host.wantsLayer = true
        window.contentView = host
        host.addSubview(control)
        control.updateLayer()
        control.frame = NSRect(x: 4, y: 30, width: 372, height: 32)
        host.layoutSubtreeIfNeeded()
        control.displayIfNeeded()
        XCTAssertEqual(control.layer?.sublayers?.count, 5)
        XCTAssertNotNil(control.layer?.sublayers?.first?.contents)
        XCTAssertEqual(control.layer?.sublayers?.last?.bounds.size, NSSize(width: 6, height: 20))
    }

    func testPointerTrackingPreviewsContinuouslyAndCommitsOnceOnRelease() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        let control = PercentSlider(frame: NSRect(x: 4, y: 30, width: 372, height: 32))
        window.contentView!.addSubview(control)
        control.minimumPercent = 21
        control.percent = 60
        var previews: [Double] = [], commits: [Double] = []
        control.preview = { previews.append($0) }
        control.commit = { commits.append($0) }
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: control.convert(NSPoint(x: x, y: 16), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        control.mouseDown(with: event(.leftMouseDown, 180))
        control.mouseDragged(with: event(.leftMouseDragged, 280))
        XCTAssertTrue(control.dragging)
        XCTAssertGreaterThan(control.percent, 70)
        XCTAssertTrue(commits.isEmpty)
        control.mouseDragged(with: event(.leftMouseDragged, -20))
        XCTAssertEqual(control.percent, 21)
        control.mouseUp(with: event(.leftMouseUp, -20))
        XCTAssertFalse(control.dragging)
        XCTAssertEqual(commits, [21])
        XCTAssertGreaterThanOrEqual(previews.count, 3)
    }

    func testAccessibilityValueCommitsAndRespectsHardwareFloor() {
        let control = PercentSlider(frame: NSRect(x: 0, y: 0, width: 372, height: 32))
        control.minimumPercent = 21
        var commits: [Double] = []
        control.commit = { commits.append($0) }
        control.setAccessibilityValue(NSNumber(value: 0))
        XCTAssertEqual(control.accessibilityValue() as? NSNumber, 21)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(commits, [21])
        control.isEnabled = false
        control.setAccessibilityValue(NSNumber(value: 100))
        XCTAssertEqual(control.percent, 21)
    }
}
