package docho.suwayomi

import eu.kanade.tachiyomi.source.model.Filter
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

class SuwayomiFiltersTest {

    private val described = Json.parseToJsonElement(
        """
        [
          { "__typename": "HeaderFilter", "name": "Note" },
          { "__typename": "SelectFilter", "name": "Type", "selectDefault": 0, "values": ["All", "Manga", "Manhwa"] },
          { "__typename": "SortFilter", "name": "Sort", "sortDefault": { "index": 0, "ascending": false }, "values": ["Popular", "New"] },
          { "__typename": "GroupFilter", "name": "Genres", "filters": [
            { "__typename": "TriStateFilter", "name": "Action", "triDefault": "IGNORE" },
            { "__typename": "TriStateFilter", "name": "Drama", "triDefault": "IGNORE" }
          ] },
          { "__typename": "TextFilter", "name": "Author", "textDefault": "" }
        ]
        """.trimIndent(),
    ).jsonArray

    @Test
    fun `unchanged filters send nothing`() {
        val filters = SuwayomiApi.toFilterList(described)
        assertEquals(JsonArray(emptyList()), SuwayomiApi.filterChanges(filters, SuwayomiApi.toFilterList(described)))
    }

    @Test
    fun `only changed filters are sent, by position`() {
        val filters = SuwayomiApi.toFilterList(described)
        (filters[1] as Filter.Select<*>).state = 2
        (filters[2] as Filter.Sort).state = Filter.Sort.Selection(1, true)
        ((filters[3] as Filter.Group<*>).state[1] as Filter.TriState).state = Filter.TriState.STATE_EXCLUDE
        (filters[4] as Filter.Text).state = "Oda"

        val expected = Json.parseToJsonElement(
            """
            [
              { "position": 1, "selectState": 2 },
              { "position": 2, "sortState": { "index": 1, "ascending": true } },
              { "position": 3, "groupChange": { "position": 1, "triState": "EXCLUDE" } },
              { "position": 4, "textState": "Oda" }
            ]
            """.trimIndent(),
        )
        assertEquals(expected, SuwayomiApi.filterChanges(filters, SuwayomiApi.toFilterList(described)))
    }

    @Test
    fun `server addresses are cleaned up`() {
        assertEquals("http://192.168.1.20:4567", SuwayomiApi.normalizeBaseUrl("192.168.1.20:4567/"))
        assertEquals(
            "https://manga.example.com",
            SuwayomiApi.normalizeBaseUrl(" https://manga.example.com/api/graphql "),
        )
        assertNull(SuwayomiApi.normalizeBaseUrl(""))
    }
}
