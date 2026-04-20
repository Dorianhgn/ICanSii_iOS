import CoreGraphics
import XCTest
import simd
@testable import ICanSii_iOS

final class VestMappingEngineTests: XCTestCase {
    private func obj(x: Float, y: Float, z: Float, id: Int = 1) -> TrackedObject3D {
        TrackedObject3D(
            id: id,
            classId: 0,
            className: "person",
            confidence: 0.9,
            position: SIMD3<Float>(x, y, z),
            velocity: .zero,
            speedSmoothed: 0,
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            inFOV: true,
            isPredictive: false,
            lastSeenTimestamp: 0,
            updatedTimestamp: 0
        )
    }

    func testAllOffBeyondThreshold() {
        let engine = VestMappingEngine()
        let state = engine.map(objects: [obj(x: 0, y: 0, z: -5.0)], timestamp: 0)

        XCTAssertTrue(VestLayout.all.allSatisfy { (state.cells[$0.id] ?? 0) == 0 })
    }

    func testLayoutIsTwoByFivePerFaceOnly() {
        XCTAssertEqual(VestLayout.all.count, 20)

        let front = VestLayout.all.filter { !$0.isBack }
        let back = VestLayout.all.filter { $0.isBack }
        XCTAssertEqual(front.count, 10)
        XCTAssertEqual(back.count, 10)

        for row in 0..<VestLayout.rowsPerFace {
            let frontCols = Set(front.filter { $0.row == row }.map { $0.column })
            let backCols = Set(back.filter { $0.row == row }.map { $0.column })
            XCTAssertEqual(frontCols, Set(0..<VestLayout.colsPerFace))
            XCTAssertEqual(backCols, Set(0..<VestLayout.colsPerFace))
        }
    }

    func testCloserObjectYieldsHigherIntensity() {
        let engine = VestMappingEngine()

        let far = engine.map(objects: [obj(x: 0, y: 0, z: -1.0)], timestamp: 0)
        let near = engine.map(objects: [obj(x: 0, y: 0, z: -0.3)], timestamp: 0.2)

        let farMax = far.cells.values.max() ?? 0
        let nearMax = near.cells.values.max() ?? 0
        XCTAssertGreaterThan(nearMax, farMax)
    }

    func testCentreWithinDeadzoneActivatesBothSides() {
        let engine = VestMappingEngine()
        let state = engine.map(objects: [obj(x: 0.05, y: 0, z: -0.5)], timestamp: 0)

        let left = VestLayout.all
            .filter { !$0.isBack && $0.side == .left }
            .map { state.cells[$0.id] ?? 0 }
            .reduce(0, +)

        let right = VestLayout.all
            .filter { !$0.isBack && $0.side == .right }
            .map { state.cells[$0.id] ?? 0 }
            .reduce(0, +)

        XCTAssertGreaterThan(left, 0)
        XCTAssertGreaterThan(right, 0)
        XCTAssertEqual(left, right, accuracy: 0.01)
    }

    func testRightBiasActivatesRightFullLeftOffside() {
        let engine = VestMappingEngine()
        // Portrait logical axes: right bias is produced by positive sensor Y.
        let state = engine.map(objects: [obj(x: 0, y: 0.5, z: -0.5)], timestamp: 0)

        let rightMax = VestLayout.all
            .filter { !$0.isBack && $0.side == .right }
            .map { state.cells[$0.id] ?? 0 }
            .max() ?? 0

        let leftMax = VestLayout.all
            .filter { !$0.isBack && $0.side == .left }
            .map { state.cells[$0.id] ?? 0 }
            .max() ?? 0

        XCTAssertGreaterThan(rightMax, leftMax)
        XCTAssertEqual(leftMax / max(rightMax, 1e-6), 0.25, accuracy: 0.08)
    }

    func testWatchdogTurnsOffWhenDetectionsStop() {
        let engine = VestMappingEngine()
        _ = engine.map(objects: [obj(x: 0, y: 0, z: -0.5)], timestamp: 0)

        let state = engine.map(objects: [], timestamp: 1.0)
        XCTAssertTrue(state.cells.values.allSatisfy { $0 == 0 })
    }

    func testBehindObjectActivatesBackSide() {
        let engine = VestMappingEngine()
        let state = engine.map(objects: [obj(x: 0, y: 0, z: 0.5)], timestamp: 0)

        let front = VestLayout.all
            .filter { !$0.isBack }
            .map { state.cells[$0.id] ?? 0 }
            .reduce(0, +)

        let back = VestLayout.all
            .filter { $0.isBack }
            .map { state.cells[$0.id] ?? 0 }
            .reduce(0, +)

        XCTAssertGreaterThan(back, front)
    }
}
