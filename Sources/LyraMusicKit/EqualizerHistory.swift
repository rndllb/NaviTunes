import Foundation

/// In-memory undo/redo stack for EQ band gain edits (last 50 snapshots).
struct EqualizerHistory: Equatable {
    static let maxDepth = 50

    private(set) var undoStack: [[Float]] = []
    private(set) var redoStack: [[Float]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoStepCount: Int { undoStack.count }

    mutating func recordUndo(before previous: [Float]) {
        let snapshot = EqualizerPreset.normalizedGains(previous)
        guard undoStack.last != snapshot else { return }
        undoStack.append(snapshot)
        if undoStack.count > Self.maxDepth {
            undoStack.removeFirst(undoStack.count - Self.maxDepth)
        }
        redoStack.removeAll()
    }

    mutating func undo(current: [Float]) -> [Float]? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(EqualizerPreset.normalizedGains(current))
        return previous
    }

    mutating func redo(current: [Float]) -> [Float]? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(EqualizerPreset.normalizedGains(current))
        return next
    }

    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
