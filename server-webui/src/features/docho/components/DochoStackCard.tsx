/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { memo, useRef } from 'react';
import type { CSSProperties } from 'react';
import Link from '@mui/material/Link';
import { Link as RouterLink } from 'react-router-dom';
import Box from '@mui/material/Box';
import Stack from '@mui/material/Stack';
import { styled } from '@mui/material/styles';
import { CustomTooltip } from '@/base/components/CustomTooltip.tsx';
import { SpinnerImage } from '@/base/components/SpinnerImage.tsx';
import { MangaOptionButton } from '@/features/manga/components/MangaOptionButton.tsx';
import { Mangas } from '@/features/manga/services/Mangas.ts';
import type { SpecificMangaCardProps } from '@/features/manga/Manga.types.ts';
import { TypographyMaxLines } from '@/base/components/texts/TypographyMaxLines.tsx';
import { GridLayout } from '@/base/Base.types.ts';
import { MediaQuery } from '@/base/utils/MediaQuery.tsx';
import { MUIUtil } from '@/lib/mui/MUI.util.ts';
import { requestManager } from '@/lib/requests/RequestManager.ts';
import { GET_DOCHO_STACK, useDochoQuery } from '@/features/docho/DochoApi.ts';

/** Width over height of a cover (Suwayomi's 1 / 1.5). */
const COVER_RATIO = 1 / 1.5;

export const isStackLayout = (layout?: GridLayout) =>
    layout === GridLayout.StackSmall || layout === GridLayout.Stack || layout === GridLayout.Fanned;

/** How the covers sit: [left %, top %, rotation°] for each, back to front. */
const POSITIONS: Record<'stack' | 'fan', { coverWidth: number; layers: [number, number, number][]; extraHeight: number }> = {
    // Offset up and to the left behind the first book, as BookOrbit does.
    stack: {
        coverWidth: 0.84,
        extraHeight: 0.1,
        layers: [
            [0, 0, 0],
            [0.08, 0.05, 0],
            [0.16, 0.1, 0],
        ],
    },
    // Spread like a hand of cards: the next books tilt out either side of the first.
    fan: {
        coverWidth: 0.62,
        extraHeight: 0.12,
        layers: [
            [0.19, 0.08, -8],
            [0.19, 0.08, 8],
            [0.19, 0.08, 0],
        ],
    },
};

const Badge = styled('div')(({ theme }) => ({
    minWidth: '1.9em',
    padding: '0.1em 0.45em',
    borderRadius: 999,
    background: 'rgba(20, 20, 24, 0.78)',
    color: '#fff',
    fontWeight: 700,
    fontSize: theme.typography.pxToRem(13),
    lineHeight: 1.6,
    textAlign: 'center',
    boxShadow: '0 1px 4px rgba(0,0,0,0.4)',
    backdropFilter: 'blur(4px)',
}));

const coverStyle = (radius: number): CSSProperties => ({
    width: '100%',
    height: '100%',
    objectFit: 'cover',
    borderRadius: radius,
    display: 'block',
});

/**
 * A series as a stack of its books' covers, with how many books there are: in Suwayomi's grid
 * ("small"), at BookOrbit's size, or fanned out. The covers behind are the series' next books,
 * or for a series group, its other parts.
 */
export const DochoStackCard = memo(
    ({
        manga,
        longPressBind,
        popupState,
        mangaLinkTo,
        selected,
        inLibraryIndicator,
        isInLibrary,
        gridLayout,
        handleSelection,
        continueReadingButton,
        mangaBadges,
        mode,
    }: SpecificMangaCardProps) => {
        const preventMobileContextMenu = MediaQuery.usePreventMobileContextMenu();
        const optionButtonRef = useRef<HTMLButtonElement>(null);
        const { id, title } = manga;

        const { data } = useDochoQuery<{ dochoStack: { books: number; behind: string[] } }, { mangaId: number }>(
            GET_DOCHO_STACK,
            { mangaId: id },
            { fetchPolicy: 'cache-first' },
        );
        const books = data?.dochoStack.books ?? 0;
        const front = Mangas.getThumbnailUrl(manga);
        // Series without covers of their own books (from extensions) stack their cover, dimmed.
        const behind = data?.dochoStack.behind.length
            ? data.dochoStack.behind.map((url) => requestManager.getValidImgUrlFor(url))
            : books > 1
              ? [front, front]
              : [];
        const dimmedRepeat = !data?.dochoStack.behind.length;

        const small = gridLayout === GridLayout.StackSmall;
        const geometry = POSITIONS[gridLayout === GridLayout.Fanned ? 'fan' : 'stack'];
        const coverHeight = geometry.coverWidth / COVER_RATIO;
        const boxRatio = 1 / (coverHeight + geometry.extraHeight);
        const radius = small ? 6 : 10;
        const layers = [...behind.slice(0, 2).reverse(), front];
        const positions = geometry.layers.slice(geometry.layers.length - layers.length);
        const dim = inLibraryIndicator && isInLibrary ? 'brightness(0.4)' : undefined;

        return (
            <Link
                component={RouterLink}
                {...longPressBind(() => popupState.open(optionButtonRef.current))}
                to={mangaLinkTo}
                state={Mangas.createLocationState(manga, mode)}
                onContextMenu={preventMobileContextMenu}
                sx={MUIUtil.mergeSx(MediaQuery.preventMobileContextMenuSx(), { textDecoration: 'none' })}
            >
                <CustomTooltip title={small ? '' : title} placement="bottom">
                    <Box
                        sx={{
                            position: 'relative',
                            aspectRatio: `${boxRatio}`,
                            m: small ? 0.5 : 1.5,
                            '@media (hover: hover) and (pointer: fine)': {
                                '&:hover .manga-option-button': { visibility: 'visible', pointerEvents: 'all' },
                                '&:hover .docho-stack-front': { transform: 'translateY(-3px)' },
                                '&:hover .source-manga-library-state-button': { display: 'inline-flex' },
                                '&:hover .source-manga-library-state-indicator': {
                                    display: mode === 'source' ? 'none' : 'flex',
                                },
                            },
                        }}
                    >
                        {layers.map((src, index) => {
                            const [left, top, rotation] = positions[index];
                            const isFront = index === layers.length - 1;
                            const filter = [dim, !isFront && dimmedRepeat ? 'brightness(0.6)' : undefined]
                                .filter(Boolean)
                                .join(' ');
                            return (
                                <Box
                                    // eslint-disable-next-line react/no-array-index-key
                                    key={index}
                                    className={isFront ? 'docho-stack-front' : undefined}
                                    sx={{
                                        position: 'absolute',
                                        left: `${left * 100}%`,
                                        top: `${(top / (coverHeight + geometry.extraHeight)) * 100}%`,
                                        width: `${geometry.coverWidth * 100}%`,
                                        aspectRatio: `${COVER_RATIO}`,
                                        transform: rotation ? `rotate(${rotation}deg)` : undefined,
                                        transformOrigin: '50% 95%',
                                        transition: 'transform 150ms ease',
                                        borderRadius: `${radius}px`,
                                        boxShadow: isFront
                                            ? '0 6px 16px rgba(0,0,0,0.45)'
                                            : '0 3px 10px rgba(0,0,0,0.35)',
                                        outline: isFront && selected ? '4px solid' : undefined,
                                        outlineColor: (theme) => theme.palette.primary.main,
                                        backgroundColor: 'background.paper',
                                        overflow: 'hidden',
                                    }}
                                >
                                    <SpinnerImage
                                        alt={isFront ? title : ''}
                                        src={src}
                                        imgStyle={{ ...coverStyle(radius), filter: filter || undefined }}
                                        spinnerStyle={{ display: 'grid', placeItems: 'center', height: '100%' }}
                                    />
                                    {isFront && (
                                        <>
                                            <Stack
                                                direction="row"
                                                sx={{
                                                    alignItems: 'start',
                                                    justifyContent: 'space-between',
                                                    position: 'absolute',
                                                    top: (theme) => theme.spacing(1),
                                                    left: (theme) => theme.spacing(1),
                                                    right: (theme) => theme.spacing(1),
                                                    gap: 0.5,
                                                }}
                                            >
                                                {mangaBadges}
                                                <Stack direction="row" sx={{ alignItems: 'start', gap: 0.5 }}>
                                                    <MangaOptionButton
                                                        ref={optionButtonRef}
                                                        popupState={popupState}
                                                        id={id}
                                                        selected={selected}
                                                        handleSelection={handleSelection}
                                                    />
                                                    {books > 1 && <Badge>{books}</Badge>}
                                                </Stack>
                                            </Stack>
                                            {small && (
                                                <Box
                                                    sx={{
                                                        position: 'absolute',
                                                        bottom: 0,
                                                        width: '100%',
                                                        height: '40%',
                                                        background:
                                                            'linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.9) 100%)',
                                                    }}
                                                />
                                            )}
                                            <Stack
                                                direction="row"
                                                sx={{
                                                    justifyContent: small ? 'space-between' : 'end',
                                                    alignItems: 'end',
                                                    position: 'absolute',
                                                    bottom: 0,
                                                    width: '100%',
                                                    p: 1,
                                                    gap: 1,
                                                }}
                                            >
                                                {small && (
                                                    <CustomTooltip title={title} placement="top">
                                                        <TypographyMaxLines
                                                            component="h3"
                                                            sx={{ color: 'white', textShadow: '0px 0px 3px #000000' }}
                                                        >
                                                            {title}
                                                        </TypographyMaxLines>
                                                    </CustomTooltip>
                                                )}
                                                {continueReadingButton}
                                            </Stack>
                                        </>
                                    )}
                                </Box>
                            );
                        })}
                    </Box>
                </CustomTooltip>
            </Link>
        );
    },
);
