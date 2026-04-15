import Foundation
import Combine

struct VestCell: Identifiable, Hashable {
    enum Side {
        case left
        case right
    }

    let id: String
    let isBack: Bool
    let column: Int
    let row: Int

    var side: Side {
        column == 0 ? .left : .right
    }
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
    static let rowsPerFace = 5
    static let colsPerFace = 2

    static func cellID(isBack: Bool, row: Int, column: Int) -> String {
        "\(isBack ? "B" : "F")_r\(row)c\(column)"
    }

    static let all: [VestCell] = {
        var out: [VestCell] = []

        for isBack in [false, true] {
            for row in 0..<rowsPerFace {
                for col in 0..<colsPerFace {
                    out.append(
                        VestCell(
                            id: cellID(isBack: isBack, row: row, column: col),
                            isBack: isBack,
                            column: col,
                            row: row
                        )
                    )
                }
            }
        }

        return out
    }()
}
