import Foundation

/// `--dry-run` 출력용 줄 단위 diff. `diff -u`와 비슷한 모양이지만 patch용으로 쓰지는 않는다.
public enum TextDiff {
    private enum Op {
        case context(String)
        case removed(String)
        case added(String)

        var isChange: Bool {
            if case .context = self { return false }
            return true
        }
    }

    /// 바뀐 곳이 없으면 빈 문자열. `maxLineLength`를 넘는 줄은 잘라서 보여 준다(Orca 훅 명령은 한 줄이 수 KB다).
    public static func unified(
        old: String, new: String, oldLabel: String, newLabel: String,
        context: Int = 2, maxLineLength: Int? = nil
    ) -> String {
        let oldLines = lines(old)
        let newLines = lines(new)
        if oldLines == newLines { return "" }

        let difference = newLines.difference(from: oldLines)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        var ops: [Op] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removedOffsets.contains(oldIndex) {
                ops.append(.removed(oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, insertedOffsets.contains(newIndex) {
                ops.append(.added(newLines[newIndex]))
                newIndex += 1
            } else {
                ops.append(.context(oldLines[oldIndex]))
                oldIndex += 1
                newIndex += 1
            }
        }

        func show(_ text: String) -> String {
            guard let limit = maxLineLength, text.count > limit else { return text }
            return String(text.prefix(max(limit - 1, 1))) + "…"
        }

        var output = "--- \(oldLabel)\n+++ \(newLabel)\n"
        // 변경 사이 문맥이 문맥 두 배 이내면 한 덩어리로 묶는다.
        var ranges: [(first: Int, last: Int)] = []
        for index in ops.indices where ops[index].isChange {
            if let last = ranges.last, index - last.last - 1 <= context * 2 {
                ranges[ranges.count - 1].last = index
            } else {
                ranges.append((index, index))
            }
        }

        for range in ranges {
            let start = max(0, range.first - context)
            let stop = min(ops.count, range.last + 1 + context)
            var oldStart = 1
            var newStart = 1
            for op in ops[..<start] {
                switch op {
                case .context: oldStart += 1; newStart += 1
                case .removed: oldStart += 1
                case .added: newStart += 1
                }
            }
            let slice = ops[start..<stop]
            let oldCount = slice.filter { if case .added = $0 { false } else { true } }.count
            let newCount = slice.filter { if case .removed = $0 { false } else { true } }.count
            output += "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\n"
            for op in slice {
                switch op {
                case .context(let text): output += " " + show(text) + "\n"
                case .removed(let text): output += "-" + show(text) + "\n"
                case .added(let text): output += "+" + show(text) + "\n"
                }
            }
        }
        return output
    }

    private static func lines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var result = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if result.last == "" { result.removeLast() }
        return result
    }
}
