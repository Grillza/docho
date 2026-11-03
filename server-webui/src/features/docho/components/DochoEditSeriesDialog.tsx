/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import Dialog from '@mui/material/Dialog';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import Button from '@mui/material/Button';
import TextField from '@mui/material/TextField';
import MenuItem from '@mui/material/MenuItem';
import Stack from '@mui/material/Stack';
import Autocomplete from '@mui/material/Autocomplete';
import Chip from '@mui/material/Chip';
import IconButton from '@mui/material/IconButton';
import InputAdornment from '@mui/material/InputAdornment';
import Tooltip from '@mui/material/Tooltip';
import Typography from '@mui/material/Typography';
import LinearProgress from '@mui/material/LinearProgress';
import Box from '@mui/material/Box';
import LockIcon from '@mui/icons-material/Lock';
import LockOpenIcon from '@mui/icons-material/LockOpen';
import { useLingui } from '@lingui/react/macro';
import { makeToast } from '@/base/utils/Toast.ts';
import { getErrorMessage } from '@/lib/HelperFunctions.ts';
import {
    EDIT_DOCHO_SERIES,
    GET_DOCHO_SERIES_INFO,
    dochoClient,
    dochoMutate,
    dochoQuery,
} from '@/features/docho/DochoApi.ts';
import type { DochoSeriesDetails, DochoSeriesEditInput, DochoSeriesField } from '@/features/docho/DochoApi.ts';

type Form = {
    title: string;
    localizedName: string;
    sortName: string;
    summary: string;
    writers: string[];
    artists: string[];
    genres: string[];
    status: number;
    publisher: string;
    releaseYear: string;
    ageRating: string;
    language: string;
};

const FIELD_OF: Record<keyof Form, DochoSeriesField> = {
    title: 'TITLE',
    localizedName: 'LOCALIZED_NAME',
    sortName: 'SORT_NAME',
    summary: 'SUMMARY',
    writers: 'WRITERS',
    artists: 'ARTISTS',
    genres: 'GENRES',
    status: 'STATUS',
    publisher: 'PUBLISHER',
    releaseYear: 'RELEASE_YEAR',
    ageRating: 'AGE_RATING',
    language: 'LANGUAGE',
};

const AGE_RATINGS = [
    'Everyone',
    'G',
    'Early Childhood',
    'Kids to Adults',
    'Everyone 10+',
    'PG',
    'Teen',
    'Mature 15+',
    'Mature 17+',
    'M',
    'R18+',
    'Adults Only 18+',
    'X18+',
];

const toForm = (d: DochoSeriesDetails): Form => ({
    title: d.title ?? '',
    localizedName: d.localizedName ?? '',
    sortName: d.sortName ?? '',
    summary: d.summary ?? '',
    writers: d.writers,
    artists: d.artists,
    genres: d.genres,
    status: d.status ?? 0,
    publisher: d.publisher ?? '',
    releaseYear: d.releaseYear ? String(d.releaseYear) : '',
    ageRating: d.ageRating ?? '',
    language: d.language ?? '',
});

const same = (a: Form[keyof Form], b: Form[keyof Form]) => JSON.stringify(a) === JSON.stringify(b);

/**
 * Edits a library series' details, as Kavita does: an edited field is locked, so scans keep it
 * over what the files say, until it's unlocked again. Edits reach the apps through Dōchō Sync.
 */
export function DochoEditSeriesDialog({ mangaId, onClose }: { mangaId: number; onClose: () => void }) {
    const { t } = useLingui();
    const [details, setDetails] = useState<DochoSeriesDetails>();
    const [form, setForm] = useState<Form>();
    const [reset, setReset] = useState<Set<DochoSeriesField>>(new Set());
    const [saving, setSaving] = useState(false);
    const [error, setError] = useState<string>();

    useEffect(() => {
        dochoQuery<{ dochoSeriesInfo: DochoSeriesDetails }, { mangaId: number }>(GET_DOCHO_SERIES_INFO, { mangaId })
            .then((data) => {
                setDetails(data.dochoSeriesInfo);
                setForm(toForm(data.dochoSeriesInfo));
            })
            .catch((e) => setError(getErrorMessage(e)));
    }, [mangaId]);

    const initial = useMemo(() => (details ? toForm(details) : undefined), [details]);

    const STATUSES = [
        { value: 0, label: t`Unknown` },
        { value: 1, label: t`Ongoing` },
        { value: 2, label: t`Completed` },
        { value: 3, label: t`Licensed` },
        { value: 4, label: t`Publishing finished` },
        { value: 5, label: t`Cancelled` },
        { value: 6, label: t`On hiatus` },
    ];

    if (error) {
        return (
            <Dialog open onClose={onClose}>
                <DialogTitle>{t`Edit details`}</DialogTitle>
                <DialogContent>
                    <Typography color="error">{error}</Typography>
                </DialogContent>
                <DialogActions>
                    <Button onClick={onClose}>{t`Close`}</Button>
                </DialogActions>
            </Dialog>
        );
    }

    if (!details || !form || !initial) {
        return (
            <Dialog open onClose={onClose} fullWidth maxWidth="md">
                <DialogTitle>{t`Edit details`}</DialogTitle>
                <LinearProgress />
            </Dialog>
        );
    }

    const set = <K extends keyof Form>(key: K, value: Form[K]) => {
        setForm({ ...form, [key]: value });
        if (reset.has(FIELD_OF[key])) {
            const next = new Set(reset);
            next.delete(FIELD_OF[key]);
            setReset(next);
        }
    };

    const isLocked = (key: keyof Form) =>
        !reset.has(FIELD_OF[key]) && (details.editedFields.includes(FIELD_OF[key]) || !same(form[key], initial[key]));

    const toggleLock = (key: keyof Form) => {
        const field = FIELD_OF[key];
        const next = new Set(reset);
        if (isLocked(key)) {
            // Unlock: back to what the files say, at the next scan.
            next.add(field);
            setForm({ ...form, [key]: initial[key] });
        } else {
            next.delete(field);
        }
        setReset(next);
    };

    const lock = (key: keyof Form): ReactNode => (
        <InputAdornment position="end">
            <Tooltip
                title={
                    isLocked(key)
                        ? t`Edited here, so scans keep it. Unlock to use what the files say.`
                        : t`From the files. Edit it to lock it.`
                }
            >
                <span>
                    <IconButton
                        size="small"
                        edge="end"
                        disabled={!isLocked(key) && !reset.has(FIELD_OF[key])}
                        onClick={() => toggleLock(key)}
                    >
                        {isLocked(key) ? <LockIcon fontSize="small" color="primary" /> : <LockOpenIcon fontSize="small" />}
                    </IconButton>
                </span>
            </Tooltip>
        </InputAdornment>
    );

    // Series from extensions: only the fields the apps share; the source's details come back on unlock.
    const fromLibrary = details.libraryId != null;
    const can = (key: keyof Form) => details.editableFields.includes(FIELD_OF[key]);

    const text = (key: keyof Form, label: string, props: Partial<Parameters<typeof TextField>[0]> = {}) =>
        can(key) && (
        <TextField
            label={label}
            value={form[key] as string}
            onChange={(e) => set(key, e.target.value as never)}
            fullWidth
            slotProps={{ input: { endAdornment: lock(key) } }}
            {...props}
        />
        );

    const names = (key: 'writers' | 'artists' | 'genres', label: string) => (
        <Stack direction="row" sx={{ alignItems: 'center', gap: 1 }}>
            <Autocomplete
                multiple
                freeSolo
                fullWidth
                options={[] as string[]}
                value={form[key]}
                onChange={(_, value) => set(key, value.map((v) => v.trim()).filter(Boolean))}
                renderValue={(value, getItemProps) =>
                    value.map((option, index) => {
                        const { key: itemKey, ...itemProps } = getItemProps({ index });
                        return <Chip key={itemKey} size="small" label={option} {...itemProps} />;
                    })
                }
                renderInput={(params) => <TextField {...params} label={label} helperText={t`Press Enter after each one`} />}
            />
            <Box sx={{ pb: 2.5 }}>{lock(key)}</Box>
        </Stack>
    );

    const save = async () => {
        const input: DochoSeriesEditInput = { mangaId, reset: [...reset] };
        (Object.keys(form) as (keyof Form)[]).forEach((key) => {
            if (reset.has(FIELD_OF[key]) || same(form[key], initial[key])) return;
            const value = form[key];
            if (key === 'releaseYear') {
                input.releaseYear = Number(value) || 0;
            } else {
                (input as Record<string, unknown>)[key] = value;
            }
        });
        setSaving(true);
        try {
            await dochoMutate<unknown, { input: DochoSeriesEditInput }>(EDIT_DOCHO_SERIES, { input });
            await dochoClient().refetchQueries({ include: 'active' });
            makeToast(reset.size ? t`Saved; unlocked fields come back from the files after a scan` : t`Details saved`, 'success');
            onClose();
        } catch (e) {
            makeToast(t`Could not save the details`, 'error', getErrorMessage(e));
        } finally {
            setSaving(false);
        }
    };

    return (
        <Dialog open onClose={onClose} fullWidth maxWidth="md">
            <DialogTitle>{t`Edit details`}</DialogTitle>
            {saving && <LinearProgress />}
            <DialogContent dividers>
                <Stack sx={{ gap: 2 }}>
                    <Typography variant="body2" color="text.secondary">
                        {fromLibrary
                            ? t`Edited fields are locked, so scans keep them. The apps get the changes when they next sync.`
                            : t`Edited fields are locked, so refreshing from the source keeps them. The apps get the changes when they next sync, and edits made in the apps show here.`}
                    </Typography>
                    {text('title', t`Title`)}
                    {fromLibrary && (
                        <Stack direction={{ xs: 'column', sm: 'row' }} sx={{ gap: 2 }}>
                            {text('localizedName', t`Localised name`)}
                            {text('sortName', t`Sort name`, { helperText: t`Left as it is, it follows the title` })}
                        </Stack>
                    )}
                    {text('summary', t`Summary`, { multiline: true, minRows: 4, maxRows: 14 })}
                    {names('writers', t`Writers`)}
                    {names('artists', t`Artists`)}
                    {names('genres', t`Genres`)}
                    <Stack direction={{ xs: 'column', sm: 'row' }} sx={{ gap: 2 }}>
                        <TextField
                            select
                            fullWidth
                            label={t`Status`}
                            value={form.status}
                            onChange={(e) => set('status', Number(e.target.value))}
                            slotProps={{ input: { endAdornment: lock('status') } }}
                        >
                            {STATUSES.map((it) => (
                                <MenuItem key={it.value} value={it.value}>
                                    {it.label}
                                </MenuItem>
                            ))}
                        </TextField>
                        {fromLibrary && text('releaseYear', t`Release year`, { type: 'number' })}
                    </Stack>
                    {fromLibrary && (
                    <Stack direction={{ xs: 'column', sm: 'row' }} sx={{ gap: 2 }}>
                        {text('publisher', t`Publisher`)}
                        <Autocomplete
                            freeSolo
                            fullWidth
                            options={AGE_RATINGS}
                            value={form.ageRating}
                            onInputChange={(_, value) => set('ageRating', value)}
                            renderInput={(params) => (
                                <TextField
                                    {...params}
                                    label={t`Age rating`}
                                    slotProps={{
                                        ...params.slotProps,
                                        input: {
                                            ...params.slotProps.input,
                                            endAdornment: (
                                                <>
                                                    {params.slotProps.input.endAdornment}
                                                    {lock('ageRating')}
                                                </>
                                            ),
                                        },
                                    }}
                                />
                            )}
                        />
                        {text('language', t`Language`, { helperText: t`A code such as en or ja` })}
                    </Stack>
                    )}
                </Stack>
            </DialogContent>
            <DialogActions>
                <Button onClick={onClose}>{t`Cancel`}</Button>
                <Button variant="contained" disabled={saving} onClick={save}>
                    {t`Save`}
                </Button>
            </DialogActions>
        </Dialog>
    );
}
