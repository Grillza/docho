/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { useEffect, useState } from 'react';
import Box from '@mui/material/Box';
import Card from '@mui/material/Card';
import CardActionArea from '@mui/material/CardActionArea';
import CardContent from '@mui/material/CardContent';
import Typography from '@mui/material/Typography';
import Button from '@mui/material/Button';
import Stack from '@mui/material/Stack';
import Fab from '@mui/material/Fab';
import Dialog from '@mui/material/Dialog';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import TextField from '@mui/material/TextField';
import MenuItem from '@mui/material/MenuItem';
import IconButton from '@mui/material/IconButton';
import Autocomplete from '@mui/material/Autocomplete';
import FormControlLabel from '@mui/material/FormControlLabel';
import Switch from '@mui/material/Switch';
import Avatar from '@mui/material/Avatar';
import Divider from '@mui/material/Divider';
import Tooltip from '@mui/material/Tooltip';
import AddIcon from '@mui/icons-material/Add';
import DeleteIcon from '@mui/icons-material/Delete';
import ArrowUpwardIcon from '@mui/icons-material/ArrowUpward';
import ArrowDownwardIcon from '@mui/icons-material/ArrowDownward';
import AutoFixHighIcon from '@mui/icons-material/AutoFixHigh';
import CloseIcon from '@mui/icons-material/Close';
import { useLingui } from '@lingui/react/macro';
import { Link } from 'react-router-dom';
import { useAppTitle } from '@/features/navigation-bar/hooks/useAppTitle.ts';
import { LoadingPlaceholder } from '@/base/components/feedback/LoadingPlaceholder.tsx';
import { EmptyViewAbsoluteCentered } from '@/base/components/feedback/EmptyViewAbsoluteCentered.tsx';
import { makeToast } from '@/base/utils/Toast.ts';
import { getErrorMessage } from '@/lib/HelperFunctions.ts';
import { AppRoutes } from '@/base/AppRoute.constants.ts';
import {
    AUTO_LABEL_DOCHO_GROUP,
    CREATE_DOCHO_GROUP,
    DELETE_DOCHO_GROUP,
    dochoMutate,
    dochoQuery,
    GET_DOCHO_GROUPS,
    SEARCH_LIBRARY_MANGAS,
    SET_DOCHO_GROUP_LABEL,
    SET_DOCHO_GROUP_MEMBERS,
    SUGGEST_LABELS,
    thumbnailOf,
    UPDATE_DOCHO_GROUP,
    useDochoQuery,
} from '@/features/docho/DochoApi.ts';
import type {
    DochoChapterLabelStyle,
    DochoGroupSortMode,
    DochoGroupSuggestion,
    DochoManga,
    DochoSeriesGroup,
} from '@/features/docho/DochoApi.ts';

const SORT_MODES: { value: DochoGroupSortMode; label: string }[] = [
    { value: 'MANUAL', label: 'As arranged' },
    { value: 'PART_NUMBER', label: 'By part / season number' },
    { value: 'RELEASE_YEAR', label: 'By release year' },
    { value: 'TITLE', label: 'By name' },
];

const LABEL_STYLES: { value: DochoChapterLabelStyle; label: string; example: string }[] = [
    { value: 'LABEL_PREFIX', label: 'Part name first', example: 'Stardust Crusaders · Vol. 3' },
    { value: 'CONTINUOUS', label: 'Numbered straight through', example: 'Vol. 15' },
    { value: 'CONTINUOUS_WITH_LABEL', label: 'Straight through, with part', example: 'Vol. 15 · Stardust Crusaders Vol. 3' },
    { value: 'ORIGINAL', label: 'Chapter names as they are', example: 'Vol. 3' },
];

type Member = { manga: DochoManga; label: string };

/** Picks series from the server library. */
function SeriesSearch({ onPick, exclude }: { onPick: (manga: DochoManga) => void; exclude: number[] }) {
    const { t } = useLingui();
    const [query, setQuery] = useState('');
    const [options, setOptions] = useState<DochoManga[]>([]);

    useEffect(() => {
        const handle = setTimeout(() => {
            dochoQuery<{ mangas: { nodes: DochoManga[] } }, { query: string }>(SEARCH_LIBRARY_MANGAS, { query })
                .then((data) => setOptions(data.mangas.nodes))
                .catch(() => setOptions([]));
        }, 250);
        return () => clearTimeout(handle);
    }, [query]);

    return (
        <Autocomplete
            options={options.filter((it) => !exclude.includes(it.id))}
            getOptionLabel={(it) => it.title}
            filterOptions={(it) => it}
            value={null}
            inputValue={query}
            onInputChange={(_, value) => setQuery(value)}
            onChange={(_, value) => {
                if (value) onPick(value);
                setQuery('');
            }}
            renderOption={(props, option) => (
                <li {...props} key={option.id}>
                    <Avatar variant="rounded" src={thumbnailOf(option)} sx={{ width: 32, height: 44, mr: 1.5 }} />
                    {option.title}
                </li>
            )}
            renderInput={(params) => <TextField {...params} label={t`Add a series from the library`} />}
        />
    );
}

function GroupDialog({
    group,
    initial,
    onClose,
    onSaved,
}: {
    group?: DochoSeriesGroup;
    initial?: DochoGroupSuggestion;
    onClose: () => void;
    onSaved: () => void;
}) {
    const { t } = useLingui();
    const [name, setName] = useState(group?.name ?? initial?.name ?? '');
    const [description, setDescription] = useState(group?.description ?? '');
    const [sortMode, setSortMode] = useState<DochoGroupSortMode>(group?.sortMode ?? (initial ? 'PART_NUMBER' : 'MANUAL'));
    const [chapterLabel, setChapterLabel] = useState<DochoChapterLabelStyle>(group?.chapterLabel ?? 'LABEL_PREFIX');
    const [hideMembers, setHideMembers] = useState(group?.hideMembers ?? true);
    const [members, setMembers] = useState<Member[]>(
        group?.members
            .filter((m) => m.manga)
            .map((m) => ({ manga: m.manga!, label: m.label ?? '' })) ??
            initial?.series.map((manga, i) => ({ manga, label: initial.labels[i] ?? '' })) ??
            [],
    );
    const [saving, setSaving] = useState(false);

    const move = (index: number, by: number) => {
        const next = [...members];
        const [item] = next.splice(index, 1);
        next.splice(index + by, 0, item);
        setMembers(next);
        setSortMode('MANUAL');
    };

    const autoLabel = async () => {
        try {
            const data = await dochoQuery<{ dochoSuggestLabels: string[] }, { name: string; mangaIds: number[] }>(
                SUGGEST_LABELS,
                { name, mangaIds: members.map((m) => m.manga.id) },
            );
            setMembers(members.map((m, i) => ({ ...m, label: data.dochoSuggestLabels[i] ?? m.label })));
        } catch (e) {
            makeToast(t`Could not suggest names`, 'error', getErrorMessage(e));
        }
    };

    const save = async () => {
        setSaving(true);
        const input = { name, description, sortMode, chapterLabel, hideMembers };
        try {
            if (group) {
                await dochoMutate(UPDATE_DOCHO_GROUP, { id: group.id, input });
                await dochoMutate(SET_DOCHO_GROUP_MEMBERS, { id: group.id, mangaIds: members.map((m) => m.manga.id) });
                for (const member of members) {
                    const before = group.members.find((m) => m.mangaId === member.manga.id)?.label ?? '';
                    if (before !== member.label) {
                        // eslint-disable-next-line no-await-in-loop
                        await dochoMutate(SET_DOCHO_GROUP_LABEL, {
                            id: group.id,
                            mangaId: member.manga.id,
                            label: member.label || null,
                        });
                    }
                }
            } else {
                await dochoMutate(CREATE_DOCHO_GROUP, {
                    name,
                    mangaIds: members.map((m) => m.manga.id),
                    labels: members.map((m) => m.label || null),
                    input,
                });
            }
            makeToast(t`Group saved`, 'success');
            onSaved();
        } catch (e) {
            makeToast(t`Could not save the group`, 'error', getErrorMessage(e));
        } finally {
            setSaving(false);
        }
    };

    const example = LABEL_STYLES.find((it) => it.value === chapterLabel)?.example;

    return (
        <Dialog open onClose={onClose} fullWidth maxWidth="md">
            <DialogTitle>{group ? t`Edit group` : t`New series group`}</DialogTitle>
            <DialogContent dividers>
                <Stack sx={{ gap: 2 }}>
                    <TextField label={t`Name`} value={name} onChange={(e) => setName(e.target.value)} autoFocus />
                    <TextField
                        label={t`Description`}
                        value={description}
                        onChange={(e) => setDescription(e.target.value)}
                        multiline
                        minRows={2}
                        helperText={t`Left empty, the group lists its parts.`}
                    />
                    <Stack direction={{ xs: 'column', sm: 'row' }} sx={{ gap: 2 }}>
                        <TextField
                            select
                            fullWidth
                            label={t`Order`}
                            value={sortMode}
                            onChange={(e) => setSortMode(e.target.value as DochoGroupSortMode)}
                        >
                            {SORT_MODES.map((it) => (
                                <MenuItem key={it.value} value={it.value}>
                                    {it.label}
                                </MenuItem>
                            ))}
                        </TextField>
                        <TextField
                            select
                            fullWidth
                            label={t`Chapter names`}
                            value={chapterLabel}
                            onChange={(e) => setChapterLabel(e.target.value as DochoChapterLabelStyle)}
                            helperText={example}
                        >
                            {LABEL_STYLES.map((it) => (
                                <MenuItem key={it.value} value={it.value}>
                                    {it.label}
                                </MenuItem>
                            ))}
                        </TextField>
                    </Stack>
                    <FormControlLabel
                        control={<Switch checked={hideMembers} onChange={(e) => setHideMembers(e.target.checked)} />}
                        label={t`Show only the group in the library, not each part`}
                    />
                    <Divider />
                    <Stack direction="row" sx={{ alignItems: "center" }}>
                        <Typography variant="subtitle1" sx={{ flexGrow: 1 }}>
                            {t`Parts, in reading order`}
                        </Typography>
                        <Tooltip title={t`Name each part from its title, e.g. "Part 3: Stardust Crusaders"`}>
                            <span>
                                <Button startIcon={<AutoFixHighIcon />} disabled={!members.length} onClick={autoLabel}>
                                    {t`Name parts`}
                                </Button>
                            </span>
                        </Tooltip>
                    </Stack>
                    {members.map((member, index) => (
                        <Stack key={member.manga.id} direction="row" sx={{ alignItems: "center", gap: 1.5 }}>
                            <Typography sx={{ width: 24, textAlign: 'right' }} color="text.secondary">
                                {index + 1}
                            </Typography>
                            <Avatar variant="rounded" src={thumbnailOf(member.manga)} sx={{ width: 40, height: 56 }} />
                            <Stack sx={{ flexGrow: 1, minWidth: 0 }}>
                                <TextField
                                    size="small"
                                    label={t`Shown as`}
                                    placeholder={member.manga.title}
                                    value={member.label}
                                    onChange={(e) =>
                                        setMembers(members.map((m, i) => (i === index ? { ...m, label: e.target.value } : m)))
                                    }
                                />
                                <Typography variant="caption" color="text.secondary" noWrap>
                                    {member.manga.title}
                                </Typography>
                            </Stack>
                            <IconButton disabled={index === 0} onClick={() => move(index, -1)}>
                                <ArrowUpwardIcon />
                            </IconButton>
                            <IconButton disabled={index === members.length - 1} onClick={() => move(index, 1)}>
                                <ArrowDownwardIcon />
                            </IconButton>
                            <IconButton onClick={() => setMembers(members.filter((_, i) => i !== index))}>
                                <CloseIcon />
                            </IconButton>
                        </Stack>
                    ))}
                    <SeriesSearch
                        exclude={members.map((m) => m.manga.id)}
                        onPick={(manga) => setMembers([...members, { manga, label: '' }])}
                    />
                </Stack>
            </DialogContent>
            <DialogActions>
                <Button onClick={onClose}>{t`Cancel`}</Button>
                <Button variant="contained" disabled={saving || !name.trim() || !members.length} onClick={save}>
                    {t`Save`}
                </Button>
            </DialogActions>
        </Dialog>
    );
}

export function DochoSeriesGroups() {
    const { t } = useLingui();
    useAppTitle(t`Series groups`);
    const [editing, setEditing] = useState<{ group?: DochoSeriesGroup; initial?: DochoGroupSuggestion } | null>(null);
    const { data, loading, error, refetch } = useDochoQuery<{
        dochoSeriesGroups: DochoSeriesGroup[];
        dochoGroupSuggestions: DochoGroupSuggestion[];
    }>(GET_DOCHO_GROUPS);

    if (loading && !data) return <LoadingPlaceholder />;
    if (error && !data) {
        return (
            <EmptyViewAbsoluteCentered
                message={t`Could not load series groups`}
                messageExtra={getErrorMessage(error)}
                retry={() => refetch()}
            />
        );
    }
    const groups = data?.dochoSeriesGroups ?? [];
    const suggestions = data?.dochoGroupSuggestions ?? [];

    const remove = async (group: DochoSeriesGroup) => {
        // eslint-disable-next-line no-alert
        if (!window.confirm(t`Ungroup ${group.name}? Its parts go back to the library as they were.`)) return;
        await dochoMutate(DELETE_DOCHO_GROUP, { id: group.id }).catch((e) =>
            makeToast(t`Could not ungroup`, 'error', getErrorMessage(e)),
        );
        refetch();
    };

    const relabel = async (group: DochoSeriesGroup) => {
        await dochoMutate(AUTO_LABEL_DOCHO_GROUP, { id: group.id }).catch((e) =>
            makeToast(t`Could not name the parts`, 'error', getErrorMessage(e)),
        );
        refetch();
    };

    return (
        <Box sx={{ p: 2, pb: 12 }}>
            <Typography color="text.secondary" sx={{ mb: 2 }}>
                {t`A series group reads several series as one, such as the parts of JoJo's Bizarre Adventure. The group appears in the library and in the apps as a single series whose chapters run through every part, named and ordered the way you choose. Reading a chapter in the group marks it read in its own series too.`}
            </Typography>
            {!!suggestions.length && (
                <Box sx={{ mb: 3 }}>
                    <Typography variant="subtitle1" sx={{ mb: 1 }}>
                        {t`Suggested`}
                    </Typography>
                    <Stack direction="row" sx={{ gap: 1, flexWrap: "wrap" }}>
                        {suggestions.map((suggestion) => (
                            <Button
                                key={suggestion.name}
                                variant="outlined"
                                startIcon={<AddIcon />}
                                onClick={() => setEditing({ initial: suggestion })}
                            >
                                {t`${suggestion.name} (${suggestion.series.length} series)`}
                            </Button>
                        ))}
                    </Stack>
                </Box>
            )}
            {!groups.length && !suggestions.length && (
                <Typography sx={{ mt: 4, textAlign: 'center' }} color="text.secondary">
                    {t`No groups yet.`}
                </Typography>
            )}
            <Box
                sx={{
                    display: 'grid',
                    gap: 2,
                    gridTemplateColumns: 'repeat(auto-fill, minmax(min(100%, 340px), 1fr))',
                }}
            >
                {groups.map((group) => (
                    <Card key={group.id} variant="outlined">
                        <CardActionArea
                            component={Link}
                            to={group.mangaId ? AppRoutes.manga.path(group.mangaId) : '#'}
                            disabled={!group.mangaId}
                        >
                            <Stack direction="row" sx={{ p: 1.5, gap: 0.5, overflow: 'hidden' }}>
                                {group.members.slice(0, 6).map((m) => (
                                    <Avatar
                                        key={m.mangaId}
                                        variant="rounded"
                                        src={thumbnailOf(m.manga)}
                                        sx={{ width: 48, height: 68 }}
                                    />
                                ))}
                            </Stack>
                        </CardActionArea>
                        <CardContent sx={{ pt: 0 }}>
                            <Typography variant="h6">{group.name}</Typography>
                            {group.members.map((m, i) => (
                                <Typography key={m.mangaId} variant="body2" color="text.secondary" noWrap>
                                    {i + 1}. {m.displayLabel}
                                </Typography>
                            ))}
                            <Stack direction="row" sx={{ mt: 1 }}>
                                <Button onClick={() => setEditing({ group })}>{t`Edit`}</Button>
                                <Button onClick={() => relabel(group)}>{t`Name parts`}</Button>
                                <Box sx={{ flexGrow: 1 }} />
                                <IconButton onClick={() => remove(group)}>
                                    <DeleteIcon />
                                </IconButton>
                            </Stack>
                        </CardContent>
                    </Card>
                ))}
            </Box>
            <Fab
                color="primary"
                variant="extended"
                sx={{ position: 'fixed', bottom: 16, right: 16 }}
                onClick={() => setEditing({})}
            >
                <AddIcon sx={{ mr: 1 }} />
                {t`New group`}
            </Fab>
            {editing && (
                <GroupDialog
                    group={editing.group}
                    initial={editing.initial}
                    onClose={() => setEditing(null)}
                    onSaved={() => {
                        setEditing(null);
                        refetch();
                    }}
                />
            )}
        </Box>
    );
}
