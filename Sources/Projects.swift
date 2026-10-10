import Foundation

/// Something the sand is run for, so the record can say how the day's time was spread. Time is kept against the
/// project's `id` alone: renaming or recolouring a project changes nothing that has already been counted, and the
/// statistics always show it under its current name and colour.
struct Project: Equatable {
    let id: String
    var name: String
    /// sRGB, as "#RRGGBB": the colour of the sand while this project is on, and of its part of every bar.
    var color: String
    /// Whether shaking the timer cycles through this project.
    var shakes: Bool
    /// Removed from the menus and from shaking, but kept so its time still has a name and a colour.
    var archived: Bool
    /// When it was last made or changed, so that a linked phone's copy and this one can be put together: the
    /// later change wins. Projects from before linking existed carry the distant past, and lose to any change.
    var updated: Date

    init(id: String = UUID().uuidString, name: String, color: String, shakes: Bool = true, archived: Bool = false,
         updated: Date = .distantPast) {
        self.id = id
        self.name = name
        self.color = color
        self.shakes = shakes
        self.archived = archived
        self.updated = updated
    }

    /// Whether two copies say the same, whenever each was written.
    func sameAs(_ other: Project) -> Bool {
        var other = other
        other.updated = updated
        return self == other
    }

    var stored: [String: Any] {
        ["id": id, "name": name, "color": color, "shakes": shakes, "archived": archived, "updated": updated.timeIntervalSince1970]
    }

    /// From the app's settings, or from a linked device's copy, which is written the same way.
    init?(stored: [String: Any]) {
        guard let id = stored["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id, name: stored["name"] as? String ?? "Project", color: stored["color"] as? String ?? "#6C2ED6",
                  shakes: stored["shakes"] as? Bool ?? true, archived: stored["archived"] as? Bool ?? false,
                  updated: (stored["updated"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantPast)
    }
}

/// Every project there has been, in the order the user made them, with the ones still in use in front of them.
struct ProjectList: Equatable {
    static let key = "projects"
    /// The id of the project time is being counted against now; absent when there is none.
    static let activeKey = "activeProject"
    /// What time counted against no project is called.
    static let untitled = "No project"

    var all: [Project] = []

    /// The projects offered in the menus and in Settings.
    var visible: [Project] { all.filter { !$0.archived } }

    func project(_ id: String?) -> Project? {
        guard let id, !id.isEmpty else { return nil }
        return all.first { $0.id == id }
    }

    /// A project's name, or what to call time counted against none, or against one that no longer exists.
    func name(of id: String) -> String {
        id.isEmpty ? Self.untitled : project(id)?.name ?? "Unknown project"
    }

    /// The project a shake moves on to from `current`: the next one marked for shaking, round and round. Nil when
    /// there is nowhere else to go.
    func nextForShake(after current: String?) -> Project? {
        let ring = visible.filter(\.shakes)
        guard !ring.isEmpty else { return nil }
        guard let here = ring.firstIndex(where: { $0.id == current }) else { return ring[0] }
        let next = ring[(here + 1) % ring.count]
        return next.id == current ? nil : next
    }

    /// This list after a change made here, with each project that is new or different from `before` stamped `now`.
    func stamped(since before: ProjectList, at now: Date) -> ProjectList {
        var list = self
        for index in list.all.indices {
            let project = list.all[index]
            if let old = before.project(project.id), old.sameAs(project) { continue }
            list.all[index].updated = now
        }
        return list
    }

    /// This list and a linked device's put together: every project either knows, each as it was last changed — the
    /// later `updated` wins, and on a tie this list's — in this list's order, with the ones only `other` has after them.
    func merged(with other: ProjectList) -> ProjectList {
        var list = deduplicated
        for theirs in other.all {
            if let index = list.all.firstIndex(where: { $0.id == theirs.id }) {
                // A stamp a hair later is the same stamp after a trip through another device's numbers, not a change.
                if theirs.updated.timeIntervalSince(list.all[index].updated) > Self.sameMoment { list.all[index] = theirs }
            } else {
                list.all.append(theirs)
            }
        }
        return list
    }

    /// Stamps this close together are the same moment, written down by two devices.
    static let sameMoment: TimeInterval = 0.001

    /// Whether two lists say the same about every project, in whatever order and however each device wrote the stamps:
    /// when they do, there is nothing to send.
    func agrees(with other: ProjectList) -> Bool {
        let mine = deduplicated, other = other.deduplicated
        guard mine.all.count == other.all.count else { return false }
        return mine.all.allSatisfy { mine in
            guard let theirs = other.project(mine.id) else { return false }
            return mine.sameAs(theirs) && abs(mine.updated.timeIntervalSince(theirs.updated)) <= Self.sameMoment
        }
    }

    static func load(stored: [[String: Any]]?) -> ProjectList {
        ProjectList(all: (stored ?? []).compactMap(Project.init(stored:))).deduplicated
    }

    /// Each project once: a second copy of an id, however it came about, is dropped, the first one kept.
    var deduplicated: ProjectList {
        var seen = Set<String>()
        return ProjectList(all: all.filter { seen.insert($0.id).inserted })
    }

    static func load(from defaults: UserDefaults = .standard) -> ProjectList {
        load(stored: defaults.array(forKey: key) as? [[String: Any]])
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(all.map(\.stored), forKey: Self.key)
    }
}
