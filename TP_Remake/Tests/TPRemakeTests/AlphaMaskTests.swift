import XCTest
import CoreGraphics
@testable import TPRemake

final class AlphaMaskTests: XCTestCase {
    /// Image 4×4 : coin supérieur gauche opaque (2×2), le reste transparent.
    func testMaskFollowsImageOrientation() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 2, width: 2, height: 2))   // origine en bas : y 2…4 = haut de l'image
        let mask = try XCTUnwrap(AlphaMask(try XCTUnwrap(context.makeImage())))
        XCTAssertTrue(mask.isOpaque(x: 0, y: 0))
        XCTAssertTrue(mask.isOpaque(x: 1, y: 1))
        XCTAssertFalse(mask.isOpaque(x: 3, y: 0))
        XCTAssertFalse(mask.isOpaque(x: 0, y: 3))
        XCTAssertFalse(mask.isOpaque(x: -1, y: 0))
        XCTAssertFalse(mask.isOpaque(x: 4, y: 0))
    }
}
