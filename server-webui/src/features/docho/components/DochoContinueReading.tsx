/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Box from '@mui/material/Box';
import Button from '@mui/material/Button';
import Card from '@mui/material/Card';
import CardActionArea from '@mui/material/CardActionArea';
import LinearProgress from '@mui/material/LinearProgress';
import Stack from '@mui/material/Stack';
import Typography from '@mui/material/Typography';
import PlayArrowIcon from '@mui/icons-material/PlayArrow';
import { Link } from 'react-router-dom';
import { useLingui } from '@lingui/react/macro';
import { AppRoutes } from '@/base/AppRoute.constants.ts';
import { Chapters } from '@/features/chapter/services/Chapters.ts';
import { useLocalStorage } from '@/base/hooks/useStorage.tsx';
import { requestManager } from '@/lib/requests/RequestManager.ts';
import { GET_DOCHO_CONTINUE_READING, useDochoQuery } from '@/features/docho/DochoApi.ts';
import type { DochoReading } from '@/features/docho/DochoApi.ts';

export const CONTINUE_READING_KEY = 'docho-show-continue-reading';

/** How far through the book being read; or through the series when no book is open. */
const progressOf = (it: DochoReading) => {
    if (it.page > 0 && it.pageCount > 0) return Math.min(100, ((it.page + 1) / it.pageCount) * 100);
    return it.totalChapters ? Math.min(100, (it.readChapters / it.totalChapters) * 100) : 0;
};

/** The series being read, at most three, at the top of the library, each with a Resume button. */
export function DochoContinueReading() {
    const { t } = useLingui();
    const [show] = useLocalStorage(CONTINUE_READING_KEY, true);
    const { data } = useDochoQuery<{ dochoContinueReading: DochoReading[] }, { limit: number }>(
        GET_DOCHO_CONTINUE_READING,
        { limit: 3 },
        { skip: !show },
    );
    const items = data?.dochoContinueReading ?? [];
    if (!show || !items.length) return null;

    return (
        <Box sx={{ px: 1, pt: 1.5, pb: 0.5 }}>
            <Typography variant="overline" color="text.secondary" sx={{ px: 0.5, letterSpacing: 1.2 }}>
                {t`Currently reading`}
            </Typography>
            <Box
                sx={{
                    display: 'grid',
                    gap: 1,
                    gridTemplateColumns: { xs: '1fr', sm: 'repeat(2, 1fr)', lg: 'repeat(3, 1fr)' },
                }}
            >
                {items.map((it, index) => {
                    const percent = progressOf(it);
                    const readerPath = AppRoutes.reader.path(it.mangaId, it.chapterSourceOrder);
                    const readerState = Chapters.getReaderOpenChapterLocationState({ isRead: false });
                    return (
                        <Card
                            key={it.mangaId}
                            // Narrow screens show only the most recent one.
                            sx={{ display: { xs: index === 0 ? 'block' : 'none', sm: index < 2 ? 'block' : 'none', lg: 'block' } }}
                        >
                            <Stack direction="row" sx={{ alignItems: 'stretch' }}>
                                <CardActionArea
                                    component={Link}
                                    to={AppRoutes.manga.path(it.mangaId)}
                                    sx={{ width: 'auto', display: 'flex', alignItems: 'stretch', flex: 1, minWidth: 0 }}
                                >
                                    <Box
                                        component="img"
                                        src={requestManager.getValidImgUrlFor(it.thumbnailUrl)}
                                        alt=""
                                        sx={{ width: 64, height: 96, objectFit: 'cover', flexShrink: 0 }}
                                    />
                                    <Stack sx={{ p: 1.25, minWidth: 0, flex: 1, justifyContent: 'center', gap: 0.25 }}>
                                        <Typography variant="subtitle2" noWrap>
                                            {it.title}
                                        </Typography>
                                        <Typography variant="body2" color="text.secondary" noWrap>
                                            {it.page > 0 && it.pageCount > 0
                                                ? t`${it.chapterName} · page ${it.page + 1} of ${it.pageCount}`
                                                : it.chapterName}
                                        </Typography>
                                        <Stack direction="row" sx={{ alignItems: 'center', gap: 1, mt: 0.5 }}>
                                            <LinearProgress
                                                variant="determinate"
                                                value={percent}
                                                sx={{ flex: 1, height: 6, borderRadius: 3 }}
                                            />
                                            <Typography variant="caption" color="text.secondary" noWrap>
                                                {Math.round(percent)}%
                                            </Typography>
                                        </Stack>
                                        <Typography variant="caption" color="text.secondary" noWrap>
                                            {t`Book ${it.chapterSourceOrder} of ${it.totalChapters} · ${it.readChapters} read`}
                                        </Typography>
                                    </Stack>
                                </CardActionArea>
                                <Stack sx={{ justifyContent: 'center', pr: 1.25 }}>
                                    <Button
                                        variant="contained"
                                        size="small"
                                        startIcon={<PlayArrowIcon />}
                                        component={Link}
                                        to={readerPath}
                                        state={readerState}
                                    >
                                        {t`Resume`}
                                    </Button>
                                </Stack>
                            </Stack>
                        </Card>
                    );
                })}
            </Box>
        </Box>
    );
}
