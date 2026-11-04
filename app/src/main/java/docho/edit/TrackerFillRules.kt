package docho.edit

import eu.kanade.tachiyomi.source.model.SManga
import kotlinx.serialization.Serializable

/** A value a field could take, and the tracker it's from. Statuses are numbers, as text. */
@Serializable
data class FillOption(val value: String, val trackerName: String)

/** A field a tracker has something to say about. [field] is its name in "details" records. */
@Serializable
data class FillChange(
    val field: String,
    val current: String,
    val options: List<FillOption>,
    /** It takes a decision: [current] would be replaced, or the [options] differ. */
    val conflict: Boolean,
)

@Serializable
enum class FillProblem { READY, DIFFERENT, SEVERAL_MATCHES, NO_MATCH }

/** A series on the review list a scan leaves. */
@Serializable
data class FillItem(
    val sourceId: Long,
    val url: String,
    val title: String,
    val problem: FillProblem,
    val changes: List<FillChange> = emptyList(),
    /** The series it could be, when there's no clear match. */
    val candidates: List<TrackerFill.Match> = emptyList(),
    /** The user said which series it is; scans would only fail to find it again. */
    val picked: Boolean = false,
) {
    val key get() = "$sourceId|$url"
}

/** The fields a tracker can fill, as a series has them. */
data class FillCurrent(val author: String, val artist: String, val description: String, val status: Long) {
    val hasEmptyFields
        get() = TrackerFillRules.isEmptyName(author) || TrackerFillRules.isEmptyName(artist) ||
            description.isBlank() || status == TrackerFillRules.UNKNOWN
}

/**
 * What a scan makes of what trackers say. These are the same rules as Dōchō Server's TrackerFill
 * and iOS's TrackerFillRules: decisions are shared through Dōchō Sync, so names must compare alike.
 */
object TrackerFillRules {
    const val AUTHOR = "author"
    const val ARTIST = "artist"
    const val DESCRIPTION = "description"
    const val STATUS = "status"

    /** In the remembered choices, a series left out of scans altogether. */
    const val SKIPPED = "*"
    const val KEPT = "kept"

    val UNKNOWN = SManga.UNKNOWN.toLong()

    fun isEmptyName(name: String) = name.isBlank() || name.trim().equals("unknown", ignoreCase = true)

    /** A title without case, spaces or punctuation, so only real differences stop a match. */
    fun comparable(title: String): String = title.lowercase().filter { it.isLetterOrDigit() }

    /** Names to compare whatever their order: "MIURA Kentaro" is "Kentaro Miura". */
    fun namesKey(names: String): String = names
        .split(",")
        .map { name ->
            name.trim().split(Regex("\\s+")).map(::comparable).filter { it.isNotEmpty() }.sorted().joinToString(" ")
        }
        .filter { it.isNotEmpty() }
        .distinct()
        .sorted()
        .joinToString(",")

    /** The value that stands for an option in the remembered choices. */
    fun optionKey(field: String, value: String) = if (field == AUTHOR || field == ARTIST) namesKey(value) else value

    /** Whether a tracker's [status] says the same as the series'. Trackers can't tell these apart. */
    private fun sameStatus(current: Long, status: Long) = current == status ||
        current == SManga.LICENSED.toLong() ||
        (current == SManga.PUBLISHING_FINISHED.toLong() && status == SManga.COMPLETED.toLong())

    /**
     * What [matches] have to say about a series. An empty field just takes its value, unless
     * trackers disagree. A field with a value is a conflict if a tracker differs, except for a
     * status the last fill gave ([filledStatus]), which is only out of date. Summaries are never
     * compared: no two are worded alike. Values in [ignored] were decided on earlier.
     */
    fun review(
        current: FillCurrent,
        matches: List<TrackerFill.Match>,
        filledStatus: Long?,
        ignored: Map<String, List<String>> = emptyMap(),
    ): List<FillChange> = buildList {
        fun names(field: String, value: String, of: (TrackerFill.Match) -> String) {
            val options = matches
                .filter { of(it).isNotBlank() }
                .map { FillOption(of(it), it.trackerName) }
                .distinctBy { namesKey(it.value) }
                .filter { namesKey(it.value) !in ignored[field].orEmpty() }
            if (isEmptyName(value)) {
                if (options.isNotEmpty()) add(FillChange(field, value, options, conflict = options.size > 1))
            } else {
                val different = options.filter { namesKey(it.value) != namesKey(value) }
                if (different.isNotEmpty()) add(FillChange(field, value, different, conflict = true))
            }
        }
        names(AUTHOR, current.author) { it.author }
        names(ARTIST, current.artist) { it.artist }

        if (current.description.isBlank() && ignored[DESCRIPTION].isNullOrEmpty()) {
            matches.firstOrNull { it.description.isNotBlank() }?.let {
                add(FillChange(DESCRIPTION, "", listOf(FillOption(it.description, it.trackerName)), conflict = false))
            }
        }

        val statuses = matches
            .filter { it.status != UNKNOWN && it.status.toString() !in ignored[STATUS].orEmpty() }
            .distinctBy { it.status }
            .filterNot { sameStatus(current.status, it.status) }
            .map { FillOption(it.status.toString(), it.trackerName) }
        if (statuses.isNotEmpty()) {
            val weOwnIt = current.status == UNKNOWN || current.status == filledStatus
            add(FillChange(STATUS, current.status.toString(), statuses, conflict = !weOwnIt || statuses.size > 1))
        }
    }

    /** The problem for [changes], or null if there's nothing to say. */
    fun problemOf(changes: List<FillChange>): FillProblem? = when {
        changes.isEmpty() -> null
        changes.any { it.conflict } -> FillProblem.DIFFERENT
        else -> FillProblem.READY
    }

    /**
     * An item as it stands now that the series may have changed since the scan, here or on another
     * device: values it already has or that were decided against drop out. Null if nothing's left.
     */
    fun prune(item: FillItem, current: FillCurrent, filledStatus: Long?, ignored: Map<String, List<String>>): FillItem? {
        if (SKIPPED in ignored) return null
        if (item.changes.isEmpty()) return item.takeIf { current.hasEmptyFields }
        val changes = item.changes.mapNotNull { change ->
            val decided = ignored[change.field].orEmpty()
            when (change.field) {
                AUTHOR, ARTIST -> {
                    val live = if (change.field == AUTHOR) current.author else current.artist
                    val options = change.options.filter {
                        namesKey(it.value) !in decided && (isEmptyName(live) || namesKey(it.value) != namesKey(live))
                    }
                    options.takeIf { it.isNotEmpty() }
                        ?.let { change.copy(current = live, options = it, conflict = !isEmptyName(live) || it.size > 1) }
                }
                DESCRIPTION -> change.takeIf { current.description.isBlank() && decided.isEmpty() }
                else -> {
                    val options = change.options.filter {
                        it.value !in decided && !sameStatus(current.status, it.value.toLong())
                    }
                    val weOwnIt = current.status == UNKNOWN || current.status == filledStatus
                    options.takeIf { it.isNotEmpty() }?.let {
                        change.copy(current = current.status.toString(), options = it, conflict = !weOwnIt || it.size > 1)
                    }
                }
            }
        }
        return problemOf(changes)?.let { item.copy(problem = it, changes = changes) }
    }
}
