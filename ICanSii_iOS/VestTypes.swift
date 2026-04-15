import Foundation
import Combine

struct VestCell: Identifiable, Hashable {
    enum Side {
        case left
        case right
    }

    let id: String
    let isBack: Bool
    let side: Side
    let column: Int
    let row: Int
}

struct VestActivationState: Equatable {
    var cells: [String: Float] = [:]

    static let allOff = VestActivationState(cells: [:])
}

protocol HapticTransport: AnyObject {
    func send(_ state: VestActivationState, timestamp: TimeInterval)
}

final class PreviewTransport: HapticTransport, ObservableObject {
    @Published private(set) var state: VestActivationState = .allOff

    func send(_ state: VestActivationState, timestamp: TimeInterval) {
        DispatchQueue.main.async {
            self.state = state
        }
    }
}

enum VestLayout {
    static let rowsPerSide = 5
    static let colsPerSide = 2

    static let all: [VestCell] = {
        var out: [VestCell] = []

        for isBack in [false, true] {
            for side in [VestCell.Side.left, .right] {
                for row in 0..<rowsPerSide {
                    for col in 0..<colsPerSide {
                        let sideChar = side == .left ? "L" : "R"
                        let layer = isBack ? "B" : "F"
                        let id = "\(layer)_\(sideChar)_r\(row)c\(col)"
                        out.append(
                            VestCell(
                                id: id,
                                isBack: isBack,
                                side: side,
                                column: col,
                                row: row
                            )
                        )
                    }
                }
            }
        }

        return out
    }()
}
