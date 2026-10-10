package io.github.and.sandtimer.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.UUID

/**
 * Something the sand is run for. Time is kept against the id alone, so renaming or recolouring never disturbs what
 * has been counted. The same as the Mac's `Project` (Sources/Projects.swift), and written the same way, so a linked
 * Mac and phone can share one list.
 */
data class Project(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val name: String,
    /** sRGB as "#RRGGBB". */
    val color: String,
    /** Kept for the Mac, where shaking the timer moves between the projects ticked for it. */
    val shakes: Boolean = true,
    /** Removed from the lists, but kept so its time still has a name and a colour. */
    val archived: Boolean = false,
    /** Seconds since 1970 of the last change, so two copies can be put together: the later change wins. */
    val updated: Double = DISTANT_PAST,
) {
    fun sameAs(other: Project) = copy(updated = 0.0) == other.copy(updated = 0.0)

    fun toJson() = buildJsonObject {
        put("id", id)
        put("name", name)
        put("color", color)
        put("shakes", shakes)
        put("archived", archived)
        put("updated", updated)
    }

    companion object {
        /** What Swift's `Date.distantPast` is in seconds since 1970: the stamp of a project from before linking. */
        const val DISTANT_PAST = -62135769600.0

        fun fromJson(json: JsonObject): Project? {
            val id = json["id"]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotEmpty() } ?: return null
            return Project(
                id = id,
                name = json["name"]?.jsonPrimitive?.contentOrNull ?: "Project",
                color = json["color"]?.jsonPrimitive?.contentOrNull ?: "#6C2ED6",
                shakes = json["shakes"]?.jsonPrimitive?.booleanOrNull ?: true,
                archived = json["archived"]?.jsonPrimitive?.booleanOrNull ?: false,
                updated = json["updated"]?.jsonPrimitive?.doubleOrNull ?: DISTANT_PAST,
            )
        }
    }
}

/** Every project there has been, in the order they were made. */
data class ProjectList(val all: List<Project> = emptyList()) {
    val visible: List<Project> get() = all.filter { !it.archived }

    fun project(id: String?): Project? = if (id.isNullOrEmpty()) null else all.firstOrNull { it.id == id }

    fun name(id: String): String = if (id.isEmpty()) UNTITLED else project(id)?.name ?: "Unknown project"

    /** This list after a change made here, with each project that is new or different from [before] stamped [now]. */
    fun stamped(before: ProjectList, now: Double): ProjectList = ProjectList(all.map { project ->
        val old = before.project(project.id)
        if (old != null && old.sameAs(project)) project else project.copy(updated = now)
    })

    /**
     * This list and a linked device's put together: every project either knows, each as it was last changed (the
     * later `updated` wins, and on a tie this list's), in this list's order, then the ones only [other] has.
     */
    fun merged(other: ProjectList): ProjectList {
        val list = deduplicated().all.toMutableList()
        for (theirs in other.all) {
            val index = list.indexOfFirst { it.id == theirs.id }
            // A stamp a hair later is the same stamp after a trip through another device's numbers, not a change.
            if (index < 0) list += theirs else if (theirs.updated - list[index].updated > SAME_MOMENT) list[index] = theirs
        }
        return ProjectList(list)
    }

    /**
     * Whether two lists say the same about every project, in whatever order and however each device wrote the
     * stamps: when they do, there is nothing to send.
     */
    fun agrees(other: ProjectList): Boolean {
        val mine = deduplicated().all
        val theirs = other.deduplicated()
        return mine.size == theirs.all.size && mine.all { agreesWith(it, theirs.project(it.id)) }
    }

    /** Each project once: a second copy of an id, however it came about, is dropped, the first one kept. */
    fun deduplicated(): ProjectList {
        val seen = HashSet<String>()
        return ProjectList(all.filter { seen.add(it.id) })
    }

    private fun agreesWith(mine: Project, theirs: Project?): Boolean =
        theirs != null && mine.sameAs(theirs) && kotlin.math.abs(mine.updated - theirs.updated) <= SAME_MOMENT

    fun toJson() = JsonArray(all.map { it.toJson() })

    /** Project ids in the order the projects were made, then any unknown, then the untagged. */
    fun ordered(ids: Set<String>): List<String> {
        val known = all.map { it.id }.filter { it in ids }
        val unknown = (ids - known.toSet() - "").sorted()
        return known + unknown + if ("" in ids) listOf("") else emptyList()
    }

    companion object {
        const val UNTITLED = "No project"
        /** Stamps this close together, in seconds, are the same moment written down by two devices. */
        const val SAME_MOMENT = 0.001

        fun fromJson(array: JsonArray?): ProjectList =
            ProjectList(array.orEmpty().mapNotNull { runCatching { Project.fromJson(it.jsonObject) }.getOrNull() }).deduplicated()

        /** Colours for new projects, the Mac's sand colours first. */
        val palette = listOf(
            "#6C2ED6", "#2876E2", "#34BEA6", "#E0559A", "#D6B688", "#E8833A", "#3FA34D", "#D4B106", "#8E5A3C", "#C2410C", "#475569",
        )
    }
}
