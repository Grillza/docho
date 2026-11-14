package docho.dochosync

import io.kotest.matchers.shouldBe
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.Test

class SyncValuesTest {

    @Test
    fun `canonical text sorts keys and drops nulls`() {
        val a = Json.parseToJsonElement("""{"b":1,"a":"x","c":null,"d":{"z":true,"y":[2,1]}}""")
        SyncValues.canonical(a) shouldBe """{"a":"x","b":1,"d":{"y":[2,1],"z":true}}"""
        SyncValues.canonical(SyncValues.rename("Vol. 3", 3.0, null, 5, null)) shouldBe
            """{"at":5,"name":"Vol. 3","number":"3"}"""
        SyncValues.number(119.1) shouldBe "119.1"
        SyncValues.number(-1.0) shouldBe "-1"
    }

    @Test
    fun `a value from the server reads the same as one built here`() {
        val here = SyncValues.chapter("/series/1", read = false, bookmark = true, page = 4)
        val fromServer = Json.parseToJsonElement("""{"read":false,"page":4,"manga":"/series/1","bookmark":true}""")
        SyncValues.canonical(here) shouldBe SyncValues.canonical(fromServer)
        // A read chapter's page doesn't matter
        SyncValues.canonical(SyncValues.chapter("/s", true, false, 9)) shouldBe
            SyncValues.canonical(SyncValues.chapter("/s", true, false, 0))
    }

    @Test
    fun `changes are what differ from the last sync, and deletions`() {
        val chapter = SyncValues.chapter("/s", true, false, 0)
        val current = mapOf(
            SyncValues.id("chapter", "1|/c/1") to ("chapter" to chapter),
            SyncValues.id("chapter", "1|/c/2") to ("chapter" to chapter),
            SyncValues.id("chapter", "1|/c/3") to ("chapter" to chapter),
        )
        val synced = mapOf(
            SyncValues.id("chapter", "1|/c/1") to SyncValues.canonical(chapter),
            SyncValues.id("manga", "1|/s") to "{}",
            SyncValues.id("manga", "1|/waiting") to "{}",
        )
        val pending = setOf(SyncValues.id("chapter", "1|/c/3"), SyncValues.id("manga", "1|/waiting"))
        val changes = syncChanges(current, synced, pending, now = 9)
        changes.map { "${it.kind} ${it.key} ${it.isDeleted}" }.sorted() shouldBe listOf(
            "chapter 1|/c/2 false",
            "manga 1|/s true",
        )
    }

    @Test
    fun `a first sync keeps reading from both devices`() {
        val local = SyncValues.chapter("/s", read = false, bookmark = true, page = 7)
        val remote = SyncValues.chapter("/s", read = false, bookmark = false, page = 3)
        SyncValues.mergeChapter(local, remote) shouldBe SyncValues.chapter("/s", false, true, 7)
        val readRemote = SyncValues.chapter("/s", read = true, bookmark = false, page = 0)
        (SyncValues.mergeChapter(local, readRemote)["read"].toString()) shouldBe "true"
        SyncValues.parseKey("123|/a|b") shouldBe (123L to "/a|b")
        SyncValues.parseKey("nope") shouldBe null
    }

    @Test
    fun `progress coming down never takes the device back`() {
        val local = SyncValues.chapter("/s", read = false, bookmark = true, page = 120)
        val remote = SyncValues.chapter("/s", read = false, bookmark = false, page = 110)
        SyncValues.mergeChapter(local, remote, remoteBookmark = true) shouldBe SyncValues.chapter("/s", false, false, 120)
        val behind = SyncValues.chapter("/s", read = false, bookmark = false, page = 4)
        SyncValues.mergeChapter(behind, remote, remoteBookmark = true) shouldBe remote
    }

    @Test
    fun `the later change wins by when it was read, even going back`() {
        val further = SyncValues.chapter("/s", read = false, bookmark = false, page = 110, at = 200)
        val back = SyncValues.chapter("/s", read = false, bookmark = false, page = 4, at = 300)
        SyncValues.mergeChapter(further, back) shouldBe back
        SyncValues.isBehind(back, further) shouldBe true
        // Read earlier, so the further page stays
        val stale = SyncValues.chapter("/s", read = false, bookmark = false, page = 4, at = 100)
        SyncValues.mergeChapter(further, stale) shouldBe further
        // Unread on purpose after it was read
        val read = SyncValues.chapter("/s", read = true, bookmark = false, page = 0, at = 200)
        val unread = SyncValues.chapter("/s", read = false, bookmark = false, page = 0, at = 300)
        SyncValues.mergeChapter(read, unread) shouldBe unread
    }

    @Test
    fun `without a time on one side, the stored time decides, else the furthest point`() {
        val untimed = SyncValues.chapter("/s", read = false, bookmark = false, page = 110)
        val back = SyncValues.chapter("/s", read = false, bookmark = false, page = 4, at = 300)
        SyncValues.mergeChapter(untimed, back, localStored = 250) shouldBe back
        SyncValues.mergeChapter(untimed, back, localStored = 350) shouldBe
            SyncValues.chapter("/s", read = false, bookmark = false, page = 110, at = 300)
        SyncValues.canonical(untimed) shouldBe """{"bookmark":false,"manga":"/s","page":110,"read":false}"""
    }
}
