/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Button from '@mui/material/Button';
import Dialog from '@mui/material/Dialog';
import DialogActions from '@mui/material/DialogActions';
import DialogContent from '@mui/material/DialogContent';
import DialogTitle from '@mui/material/DialogTitle';
import MenuItem from '@mui/material/MenuItem';
import Stack from '@mui/material/Stack';
import TextField from '@mui/material/TextField';
import Typography from '@mui/material/Typography';
import { useLingui } from '@lingui/react/macro';
import type { AwaitableComponentProps } from 'awaitable-component';
import { useEffect, useState } from 'react';
import {
    dochoClient,
    dochoMutate,
    dochoQuery,
    GET_DOCHO_CHAPTER_EDITS,
    RENAME_DOCHO_CHAPTER,
    type DochoChapterEdit,
} from '@/features/docho/DochoApi.ts';
import { makeToast } from '@/base/utils/Toast.ts';
import { getErrorMessage } from '@/lib/HelperFunctions.ts';

type Props = AwaitableComponentProps<boolean> & {
    chapter: { id: number; mangaId: number; name: string; chapterNumber: number };
};

type Kind = 'auto' | 'volume' | 'chapter';

/**
 * Renames a chapter or says whether it's a volume or a chapter, as the Dōchō apps do. The change
 * is kept over what the source or the files say, and reaches the apps through Dōchō Sync; renames
 * made in the apps show here too.
 */
export function DochoRenameChapterDialog({ chapter, onSubmit, onDismiss, isVisible, onExitComplete }: Props) {
    const { t } = useLingui();
    const [edit, setEdit] = useState<DochoChapterEdit | null>();
    const [name, setName] = useState(chapter.name);
    const [number, setNumber] = useState(chapter.chapterNumber >= 0 ? String(chapter.chapterNumber) : '');
    const [kind, setKind] = useState<Kind>('auto');
    const [saving, setSaving] = useState(false);

    useEffect(() => {
        dochoQuery<{ dochoChapterEdits: DochoChapterEdit[] }, { mangaId: number }>(GET_DOCHO_CHAPTER_EDITS, {
            mangaId: chapter.mangaId,
        })
            .then((data) => {
                const found = data.dochoChapterEdits.find((it) => it.chapterId === chapter.id) ?? null;
                setEdit(found);
                setKind(found?.kind ?? 'auto');
            })
            .catch(() => setEdit(null));
    }, [chapter.id, chapter.mangaId]);

    const renamed = edit?.original != null;

    const save = async (drop = false) => {
        setSaving(true);
        try {
            const nameChanged = name.trim() !== chapter.name || number !== String(chapter.chapterNumber);
            // Unchanged and never renamed: only the type is set.
            const keepsName = !drop && (nameChanged || renamed);
            await dochoMutate<unknown, Record<string, unknown>>(RENAME_DOCHO_CHAPTER, {
                chapterId: chapter.id,
                name: keepsName ? name.trim() : null,
                number: drop || number.trim() === '' ? null : Number(number),
                kind: kind === 'auto' ? null : kind,
            });
            await dochoClient().refetchQueries({ include: 'active' });
            makeToast(t`Saved; the apps get it when they next sync`, 'success');
            onSubmit(true);
        } catch (e) {
            makeToast(t`Could not rename the chapter`, 'error', getErrorMessage(e));
        } finally {
            setSaving(false);
        }
    };

    return (
        <Dialog open={isVisible} onClose={onDismiss} onTransitionExited={onExitComplete} fullWidth maxWidth="sm">
            <DialogTitle>{t`Rename chapter`}</DialogTitle>
            <DialogContent dividers>
                <Stack sx={{ gap: 2 }}>
                    {renamed && (
                        <Typography variant="body2" color="text.secondary">
                            {t`Originally "${edit.original}"`}
                        </Typography>
                    )}
                    <TextField label={t`Name`} value={name} onChange={(e) => setName(e.target.value)} fullWidth autoFocus />
                    <Stack direction={{ xs: 'column', sm: 'row' }} sx={{ gap: 2 }}>
                        <TextField
                            label={t`Number`}
                            value={number}
                            type="number"
                            onChange={(e) => setNumber(e.target.value)}
                            fullWidth
                        />
                        <TextField
                            select
                            label={t`Type`}
                            value={kind}
                            onChange={(e) => setKind(e.target.value as Kind)}
                            fullWidth
                            helperText={t`Automatic goes by the name`}
                        >
                            <MenuItem value="auto">{t`Automatic`}</MenuItem>
                            <MenuItem value="volume">{t`Volume`}</MenuItem>
                            <MenuItem value="chapter">{t`Chapter`}</MenuItem>
                        </TextField>
                    </Stack>
                </Stack>
            </DialogContent>
            <DialogActions>
                {renamed && (
                    <Button color="error" disabled={saving} onClick={() => save(true)} sx={{ mr: 'auto' }}>
                        {t`Undo rename`}
                    </Button>
                )}
                <Button onClick={onDismiss}>{t`Cancel`}</Button>
                <Button variant="contained" disabled={saving || !name.trim()} onClick={() => save()}>
                    {t`Save`}
                </Button>
            </DialogActions>
        </Dialog>
    );
}
