/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { useState } from 'react';
import Box from '@mui/material/Box';
import Card from '@mui/material/Card';
import CardContent from '@mui/material/CardContent';
import Typography from '@mui/material/Typography';
import Button from '@mui/material/Button';
import Stack from '@mui/material/Stack';
import Chip from '@mui/material/Chip';
import Fab from '@mui/material/Fab';
import Avatar from '@mui/material/Avatar';
import Dialog from '@mui/material/Dialog';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import TextField from '@mui/material/TextField';
import IconButton from '@mui/material/IconButton';
import AddIcon from '@mui/icons-material/Add';
import DeleteIcon from '@mui/icons-material/Delete';
import { useLingui } from '@lingui/react/macro';
import { Link } from 'react-router-dom';
import { useAppTitle } from '@/features/navigation-bar/hooks/useAppTitle.ts';
import { LoadingPlaceholder } from '@/base/components/feedback/LoadingPlaceholder.tsx';
import { EmptyViewAbsoluteCentered } from '@/base/components/feedback/EmptyViewAbsoluteCentered.tsx';
import { makeToast } from '@/base/utils/Toast.ts';
import { getErrorMessage } from '@/lib/HelperFunctions.ts';
import { AppRoutes } from '@/base/AppRoute.constants.ts';
import {
    CREATE_DOCHO_COLLECTION,
    DELETE_DOCHO_COLLECTION,
    dochoMutate,
    GET_DOCHO_COLLECTIONS,
    thumbnailOf,
    UPDATE_DOCHO_COLLECTION,
    useDochoQuery,
} from '@/features/docho/DochoApi.ts';
import type { DochoCollection } from '@/features/docho/DochoApi.ts';

const ORIGIN_LABEL: Record<DochoCollection['origin'], string> = {
    MANUAL: 'Made by hand',
    METADATA: 'From metadata',
    FOLDER: 'From a folder',
};

export function DochoCollections() {
    const { t } = useLingui();
    useAppTitle(t`Collections`);
    const [editing, setEditing] = useState<DochoCollection | 'new' | null>(null);
    const [name, setName] = useState('');
    const [summary, setSummary] = useState('');
    const { data, loading, error, refetch } = useDochoQuery<{ dochoCollections: DochoCollection[] }>(
        GET_DOCHO_COLLECTIONS,
    );

    if (loading && !data) return <LoadingPlaceholder />;
    if (error && !data) {
        return (
            <EmptyViewAbsoluteCentered
                message={t`Could not load collections`}
                messageExtra={getErrorMessage(error)}
                retry={() => refetch()}
            />
        );
    }
    const collections = data?.dochoCollections ?? [];

    const open = (collection: DochoCollection | 'new') => {
        setName(collection === 'new' ? '' : collection.name);
        setSummary(collection === 'new' ? '' : collection.summary);
        setEditing(collection);
    };

    const save = async () => {
        try {
            if (editing === 'new') {
                await dochoMutate(CREATE_DOCHO_COLLECTION, { name, summary });
            } else if (editing) {
                await dochoMutate(UPDATE_DOCHO_COLLECTION, { id: editing.id, name, summary });
            }
            setEditing(null);
            refetch();
        } catch (e) {
            makeToast(t`Could not save the collection`, 'error', getErrorMessage(e));
        }
    };

    const remove = async (collection: DochoCollection) => {
        // eslint-disable-next-line no-alert
        if (!window.confirm(t`Delete the collection ${collection.name}? Its series stay.`)) return;
        await dochoMutate(DELETE_DOCHO_COLLECTION, { id: collection.id });
        refetch();
    };

    return (
        <Box sx={{ p: 2, pb: 12 }}>
            <Typography color="text.secondary" sx={{ mb: 2 }}>
                {t`Collections hold series that belong together without being read as one, as in Kavita. Scans make them from ComicInfo SeriesGroup, or from a book library's folders; add series to any collection from a series' page.`}
            </Typography>
            {!collections.length && (
                <Typography sx={{ mt: 4, textAlign: 'center' }} color="text.secondary">
                    {t`No collections yet.`}
                </Typography>
            )}
            <Stack sx={{ gap: 2 }}>
                {collections.map((collection) => (
                    <Card key={collection.id} variant="outlined">
                        <CardContent>
                            <Stack direction="row" sx={{ alignItems: "center", gap: 1 }}>
                                <Typography variant="h6" sx={{ flexGrow: 1 }}>
                                    {collection.name}
                                </Typography>
                                <Chip size="small" label={ORIGIN_LABEL[collection.origin]} />
                                <Chip size="small" variant="outlined" label={t`${collection.seriesCount} series`} />
                            </Stack>
                            {collection.summary && (
                                <Typography variant="body2" color="text.secondary">
                                    {collection.summary}
                                </Typography>
                            )}
                            <Stack direction="row" sx={{ gap: 1, mt: 1.5, overflowX: 'auto', pb: 1 }}>
                                {collection.series.map((manga) => (
                                    <Box
                                        key={manga.id}
                                        component={Link}
                                        to={AppRoutes.manga.path(manga.id)}
                                        sx={{ width: 84, flexShrink: 0, textDecoration: 'none', color: 'inherit' }}
                                    >
                                        <Avatar variant="rounded" src={thumbnailOf(manga)} sx={{ width: 84, height: 120 }} />
                                        <Typography variant="caption" sx={{ display: 'block' }} noWrap>
                                            {manga.title}
                                        </Typography>
                                    </Box>
                                ))}
                            </Stack>
                            <Stack direction="row">
                                <Button onClick={() => open(collection)}>{t`Edit`}</Button>
                                <Box sx={{ flexGrow: 1 }} />
                                <IconButton onClick={() => remove(collection)}>
                                    <DeleteIcon />
                                </IconButton>
                            </Stack>
                        </CardContent>
                    </Card>
                ))}
            </Stack>
            <Fab
                color="primary"
                variant="extended"
                sx={{ position: 'fixed', bottom: 16, right: 16 }}
                onClick={() => open('new')}
            >
                <AddIcon sx={{ mr: 1 }} />
                {t`New collection`}
            </Fab>
            {editing && (
                <Dialog open onClose={() => setEditing(null)} fullWidth maxWidth="xs">
                    <DialogTitle>{editing === 'new' ? t`New collection` : t`Edit collection`}</DialogTitle>
                    <DialogContent>
                        <Stack sx={{ gap: 2, pt: 1 }}>
                            <TextField label={t`Name`} value={name} onChange={(e) => setName(e.target.value)} autoFocus />
                            <TextField
                                label={t`Summary`}
                                value={summary}
                                onChange={(e) => setSummary(e.target.value)}
                                multiline
                                minRows={2}
                            />
                        </Stack>
                    </DialogContent>
                    <DialogActions>
                        <Button onClick={() => setEditing(null)}>{t`Cancel`}</Button>
                        <Button variant="contained" disabled={!name.trim()} onClick={save}>
                            {t`Save`}
                        </Button>
                    </DialogActions>
                </Dialog>
            )}
        </Box>
    );
}
