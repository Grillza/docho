package docho.edit

import docho.dochosync.SyncValues
import io.kotest.matchers.shouldBe
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.Test

class SeriesEditsTest {

    @Test
    fun `only edited fields go in a details record, blank ones as empty text`() {
        val details = SeriesEdits.Details(title = "Kaiju No. 8 (Mine)", author = "", genres = listOf("Action", "Sci-Fi"))
        SyncValues.canonical(SeriesEdits.toJson(details)) shouldBe
            """{"author":"","genres":["Action","Sci-Fi"],"title":"Kaiju No. 8 (Mine)"}"""
    }

    @Test
    fun `a details record from Dōchō Server or iOS reads back the same`() {
        val fromServer = Json.parseToJsonElement("""{"status":2,"description":"Edited","title":"T","genres":[]}""").jsonObject
        val details = SeriesEdits.fromJson(fromServer)
        details shouldBe SeriesEdits.Details(title = "T", description = "Edited", genres = emptyList(), status = 2)
        SyncValues.canonical(SeriesEdits.toJson(details)) shouldBe SyncValues.canonical(fromServer)
    }

    @Test
    fun `fields not in the record aren't edited`() {
        val details = SeriesEdits.fromJson(Json.parseToJsonElement("""{"title":"T"}""").jsonObject)
        details.author shouldBe null
        details.genres shouldBe null
        details.status shouldBe null
        SeriesEdits.Details().isEmpty shouldBe true
    }
}
