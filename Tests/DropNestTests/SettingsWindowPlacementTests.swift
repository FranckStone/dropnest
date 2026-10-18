import AppKit
import XCTest
@testable import DropNest

final class SettingsWindowPlacementTests: XCTestCase {
    func testOpeningOnDisplayToLeftOfMainScreen() {
        let screen = NSRect(x: -1920, y: 25, width: 1920, height: 1055)
        let oldFrame = NSRect(x: 400, y: 200, width: 880, height: 650)
        let placed = SettingsWindowPlacement.frame(oldFrame, in: screen, centered: true)
        XCTAssertTrue(screen.contains(placed))
        XCTAssertEqual(placed.midX, screen.midX)
        XCTAssertEqual(placed.midY, screen.midY)
        XCTAssertEqual(placed.size, oldFrame.size)
    }

    func testReopeningKeepsUserPositionOnSameDisplay() {
        let screen = NSRect(x: 1440, y: -900, width: 1600, height: 875)
        let frame = NSRect(x: 1500, y: -850, width: 880, height: 650)
        XCTAssertEqual(SettingsWindowPlacement.frame(frame, in: screen, centered: false), frame)
    }

    func testDisplayResizeClampsWindowToVisibleArea() {
        let screen = NSRect(x: 0, y: 80, width: 1280, height: 700)
        let frame = NSRect(x: 1000, y: 500, width: 880, height: 650)
        let placed = SettingsWindowPlacement.frame(frame, in: screen, centered: false)
        XCTAssertTrue(screen.contains(placed))
        XCTAssertEqual(placed.maxX, screen.maxX)
        XCTAssertEqual(placed.maxY, screen.maxY)
    }

    func testSmallDisplayKeepsTitlebarVisible() {
        let screen = NSRect(x: 0, y: 0, width: 800, height: 600)
        let frame = NSRect(x: 0, y: 0, width: 880, height: 650)
        let placed = SettingsWindowPlacement.frame(frame, in: screen, centered: true)
        XCTAssertEqual(placed.maxY, screen.maxY)
        XCTAssertEqual(placed.minX, screen.minX)
    }
}
