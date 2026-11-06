/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import { useEffect } from 'react';
import { d } from 'koration';
import { requestManager } from '@/lib/requests/RequestManager.ts';
import { GET_CHAPTERS_READER } from '@/lib/graphql/chapter/ChapterQuery.ts';
import { ChapterOrderBy, SortOrder } from '@/lib/graphql/generated/graphql-base.types.ts';
import type { GetChaptersReaderQuery, GetChaptersReaderQueryVariables } from '@/lib/graphql/generated/graphql.ts';
import { getReaderChapterFromCache } from '@/features/reader/Reader.utils.ts';
import { ReaderService } from '@/features/reader/services/ReaderService.ts';
import { getReaderChaptersStore, getReaderPagesStore } from '@/features/reader/stores/ReaderStore.ts';
import { defaultPromiseErrorHandler } from '@/lib/DefaultPromiseErrorHandler.ts';

const REFRESH_EVERY = d(5).minutes.inWholeMilliseconds;

/**
 * Keeps an open reader up to date with reading done on other devices (Dōchō Sync brings it to the
 * server's chapters): when a chapter opens, when the tab comes back and every few minutes while it's
 * showing. A page further on becomes the least this reader saves, so turning an older page can't undo
 * it. If the page hasn't been turned since opening or coming back, the reader moves there too.
 *
 * It's a request of its own rather than a refetch of the reader's query, so being offline for a
 * moment doesn't replace the page with an error.
 */
export const useReaderProgressRefresh = (mangaId: number, chapterId: number | undefined) => {
    useEffect(() => {
        if (chapterId === undefined || Number.isNaN(mangaId)) {
            return undefined;
        }

        const refresh = (mayMove: boolean) => {
            const known = getReaderChapterFromCache(chapterId);
            const pageBefore = getReaderPagesStore().currentPageIndex;

            requestManager
                .getChapters<GetChaptersReaderQuery, GetChaptersReaderQueryVariables>(
                    GET_CHAPTERS_READER,
                    {
                        condition: { mangaId },
                        order: [{ by: ChapterOrderBy.SourceOrder, byType: SortOrder.Desc }],
                    },
                    { fetchPolicy: 'network-only' },
                )
                .response.then(() => {
                    const fresh = getReaderChapterFromCache(chapterId);
                    if (!known || !fresh || fresh.isRead || fresh.lastPageRead <= known.lastPageRead) {
                        return;
                    }

                    ReaderService.setRemotePage(chapterId, fresh.lastPageRead);

                    const { currentPageIndex, setPageToScrollToIndex } = getReaderPagesStore();
                    const isCurrentChapter = getReaderChaptersStore().currentChapter?.id === chapterId;
                    const isBehind = currentPageIndex < fresh.lastPageRead;
                    if (mayMove && isCurrentChapter && isBehind && currentPageIndex === pageBefore) {
                        setPageToScrollToIndex(fresh.lastPageRead);
                    }
                })
                .catch(defaultPromiseErrorHandler('useReaderProgressRefresh'));
        };

        const onVisibilityChange = () => {
            if (document.visibilityState === 'visible') {
                refresh(true);
            }
        };

        refresh(true);
        const timer = setInterval(() => {
            if (document.visibilityState === 'visible') {
                refresh(false);
            }
        }, REFRESH_EVERY);
        document.addEventListener('visibilitychange', onVisibilityChange);

        return () => {
            clearInterval(timer);
            document.removeEventListener('visibilitychange', onVisibilityChange);
        };
    }, [chapterId, mangaId]);
};
