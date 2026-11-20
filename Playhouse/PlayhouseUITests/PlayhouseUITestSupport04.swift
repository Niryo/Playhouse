import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
import SQLite3
import Vision

extension PlayhouseUITests {
    func copyFixtureFile(at source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.copyItem(at: source, to: destination)
        let sourceFolder = source.deletingLastPathComponent()
        let destinationFolder = destination.deletingLastPathComponent()
        guard sourceFolder.standardizedFileURL != destinationFolder.standardizedFileURL,
              let data = try? Data(contentsOf: source),
              let header = String(data: data.prefix(512), encoding: .utf8),
              header.contains("Deterministic stand-in for the `claude` CLI") || header.contains("Deterministic app-server peer") else { return }
        for companion in try manager.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil)
            where companion.pathExtension == "py" && companion.lastPathComponent.contains("_fixture_") {
            try Data(contentsOf: companion).write(
                to: destinationFolder.appendingPathComponent(companion.lastPathComponent), options: .atomic
            )
        }
    }

    /// Clicks a few points into the first characters of highlighted text, selecting nothing; the
    /// bubble reopens once the double-click interval passes, so callers wait for it. The text is
    /// scrolled into view first: after a send the transcript follows the newest turn, and a click
    /// on text above the viewport would land on whatever covers that point.
    func clickHighlightedText(_ text: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let scrollView = element("conversation-scroll-view")
        if scrollView.exists {
            XCTAssertTrue(scrollFullyIntoView(text, in: scrollView), "The highlighted text should scroll into view.", file: file, line: line)
            waitForStableFrame(text)
        }
        text.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: 12)).click()
    }
    func orangePixelFillRatio(in screenshot: XCUIScreenshot) -> Double {
        guard let image = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let bitmap = NSBitmapImageRep(cgImage: image)
        var count = 0
        var minX = bitmap.pixelsWide
        var maxX = 0
        var minY = bitmap.pixelsHigh
        var maxY = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if Self.isOrangePixel(color) {
                    count += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard count > 0 else { return 0 }
        let area = max(1, (maxX - minX + 1) * (maxY - minY + 1))
        return Double(count) / Double(area)
    }
    func assertHoverEmphasis(for element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // The pointer may already rest on this control from an earlier step (a relaunch keeps the
        // pointer still while the card re-renders under it), so park it elsewhere before sampling.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).hover()
        Thread.sleep(forTimeInterval: 0.3)
        let before = element.screenshot().image
        // XCTest cannot read NSCursor.current from the app process; hover inside the padded edge to verify that region receives hover events.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).hover()
        Thread.sleep(forTimeInterval: 0.2)
        let after = element.screenshot().image
        guard let changedPixels = changedPixelCount(before: before, after: after, step: max(1, Int(before.size.width) / 40), threshold: 0.08) else {
            XCTFail("Could not read control screenshots to verify hover emphasis.", file: file, line: line)
            return
        }
        XCTAssertGreaterThan(changedPixels, 5, "Hovering the control should visibly change its appearance.", file: file, line: line)
    }
    func element(containingAccessibilityText text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(Self.textPredicate(containing: text, caseInsensitive: true))
            .firstMatch
    }
    /// Matches an element whose label, text value, or (optionally) title contains `text`.
    /// `value CONTAINS` raises inside the app on a numeric value, such as the board's
    /// horizontal scroll bar, and that aborts the whole query until it times out, so a
    /// value is compared only on element types whose value is text.
    static func textPredicate(containing text: String, caseInsensitive: Bool, includeTitle: Bool = false) -> NSPredicate {
        let contains = caseInsensitive ? "CONTAINS[c]" : "CONTAINS"
        let format = "label \(contains) %@ OR (NOT (elementType IN %@) AND value \(contains) %@)" + (includeTitle ? " OR title \(contains) %@" : "")
        let arguments: [Any] = includeTitle ? [text, numericValueElementTypes, text, text] : [text, numericValueElementTypes, text]
        return NSPredicate(format: format, argumentArray: arguments)
    }
    /// Empty for an element that does not exist (yet), so it can be polled:
    /// reading `label` of a missing element fails the test on the spot.
    func accessibleLabelOrValue(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        if !element.label.isEmpty { return element.label }
        return element.value as? String ?? ""
    }
    func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !element.exists
    }
    /// How purple a board column's own surface reads: the mean of blue and red
    /// over green, sampled along a strip just inside its top edge, above its
    /// header and inside its padding, so only the column's fill shows there. The
    /// strip must lie within `container` (the scroll area showing the column), so
    /// a clipped column never samples whatever is drawn beyond it.
    func columnPurpleness(_ column: XCUIElement, visibleIn container: XCUIElement) throws -> CGFloat {
        XCTAssertTrue(column.waitToExist(timeout: 10), "\(column) should exist before sampling its tint.")
        let strip = CGRect(x: column.frame.minX + column.frame.width * 0.2, y: column.frame.minY + 4, width: column.frame.width * 0.6, height: 6)
        XCTAssertTrue(container.frame.contains(strip), "\(column)'s sampled strip \(strip) should be visible in \(container.frame).")
        let image = try XCTUnwrap(column.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil), "Could not read \(column)'s pixels.")
        let bitmap = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(bitmap.pixelsWide) / column.frame.width
        var total: CGFloat = 0, samples: CGFloat = 0
        for yPoint in stride(from: CGFloat(4), to: 10, by: 1) {
            for xFraction in stride(from: 0.2, through: 0.8, by: 0.05) {
                guard let color = bitmap.colorAt(x: Int(column.frame.width * xFraction * scale), y: Int(yPoint * scale))?.usingColorSpace(.deviceRGB) else { continue }
                total += (color.blueComponent + color.redComponent) / 2 - color.greenComponent
                samples += 1
            }
        }
        return try XCTUnwrap(samples > 0 ? total / samples : nil, "No pixels sampled in \(column).")
    }
    /// A scroll view's vertical scroller. Its frame is reported whether or not it is drawn.
    func verticalScroller(of scrollView: XCUIElement) throws -> XCUIElement {
        let bars = scrollView.scrollBars.allElementsBoundByIndex
        return try XCTUnwrap(bars.first { $0.frame.height > $0.frame.width }, "\(scrollView) should expose a vertical scroller: \(bars.map(\.frame)).")
    }
    func screenBitmap(_ screenshot: XCUIScreenshot) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil), "Could not read the screen's pixels.")
        return NSBitmapImageRep(cgImage: image)
    }
    func captureScreenBitmap() throws -> NSBitmapImageRep {
        try screenBitmap(XCUIScreen.main.screenshot())
    }
    /// Luminance samples across `region` (screen points) of a screen capture, in reading order, so
    /// two captures of the same unscrolled region compare pixel for pixel.
    func luminance(in region: CGRect, of bitmap: NSBitmapImageRep) throws -> [CGFloat] {
        let screenFrame = try XCTUnwrap(NSScreen.main?.frame)
        let scaleX = CGFloat(bitmap.pixelsWide) / screenFrame.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / screenFrame.height
        var samples: [CGFloat] = []
        for y in stride(from: region.minY + 1, to: region.maxY - 1, by: 2) {
            for x in stride(from: region.minX + 1, to: region.maxX - 1, by: 1) {
                guard let color = bitmap.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?.usingColorSpace(.deviceRGB) else { continue }
                samples.append(0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent)
            }
        }
        XCTAssertFalse(samples.isEmpty, "No pixels sampled in \(region).")
        return samples
    }
    /// The largest per-pixel luminance change between two samplings of the same region.
    func largestLuminanceChange(_ first: [CGFloat], _ second: [CGFloat]) -> CGFloat {
        zip(first, second).map { abs($0 - $1) }.max() ?? 0
    }
    /// Asserts that `scrollView`'s scroller stays hidden while the pointer is over `elsewhere`,
    /// shows at a subdued opacity for as long as the pointer rests over `scrollView`, and hides
    /// again once the pointer returns to `elsewhere`. Each sampling waits out AppKit's own fade
    /// after a scroll, so a scroller that only flashed reads as hidden. Returns the change that
    /// revealing the scroller made, which sizes a subdued scroller for later comparisons.
    @discardableResult
    func assertScrollerRevealsOnlyOnHover(_ scrollView: XCUIElement, elsewhere: XCUIElement, named name: String) throws -> CGFloat {
        let strip = try verticalScroller(of: scrollView).frame.intersection(scrollView.frame)
        XCTAssertFalse(strip.isNull, "The \(name) scroller should lie inside its scroll view.")
        elsewhere.hover()
        Thread.sleep(forTimeInterval: 2)
        let away = try luminance(in: strip, of: captureScreenBitmap())
        attachScreenshot(named: "The \(name) scroller is hidden while the pointer is elsewhere")
        scrollView.hover()
        Thread.sleep(forTimeInterval: 2)
        let hovered = try luminance(in: strip, of: captureScreenBitmap())
        attachScreenshot(named: "The \(name) scroller shows at a subdued opacity while its content is hovered")
        elsewhere.hover()
        Thread.sleep(forTimeInterval: 2)
        let awayAgain = try luminance(in: strip, of: captureScreenBitmap())
        attachScreenshot(named: "The \(name) scroller hides again once the pointer leaves")
        let revealChange = largestLuminanceChange(away, hovered)
        XCTAssertGreaterThan(revealChange, 0.06, "Hovering the \(name) should draw its scroller and keep it drawn while the pointer rests there (change \(revealChange)).")
        XCTAssertLessThan(revealChange, 0.4, "A hovered \(name) scroller that is not being dragged should be subdued, not fully opaque (change \(revealChange)).")
        let hideChange = largestLuminanceChange(away, awayAgain)
        XCTAssertLessThan(hideChange, 0.03, "Moving the pointer off the \(name) should hide its scroller again (change \(hideChange)).")
        return revealChange
    }
    /// The sidebar's drawn bottom edge. A collapsed bottom section keeps its content
    /// mounted at zero height, and its accessibility frame still counts toward the
    /// sidebar's, so the sidebar can report a frame past the window's bottom.
    func visibleSidebarBottom() -> CGFloat {
        min(element(withAccessibilityLabel: "Kanban sidebar").frame.maxY, app.windows["main"].frame.maxY)
    }
    /// Attaches the app as it looks now. On macOS a capture is always the whole screen, where the
    /// app's window is a small part of a large desktop; unless `fullScreen` asks for the desktop,
    /// the image is cut down to the app's windows and popovers at the screen's own pixel density,
    /// so text in a showcase screenshot stays readable.
    func attachScreenshot(named name: String, fullScreen: Bool = false) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = (fullScreen ? nil : appWindowsImage(of: screenshot)).map { XCTAttachment(image: $0) }
            ?? XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    /// Attaches the complete app window, including its surrounding panels and context.
    func attachAppWindowScreenshot(named name: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Attaches `element` alone, at native pixel density, for non-showcase diagnostics.
    func attachElementScreenshot(_ element: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    /// Attaches the region around `elements` together, at native pixel density, for a close-up
    /// of a small control and what sits next to it.
    func attachRegionScreenshot(_ elements: [XCUIElement], named name: String, padding: CGFloat = 8) {
        let screenshot = XCUIScreen.main.screenshot()
        guard let image = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let screen = NSScreen.main?.frame, screen.width > 0,
              let first = elements.first?.frame else { return }
        let region = elements.dropFirst().map(\.frame).reduce(first) { $0.union($1) }
            .insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(origin: .zero, size: screen.size))
        let scale = CGFloat(image.width) / screen.width
        let pixels = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale).integral
        guard !region.isEmpty, let cropped = image.cropping(to: pixels) else { return }
        let attachment = XCTAttachment(image: NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height)))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    /// Attaches the region around `elements` at native pixel density, for changed UI
    /// that is small within its window.
    func attachScreenshot(named name: String, around elements: [XCUIElement]) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = regionImage(of: screenshot, frames: elements.map(\.frame)).map { XCTAttachment(image: $0) }
            ?? XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    /// `screenshot` cropped to the union of the app's windows and popovers (such as the side chat
    /// bubble, which can reach past its window), with a small margin, or nil when it can't tell.
    func appWindowsImage(of screenshot: XCUIScreenshot) -> NSImage? {
        regionImage(of: screenshot, frames: (app.windows.allElementsBoundByIndex + app.popovers.allElementsBoundByIndex).map(\.frame))
    }
    func regionImage(of screenshot: XCUIScreenshot, frames: [CGRect]) -> NSImage? {
        guard let image = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let screen = NSScreen.main?.frame, screen.width > 0 else { return nil }
        let frames = frames.filter { !$0.isEmpty && $0.width > 1 && $0.height > 1 }
        guard let first = frames.first else { return nil }
        let region = frames.dropFirst().reduce(first) { $0.union($1) }
            .insetBy(dx: -16, dy: -16)
            .intersection(CGRect(origin: .zero, size: screen.size))
        // Element frames are in screen points from the top left, as the captured image is.
        let scale = CGFloat(image.width) / screen.width
        let pixels = CGRect(x: region.minX * scale, y: region.minY * scale, width: region.width * scale, height: region.height * scale).integral
        guard !region.isEmpty, let cropped = image.cropping(to: pixels) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
    func assertScreenshotIfVisible(named name: String) {
        attachScreenshot(named: name)
    }
    static func findAppBundle() throws -> URL {
        var directory = Bundle(for: PlayhouseUITests.self).bundleURL
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Playhouse.app", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "PlayhouseUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Couldn't locate the app bundle beside the UI test runner."
        ])
    }
}
