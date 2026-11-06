package suwayomi.tachidesk.docho.sync

/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import io.javalin.apibuilder.ApiBuilder.get
import io.javalin.apibuilder.ApiBuilder.path
import io.javalin.apibuilder.ApiBuilder.post
import io.javalin.http.Context
import io.javalin.http.HttpStatus
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import org.jetbrains.exposed.v1.core.JoinType
import org.jetbrains.exposed.v1.core.SortOrder
import org.jetbrains.exposed.v1.core.and
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.core.greater
import org.jetbrains.exposed.v1.core.lowerCase
import org.jetbrains.exposed.v1.jdbc.deleteWhere
import org.jetbrains.exposed.v1.jdbc.insert
import org.jetbrains.exposed.v1.jdbc.insertAndGetId
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import org.jetbrains.exposed.v1.jdbc.update
import org.jetbrains.exposed.v1.jdbc.upsert
import suwayomi.tachidesk.docho.DochoSyncCounterTable
import suwayomi.tachidesk.docho.DochoSyncRecordTable
import suwayomi.tachidesk.docho.DochoSyncTokenTable
import suwayomi.tachidesk.docho.DochoSyncUserTable
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * Dōchō Sync, built into the server: keeps the library and categories, edited details, chapter
 * renames and Volume/Chapter types, read progress and history the same on every device and in the
 * server's own reader, under /api/docho/sync/v1.
 *
 * Every record is a kind, a key and a JSON value (null once deleted). Devices send what changed
 * and get back what other devices changed since they last asked. The newest write wins, except for
 * reading progress a device sends without having seen another device's newer progress: those are
 * put together ([mergeUnseen]), so a device that was asleep can't undo reading done elsewhere.
 *
 * The apps sync through the server's own authentication and send no token: they sync as the
 * server's account ([serverAccount]). Tokens from apps before 0.32.1, which made accounts with
 * register/login, still work; DOCHO_SYNC_REGISTRATION=open still lets more be made that way.
 */
object DochoSync {
    const val VERSION = "1"

    /**
     * The device on records put together from two devices' progress ([mergeUnseen]). It's neither
     * of theirs, because a device skips its own records and both need this one.
     */
    const val MERGED_DEVICE = "docho-merged"

    /** The account made for syncing through the server's own authentication. */
    private const val SERVER_ACCOUNT = "docho-server"
    private val KINDS = setOf("manga", "category", "rename", "kind", "chapter", "history", SyncBridge.DETAILS, SyncBridge.FILL)
    private const val MAX_BODY = 32 * 1024 * 1024
    private const val MAX_CHANGES = 50_000
    private const val PAGE = 5_000
    private const val PASSWORD_ITERATIONS = 600_000
    private const val MAX_VALUE = 64_000

    /** Kinds that are reading progress, where a device that hadn't seen a change is put together with it. */
    private val MERGED_KINDS = setOf("chapter", "history")

    private val random = SecureRandom()
    private val registrationOpen get() = System.getenv("DOCHO_SYNC_REGISTRATION") == "open"

    class ApiError(
        val status: HttpStatus,
        override val message: String,
    ) : Exception(message)

    // ---- Routes ----

    fun defineEndpoints() {
        path("docho/sync/v1") {
            get("health") { ctx -> respond(ctx) { health() } }
            post("register") { ctx ->
                respond(ctx) {
                    val body = body(ctx)
                    register(body.string("username"), body.string("password"), device(body))
                }
            }
            post("login") { ctx ->
                respond(ctx) {
                    val body = body(ctx)
                    login(body.string("username"), body.string("password"), device(body))
                }
            }
            get("me") { ctx ->
                respond(ctx) {
                    val (_, username) = userFor(token(ctx))
                    buildJsonObject { put("username", username) }
                }
            }
            post("logout") { ctx ->
                respond(ctx) {
                    val token = token(ctx)
                    userFor(token)
                    logout(token!!)
                    JsonObject(emptyMap())
                }
            }
            post("sync") { ctx ->
                respond(ctx) {
                    val (userId, _) = userFor(token(ctx))
                    val body = body(ctx)
                    val since = (body["since"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: if (body["since"] == null) 0L else -1L
                    val changes = body["changes"] ?: JsonArray(emptyList())
                    if (since < 0 || changes !is JsonArray) throw ApiError(HttpStatus.BAD_REQUEST, "Send since and changes")
                    sync(userId, since, device(body), changes)
                }
            }
        }
    }

    fun health() =
        buildJsonObject {
            put("name", "Dōchō Sync")
            put("version", VERSION)
            put("server", "Dōchō Server")
        }

    private fun respond(
        ctx: Context,
        block: () -> JsonElement,
    ) {
        val (status, body) =
            try {
                HttpStatus.OK to block()
            } catch (e: ApiError) {
                e.status to buildJsonObject { put("error", e.message) }
            } catch (e: kotlinx.serialization.SerializationException) {
                HttpStatus.BAD_REQUEST to buildJsonObject { put("error", "The body isn't JSON") }
            } catch (e: IllegalArgumentException) {
                HttpStatus.BAD_REQUEST to buildJsonObject { put("error", "The body isn't JSON") }
            }
        ctx.status(status)
        ctx.contentType("application/json")
        ctx.result(body.toString())
    }

    private fun body(ctx: Context): JsonObject {
        val length = ctx.contentLength()
        if (length > MAX_BODY) throw ApiError(HttpStatus.CONTENT_TOO_LARGE, "Too large")
        val text = ctx.body().ifBlank { "{}" }
        return Json.parseToJsonElement(text) as? JsonObject ?: throw ApiError(HttpStatus.BAD_REQUEST, "Send a JSON object")
    }

    private fun JsonObject.string(key: String): String = (this[key] as? JsonPrimitive)?.contentOrNull.orEmpty()

    private fun device(body: JsonObject): String {
        val device = (body["device"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim()
        if (device.isNullOrEmpty()) throw ApiError(HttpStatus.BAD_REQUEST, "Send the device id")
        return device.take(200)
    }

    private fun token(ctx: Context): String? {
        val header = ctx.header("Authorization").orEmpty()
        return if (header.lowercase().startsWith("bearer ")) header.substring(7).trim() else null
    }

    // ---- Accounts ----

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

    private fun hashPassword(
        password: String,
        salt: ByteArray,
    ): String {
        val spec = PBEKeySpec(password.toCharArray(), salt, PASSWORD_ITERATIONS, 256)
        return hex(SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded)
    }

    private fun hashToken(token: String) = hex(MessageDigest.getInstance("SHA-256").digest(token.toByteArray()))

    private fun now() = System.currentTimeMillis()

    @Synchronized
    fun register(
        username: String,
        password: String,
        device: String,
    ): JsonObject {
        val name = username.trim()
        if (name.isEmpty() || name.length > 100) throw ApiError(HttpStatus.BAD_REQUEST, "Enter a username")
        if (password.length < 8) throw ApiError(HttpStatus.BAD_REQUEST, "The password needs at least 8 characters")
        return transaction {
            val users = DochoSyncUserTable.selectAll().count()
            if (users > 0 && !registrationOpen) throw ApiError(HttpStatus.FORBIDDEN, "This server doesn't take new accounts")
            if (DochoSyncUserTable.selectAll().where { DochoSyncUserTable.username.lowerCase() eq name.lowercase() }.any()) {
                throw ApiError(HttpStatus.CONFLICT, "That username is taken")
            }
            val salt = ByteArray(16).also(random::nextBytes)
            val id =
                DochoSyncUserTable
                    .insertAndGetId {
                        it[DochoSyncUserTable.username] = name
                        it[DochoSyncUserTable.salt] = hex(salt)
                        it[passwordHash] = hashPassword(password, salt)
                        it[createdAt] = now()
                    }.value
            newToken(id, name, device)
        }
    }

    fun login(
        username: String,
        password: String,
        device: String,
    ): JsonObject =
        transaction {
            val row = DochoSyncUserTable.selectAll().where { DochoSyncUserTable.username.lowerCase() eq username.trim().lowercase() }.firstOrNull()
            // Hash even for unknown users, so the time taken doesn't say which usernames exist.
            val salt = row?.get(DochoSyncUserTable.salt)?.chunked(2)?.map { it.toInt(16).toByte() }?.toByteArray() ?: ByteArray(16)
            val given = hashPassword(password, salt)
            if (row == null || !MessageDigest.isEqual(given.toByteArray(), row[DochoSyncUserTable.passwordHash].toByteArray())) {
                throw ApiError(HttpStatus.UNAUTHORIZED, "Wrong username or password")
            }
            newToken(row[DochoSyncUserTable.id].value, row[DochoSyncUserTable.username], device)
        }

    private fun newToken(
        userId: Int,
        username: String,
        device: String,
    ): JsonObject {
        val bytes = ByteArray(32).also(random::nextBytes)
        val token = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        val stamp = now()
        DochoSyncTokenTable.insert {
            it[tokenHash] = hashToken(token)
            it[user] = userId
            it[DochoSyncTokenTable.device] = device.take(200)
            it[createdAt] = stamp
            it[lastUsedAt] = stamp
        }
        return buildJsonObject {
            put("token", token)
            put("username", username)
        }
    }

    /**
     * The account a request syncs as. The apps send no token: the server's own authentication
     * (none, or its login) has let them in, and they sync as the server's account. A token (apps
     * before 0.33, which made accounts of their own) still picks its account.
     */
    fun userFor(token: String?): Pair<Int, String> {
        if (token.isNullOrEmpty()) return serverAccount()
        val hash = hashToken(token)
        return transaction {
            val row =
                DochoSyncTokenTable
                    .join(DochoSyncUserTable, JoinType.INNER, DochoSyncTokenTable.user, DochoSyncUserTable.id)
                    .selectAll()
                    .where { DochoSyncTokenTable.tokenHash eq hash }
                    .firstOrNull() ?: throw ApiError(HttpStatus.UNAUTHORIZED, "Signed out, sign in again")
            DochoSyncTokenTable.update({ DochoSyncTokenTable.tokenHash eq hash }) { it[lastUsedAt] = now() }
            row[DochoSyncUserTable.id].value to row[DochoSyncUserTable.username]
        }
    }

    /** The account the server's own reading follows (SyncBridge), made the first time it's needed. */
    @Synchronized
    fun serverAccount(): Pair<Int, String> {
        SyncBridge.linkedUserId()?.let { id ->
            val name = transaction { DochoSyncUserTable.selectAll().where { DochoSyncUserTable.id eq id }.first()[DochoSyncUserTable.username] }
            return id to name
        }
        return transaction {
            DochoSyncUserTable.selectAll().where { DochoSyncUserTable.username eq SERVER_ACCOUNT }.firstOrNull()?.let {
                return@transaction it[DochoSyncUserTable.id].value to SERVER_ACCOUNT
            }
            // No password signs in to it: the server's authentication stands in for one.
            val salt = ByteArray(16).also(random::nextBytes)
            val id =
                DochoSyncUserTable
                    .insertAndGetId {
                        it[username] = SERVER_ACCOUNT
                        it[DochoSyncUserTable.salt] = hex(salt)
                        it[passwordHash] = hashPassword(Base64.getEncoder().encodeToString(ByteArray(32).also(random::nextBytes)), salt)
                        it[createdAt] = now()
                    }.value
            id to SERVER_ACCOUNT
        }
    }

    fun logout(token: String) {
        transaction { DochoSyncTokenTable.deleteWhere { DochoSyncTokenTable.tokenHash eq hashToken(token) } }
    }

    // ---- Records ----

    data class Change(
        val kind: String,
        val key: String,
        val value: String?,
        val updatedAt: Long,
    )

    private fun parseChange(element: JsonElement): Change {
        val change = element as? JsonObject ?: throw ApiError(HttpStatus.BAD_REQUEST, "Each change must be an object")
        val kind = (change["kind"] as? JsonPrimitive)?.contentOrNull
        if (kind !in KINDS) throw ApiError(HttpStatus.BAD_REQUEST, "Unknown kind: $kind")
        val key = (change["key"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (key.isNullOrEmpty() || key.length > 2000) throw ApiError(HttpStatus.BAD_REQUEST, "Each change needs a key")
        val updatedAtPrimitive = change["updatedAt"] as? JsonPrimitive
        val updatedAt = updatedAtPrimitive?.takeIf { !it.isString && it.booleanOrNull == null }?.longOrNull
        if (updatedAt == null || updatedAt <= 0) throw ApiError(HttpStatus.BAD_REQUEST, "Each change needs updatedAt in milliseconds")
        val value = change["value"]?.takeUnless { it is JsonNull }?.let { canonical(it) }
        if (value != null && value.length > MAX_VALUE) throw ApiError(HttpStatus.BAD_REQUEST, "A value is too large")
        return Change(kind!!, key, value, updatedAt)
    }

    /** JSON with sorted keys, so equal values are stored alike. */
    fun canonical(element: JsonElement): String =
        when (element) {
            is JsonObject -> element.entries.sortedBy { it.key }.joinToString(",", "{", "}") { (k, v) -> JsonPrimitive(k).toString() + ":" + canonical(v) }
            is JsonArray -> element.joinToString(",", "[", "]") { canonical(it) }
            else -> element.toString()
        }

    /** Takes the device's changes, newest write winning, then returns what changed after [since]. */
    @Synchronized
    fun sync(
        userId: Int,
        since: Long,
        device: String,
        changes: JsonArray,
    ): JsonObject {
        if (changes.size > MAX_CHANGES) throw ApiError(HttpStatus.CONTENT_TOO_LARGE, "Too many changes at once")
        val parsed = changes.map(::parseChange)
        return transaction {
            val stored = store(userId, parsed, device, since)
            // The server's own read progress follows the linked account (SyncBridge).
            if (SyncBridge.isLinked(userId)) {
                val corrections = SyncBridge.fromDevices(stored)
                if (corrections.isNotEmpty()) store(userId, corrections, SyncBridge.DEVICE)
            }
            val seq = currentSeq(userId)
            val rows =
                DochoSyncRecordTable
                    .selectAll()
                    .where { (DochoSyncRecordTable.user eq userId) and (DochoSyncRecordTable.seq greater since) }
                    .orderBy(DochoSyncRecordTable.seq to SortOrder.ASC)
                    .limit(PAGE + 1)
                    .toList()
            val more = rows.size > PAGE
            val page = rows.take(PAGE)
            buildJsonObject {
                put("accepted", stored.count { it.device == device })
                put("seq", if (more) page.last()[DochoSyncRecordTable.seq] else maxOf(seq, since))
                put("more", more)
                put(
                    "changes",
                    buildJsonArray {
                        page.forEach { row ->
                            add(
                                buildJsonObject {
                                    put("kind", row[DochoSyncRecordTable.kind])
                                    put("key", row[DochoSyncRecordTable.key])
                                    put("value", row[DochoSyncRecordTable.value]?.let { Json.parseToJsonElement(it) } ?: JsonNull)
                                    put("updatedAt", row[DochoSyncRecordTable.updatedAt])
                                    put("device", row[DochoSyncRecordTable.device])
                                },
                            )
                        }
                    },
                )
            }
        }
    }

    /** Records the server itself makes (SyncBridge), stored like a device's. */
    @Synchronized
    fun storeFromServer(
        userId: Int,
        changes: List<Change>,
    ): List<Stored> = if (changes.isEmpty()) emptyList() else transaction { store(userId, changes, SyncBridge.DEVICE) }

    /** A change that was stored, with the value it replaced. */
    data class Stored(
        val kind: String,
        val key: String,
        val value: String?,
        val updatedAt: Long,
        val device: String,
        val previous: String?,
    )

    private fun currentSeq(userId: Int): Long =
        DochoSyncCounterTable.selectAll().where { DochoSyncCounterTable.user eq userId }.firstOrNull()?.get(DochoSyncCounterTable.seq) ?: 0L

    /**
     * Stores [changes] from [device], newest write winning; call inside a transaction, holding
     * this object's lock. Returns the changes that were stored.
     *
     * A device that has just added a series sends each of its chapters as unread. Where another
     * device (or the server) has progress for those chapters, that progress is kept and sent back
     * to the device instead, so adding a series somewhere new doesn't wipe where you were.
     *
     * [since] is what the device has caught up to, or null for the server's own records. A device's
     * updatedAt is when it synced rather than when it read, so a page read days ago arrives looking
     * new. What tells a stale write from a deliberate one is whether the device had seen the record
     * it would replace: if it had, going back to an earlier page is what you asked for; if it hadn't,
     * the two are put together ([mergeUnseen]).
     */
    private fun store(
        userId: Int,
        changes: List<Change>,
        device: String,
        since: Long? = null,
    ): List<Stored> {
        var seq = currentSeq(userId)
        val stored = mutableListOf<Stored>()
        val justAdded = justAddedSeries(userId, changes)
        for (change in changes) {
            val current =
                DochoSyncRecordTable
                    .selectAll()
                    .where {
                        (DochoSyncRecordTable.user eq userId) and (DochoSyncRecordTable.kind eq change.kind) and (DochoSyncRecordTable.key eq change.key)
                    }.firstOrNull()
            val currentValue = current?.get(DochoSyncRecordTable.value)
            val unseen =
                current != null &&
                    since != null &&
                    current[DochoSyncRecordTable.seq] > since &&
                    current[DochoSyncRecordTable.device] != device &&
                    change.kind in MERGED_KINDS &&
                    change.value != null &&
                    currentValue != null
            if (unseen) {
                val merged = mergeUnseen(change.kind, currentValue!!, change.value!!)
                // Nothing to add: the record is after [since], so this response takes it to the device.
                if (merged == currentValue) continue
                seq++
                val at = maxOf(change.updatedAt, current!![DochoSyncRecordTable.updatedAt] + 1)
                val from = if (merged == change.value) device else MERGED_DEVICE
                DochoSyncRecordTable.upsert {
                    it[user] = userId
                    it[kind] = change.kind
                    it[key] = change.key
                    it[value] = merged
                    it[updatedAt] = at
                    it[DochoSyncRecordTable.device] = from
                    it[DochoSyncRecordTable.seq] = seq
                }
                stored += Stored(change.kind, change.key, merged, at, from, currentValue)
                continue
            }
            // Newest wins; on the same millisecond, the device id breaks the tie the same way
            // every time, so devices can't keep overwriting each other.
            if (current != null) {
                val currentAt = current[DochoSyncRecordTable.updatedAt]
                val currentDevice = current[DochoSyncRecordTable.device]
                if (currentAt > change.updatedAt || (currentAt == change.updatedAt && currentDevice >= device)) continue
                if (change.kind == "chapter" && current[DochoSyncRecordTable.device] != device &&
                    seriesKeyOf(change) in justAdded && isUntouched(change.value) && !isUntouched(current[DochoSyncRecordTable.value])
                ) {
                    // Send the progress back rather than taking the new device's blank state.
                    seq++
                    DochoSyncRecordTable.update({
                        (DochoSyncRecordTable.user eq userId) and (DochoSyncRecordTable.kind eq change.kind) and (DochoSyncRecordTable.key eq change.key)
                    }) {
                        it[DochoSyncRecordTable.seq] = seq
                    }
                    continue
                }
            }
            seq++
            DochoSyncRecordTable.upsert {
                it[user] = userId
                it[kind] = change.kind
                it[key] = change.key
                it[value] = change.value
                it[updatedAt] = change.updatedAt
                it[DochoSyncRecordTable.device] = device
                it[DochoSyncRecordTable.seq] = seq
            }
            stored += Stored(change.kind, change.key, change.value, change.updatedAt, device, current?.get(DochoSyncRecordTable.value))
        }
        DochoSyncCounterTable.upsert {
            it[user] = userId
            it[DochoSyncCounterTable.seq] = seq
        }
        return stored
    }

    /**
     * Reading progress from two devices that hadn't seen each other's: read on either is read,
     * bookmarked on either is bookmarked, and the furthest page is kept. For history, the latest
     * read. Returns canonical text, the same as [current] or [incoming] where one already says it all.
     */
    fun mergeUnseen(
        kind: String,
        current: String,
        incoming: String,
    ): String {
        val here = parseObject(current) ?: return incoming
        val there = parseObject(incoming) ?: return current
        fun JsonObject.flag(name: String) = (this[name] as? JsonPrimitive)?.booleanOrNull == true
        fun JsonObject.number(name: String) = (this[name] as? JsonPrimitive)?.longOrNull ?: 0L
        return when (kind) {
            "chapter" -> {
                val read = here.flag("read") || there.flag("read")
                val merged =
                    there +
                        mapOf(
                            "read" to JsonPrimitive(read),
                            "bookmark" to JsonPrimitive(here.flag("bookmark") || there.flag("bookmark")),
                            // As the apps write it: the page is 0 once read.
                            "page" to JsonPrimitive(if (read) 0L else maxOf(here.number("page"), there.number("page"))),
                        )
                canonical(JsonObject(merged))
            }
            "history" -> if (there.number("readAt") > here.number("readAt")) incoming else current
            else -> incoming
        }
    }

    /** "source|url" of the series in [changes] that the device has newly added to its library. */
    private fun justAddedSeries(
        userId: Int,
        changes: List<Change>,
    ): Set<String> =
        changes
            .filter { it.kind == "manga" && it.value != null }
            .filter { change ->
                val previous =
                    DochoSyncRecordTable
                        .selectAll()
                        .where { (DochoSyncRecordTable.user eq userId) and (DochoSyncRecordTable.kind eq "manga") and (DochoSyncRecordTable.key eq change.key) }
                        .firstOrNull()
                        ?.get(DochoSyncRecordTable.value)
                previous == null || addedAt(previous) != addedAt(change.value)
            }.map { it.key }
            .toSet()

    private fun parseObject(value: String?): JsonObject? = value?.let { runCatching { Json.parseToJsonElement(it) as? JsonObject }.getOrNull() }

    private fun addedAt(value: String?): Long? = (parseObject(value)?.get("addedAt") as? JsonPrimitive)?.longOrNull

    private fun seriesKeyOf(change: Change): String? {
        val manga = (parseObject(change.value)?.get("manga") as? JsonPrimitive)?.contentOrNull ?: return null
        return change.key.substringBefore('|') + "|" + manga
    }

    /** A chapter record with nothing in it: unread, not bookmarked, no page. Deleted counts too. */
    fun isUntouched(value: String?): Boolean {
        val obj = parseObject(value) ?: return true
        fun flag(name: String) = (obj[name] as? JsonPrimitive)?.booleanOrNull == true
        val page = (obj["page"] as? JsonPrimitive)?.longOrNull ?: 0
        return !flag("read") && !flag("bookmark") && page == 0L
    }
}
