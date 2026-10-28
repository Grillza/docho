package tachiyomi.domain.source.model

import eu.kanade.tachiyomi.source.model.MangasPage

/**
 * A source that knows which of its series the user hasn't finished, such as a self-hosted
 * server that tracks reading progress. Browsing it offers an "Unread" listing next to
 * Popular and Latest.
 */
interface UnreadListingSource {

    /** Series with unread books, most recently added to first. [page] counts from 1. */
    suspend fun getUnreadManga(page: Int): MangasPage
}
