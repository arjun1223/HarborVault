import Foundation

struct BrowserLocation: Equatable {
    let folderID: UUID?
    let query: String
    var selected: Set<UUID> = []
    var lead: UUID? = nil
}

enum BrowserSelection {
    struct Result {
        let ids: Set<UUID>
        let anchor: UUID?
        let lead: UUID?
    }
    static func click(_ id: UUID, ordered: [UUID], selected: Set<UUID>, anchor: UUID?, shift: Bool, command: Bool) -> Result {
        guard ordered.contains(id) else { return Result(ids: selected, anchor: anchor, lead: nil) }
        if shift, let anchor, let start = ordered.firstIndex(of: anchor), let end = ordered.firstIndex(of: id) {
            let range = Set(ordered[min(start, end)...max(start, end)])
            return Result(ids: command ? selected.union(range) : range, anchor: anchor, lead: id)
        }
        if command {
            var ids = selected
            if !ids.insert(id).inserted { ids.remove(id) }
            return Result(ids: ids, anchor: id, lead: ids.contains(id) ? id : ordered.first { ids.contains($0) })
        }
        return Result(ids: [id], anchor: id, lead: id)
    }
    static func marquee(hits: Set<UUID>, initial: Set<UUID>, shift: Bool, command: Bool) -> Set<UUID> {
        command ? initial.symmetricDifference(hits) : shift ? initial.union(hits) : hits
    }
}
enum QuickViewKeyAction {
    case close, previous, next, ignore, passThrough
    static func action(for code: UInt16) -> QuickViewKeyAction {
        switch code {
        case 49, 53: return .close
        case 123: return .previous
        case 124: return .next
        case 125, 126: return .ignore
        default: return .passThrough
        }
    }
}

