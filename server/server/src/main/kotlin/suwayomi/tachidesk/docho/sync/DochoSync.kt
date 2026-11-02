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
 * Dōchō Sync, built into the server: keeps each account's library and categories, chapter
 * renames and Volume/Chapter types, read progress and history the same on every device signed in
 * to it. The same API as the standalone sync server, under /api/docho/sync/v1.
 *
 * Every record is a kind, a key and a JSON value (null once deleted). Devices send what changed
 * and get back what other devices changed since they last asked. The newest write wins, so a
 * device that was offline can't undo newer changes from another.
 *
 * Accounts are separate from the server's own login: the apps sign in with a username and
 * password and get a token. Set DOCHO_SYNC_REGISTRATION=open to let more than the first account
 * be made.
 */
object DochoSync {
    const val VERSION = "1"
    private val KINDS = setOf("manga", "category", "rename", "kind", "chapter", "history")
    private const val MAX_BODY = 32 * 1024 * 1024
    private const val MAX_CHANGES = 50_000
    private const val PAGE = 5_000
    private const val PASSWORD_ITERATIONS = 600_000
    private const val MAX_VALUE = 64_000

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

    fun userFor(token: String?): Pair<Int, String> {
        if (token.isNullOrEmpty()) throw ApiError(HttpStatus.UNAUTHORIZED, "Sign in first")
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

    fun logout(token: String) {
        transaction { DochoSyncTokenTable.deleteWhere { DochoSyncTokenTable.tokenHash eq hashToken(token) } }
    }

    // ---- Records ----

    private data class Change(
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
    private fun canonical(element: JsonElement): String =
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
            var seq =
                DochoSyncCounterTable.selectAll().where { DochoSyncCounterTable.user eq userId }.firstOrNull()?.get(DochoSyncCounterTable.seq) ?: 0L
            var accepted = 0
            for (change in parsed) {
                val current =
                    DochoSyncRecordTable
                        .selectAll()
                        .where {
                            (DochoSyncRecordTable.user eq userId) and (DochoSyncRecordTable.kind eq change.kind) and (DochoSyncRecordTable.key eq change.key)
                        }.firstOrNull()
                // Newest wins; on the same millisecond, the device id breaks the tie the same way
                // every time, so devices can't keep overwriting each other.
                if (current != null) {
                    val currentAt = current[DochoSyncRecordTable.updatedAt]
                    val currentDevice = current[DochoSyncRecordTable.device]
                    if (currentAt > change.updatedAt || (currentAt == change.updatedAt && currentDevice >= device)) continue
                }
                seq++
                accepted++
                DochoSyncRecordTable.upsert {
                    it[user] = userId
                    it[kind] = change.kind
                    it[key] = change.key
                    it[value] = change.value
                    it[updatedAt] = change.updatedAt
                    it[DochoSyncRecordTable.device] = device
                    it[DochoSyncRecordTable.seq] = seq
                }
            }
            DochoSyncCounterTable.upsert {
                it[user] = userId
                it[DochoSyncCounterTable.seq] = seq
            }
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
                put("accepted", accepted)
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
}
