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

    init(id: String = UUID().uuidString, name: String, color: String, shakes: Bool = true, archived: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.shakes = shakes
        self.archived = archived
    }

    var stored: [String: Any] { ["id": id, "name": name, "color": color, "shakes": shakes, "archived": archived] }

    init?(stored: [String: Any]) {
        guard let id = stored["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id, name: stored["name"] as? String ?? "Project", color: stored["color"] as? String ?? "#6C2ED6",
                  shakes: stored["shakes"] as? Bool ?? true, archived: stored["archived"] as? Bool ?? false)
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

    static func load(stored: [[String: Any]]?) -> ProjectList {
        ProjectList(all: (stored ?? []).compactMap(Project.init(stored:)))
    }

    static func load(from defaults: UserDefaults = .standard) -> ProjectList {
        load(stored: defaults.array(forKey: key) as? [[String: Any]])
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(all.map(\.stored), forKey: Self.key)
    }
}
