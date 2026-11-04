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
import CardContent from '@mui/material/CardContent';
import CardActions from '@mui/material/CardActions';
import Typography from '@mui/material/Typography';
import Button from '@mui/material/Button';
import Chip from '@mui/material/Chip';
import Stack from '@mui/material/Stack';
import Fab from '@mui/material/Fab';
import Dialog from '@mui/material/Dialog';
import DialogTitle from '@mui/material/DialogTitle';
import DialogContent from '@mui/material/DialogContent';
import DialogActions from '@mui/material/DialogActions';
import TextField from '@mui/material/TextField';
import MenuItem from '@mui/material/MenuItem';
import Tabs from '@mui/material/Tabs';
import Tab from '@mui/material/Tab';
import FormControlLabel from '@mui/material/FormControlLabel';
import FormGroup from '@mui/material/FormGroup';
import Switch from '@mui/material/Switch';
import Checkbox from '@mui/material/Checkbox';
import IconButton from '@mui/material/IconButton';
import List from '@mui/material/List';
import ListItemButton from '@mui/material/ListItemButton';
import ListItemText from '@mui/material/ListItemText';
import LinearProgress from '@mui/material/LinearProgress';
import AddIcon from '@mui/icons-material/Add';
import DeleteIcon from '@mui/icons-material/Delete';
import FolderIcon from '@mui/icons-material/Folder';
import ArrowUpwardIcon from '@mui/icons-material/ArrowUpward';
import { useLingui } from '@lingui/react/macro';
import { Link } from 'react-router-dom';
import { useAppTitle } from '@/features/navigation-bar/hooks/useAppTitle.ts';
import { LoadingPlaceholder } from '@/base/components/feedback/LoadingPlaceholder.tsx';
import { EmptyViewAbsoluteCentered } from '@/base/components/feedback/EmptyViewAbsoluteCentered.tsx';
import { makeToast } from '@/base/utils/Toast.ts';
import { getErrorMessage } from '@/lib/HelperFunctions.ts';
import { AppRoutes } from '@/base/AppRoute.constants.ts';
import { DochoTrackerFillReview } from '@/features/docho/components/DochoTrackerFillReview.tsx';
import {
    CANCEL_DOCHO_TRACKER_FILL,
    CREATE_DOCHO_LIBRARY,
    DELETE_DOCHO_LIBRARY,
    dochoMutate,
    dochoQuery,
    GET_DOCHO_FOLDERS,
    GET_DOCHO_LIBRARY_ROOT,
    GET_DOCHO_LIBRARIES,
    GET_DOCHO_TRACKER_FILL_STATUS,
    SCAN_DOCHO_LIBRARY,
    START_DOCHO_TRACKER_FILL,
    UPDATE_DOCHO_LIBRARY,
    useDochoQuery,
} from '@/features/docho/DochoApi.ts';
import type {
    DochoFileType,
    DochoLibrary,
    DochoLibraryInput,
    DochoLibraryType,
    DochoTrackerFillStatus,
} from '@/features/docho/DochoApi.ts';

const LIBRARY_TYPES: { value: DochoLibraryType; label: string; help: string }[] = [
    { value: 'MANGA', label: 'Manga', help: 'A folder per series. Files are volumes and chapters, read right to left.' },
    { value: 'COMIC', label: 'Comic', help: 'A folder per series, for western comics.' },
    { value: 'BOOK', label: 'Book', help: 'Each EPUB or PDF is its own series, unless its metadata names a series.' },
    { value: 'LIGHT_NOVEL', label: 'Light novel', help: 'A folder per series of EPUBs or PDFs.' },
    { value: 'IMAGE', label: 'Image', help: 'Folders of images; each folder is a chapter.' },
];

const FILE_TYPES: { value: DochoFileType; label: string }[] = [
    { value: 'ARCHIVE', label: 'Archives (CBZ, CBR, CB7, ZIP, RAR, 7Z)' },
    { value: 'EPUB', label: 'EPUB' },
    { value: 'PDF', label: 'PDF' },
    { value: 'IMAGES', label: 'Folders of images' },
];

const DEFAULT_FILE_TYPES: Record<DochoLibraryType, DochoFileType[]> = {
    MANGA: ['ARCHIVE', 'IMAGES', 'EPUB', 'PDF'],
    COMIC: ['ARCHIVE', 'IMAGES', 'EPUB', 'PDF'],
    BOOK: ['EPUB', 'PDF'],
    LIGHT_NOVEL: ['EPUB', 'PDF'],
    IMAGE: ['IMAGES'],
};

const SCAN_INTERVALS = [
    { value: 0, label: 'Never (scan by hand or on folder changes)' },
    { value: 60, label: 'Every hour' },
    { value: 360, label: 'Every 6 hours' },
    { value: 1440, label: 'Daily' },
    { value: 10080, label: 'Weekly' },
];

function FolderPicker({ onPick, onClose }: { onPick: (path: string) => void; onClose: () => void }) {
    const { t } = useLingui();
    // Opens where the library is mounted (/books in Docker), which the server reports.
    const [path, setPath] = useState<string | null>(null);
    const [folders, setFolders] = useState<{ name: string; path: string }[]>([]);
    const [error, setError] = useState<string>();

    useEffect(() => {
        dochoQuery<{ dochoServerInfo: { libraryRoot: string } }, Record<string, never>>(GET_DOCHO_LIBRARY_ROOT, {})
            .then((data) => setPath((current) => current ?? data.dochoServerInfo.libraryRoot))
            .catch(() => setPath((current) => current ?? '/'));
    }, []);

    useEffect(() => {
        if (path === null) return;
        dochoQuery<{ dochoFolders: { name: string; path: string }[] }, { path: string }>(GET_DOCHO_FOLDERS, { path })
            .then((data) => {
                setFolders(data.dochoFolders);
                setError(undefined);
            })
            .catch((e) => setError(getErrorMessage(e)));
    }, [path]);

    const parent = path === null || path === '/' ? null : path.replace(/\/[^/]+\/?$/, '') || '/';

    return (
        <Dialog open onClose={onClose} fullWidth maxWidth="sm">
            <DialogTitle>{t`Choose a folder`}</DialogTitle>
            <DialogContent dividers sx={{ p: 0 }}>
                <Stack direction="row" sx={{ alignItems: "center", px: 2, py: 1, gap: 1 }}>
                    <IconButton disabled={!parent} onClick={() => parent && setPath(parent)} size="small">
                        <ArrowUpwardIcon />
                    </IconButton>
                    <TextField
                        size="small"
                        fullWidth
                        value={path ?? ''}
                        onChange={(e) => setPath(e.target.value || '/')}
                        error={!!error}
                        helperText={error}
                    />
                </Stack>
                <List dense sx={{ maxHeight: 360, overflow: 'auto' }}>
                    {folders.map((folder) => (
                        <ListItemButton key={folder.path} onClick={() => setPath(folder.path)}>
                            <FolderIcon sx={{ mr: 1.5, color: 'text.secondary' }} />
                            <ListItemText primary={folder.name} />
                        </ListItemButton>
                    ))}
                    {!folders.length && !error && (
                        <Typography sx={{ px: 2, py: 1 }} color="text.secondary">{t`No folders inside`}</Typography>
                    )}
                </List>
            </DialogContent>
            <DialogActions>
                <Button onClick={onClose}>{t`Cancel`}</Button>
                <Button variant="contained" disabled={!path} onClick={() => path && onPick(path)}>{t`Use this folder`}</Button>
            </DialogActions>
        </Dialog>
    );
}

function LibraryDialog({
    library,
    onClose,
    onSaved,
}: {
    library?: DochoLibrary;
    onClose: () => void;
    onSaved: () => void;
}) {
    const { t } = useLingui();
    const [tab, setTab] = useState(0);
    const [picking, setPicking] = useState(false);
    const [saving, setSaving] = useState(false);
    const [form, setForm] = useState<Required<DochoLibraryInput>>({
        name: library?.name ?? '',
        type: library?.type ?? 'MANGA',
        folders: library?.folders ?? [],
        fileTypes: library?.fileTypes ?? DEFAULT_FILE_TYPES.MANGA,
        excludePatterns: library?.excludePatterns ?? [],
        includeInDashboard: library?.includeInDashboard ?? true,
        includeInSearch: library?.includeInSearch ?? true,
        useMetadata: library?.useMetadata ?? true,
        manageCollections: library?.manageCollections ?? true,
        manageGroups: library?.manageGroups ?? true,
        folderCollections: library?.folderCollections ?? false,
        folderWatching: library?.folderWatching ?? true,
        scanIntervalMinutes: library?.scanIntervalMinutes ?? 360,
        sortOrder: library?.sortOrder ?? 0,
    });
    const set = <K extends keyof typeof form>(key: K, value: (typeof form)[K]) => setForm((f) => ({ ...f, [key]: value }));

    const save = async () => {
        setSaving(true);
        try {
            const input: DochoLibraryInput = { ...form };
            if (!library) delete input.sortOrder;
            if (library) {
                await dochoMutate(UPDATE_DOCHO_LIBRARY, { id: library.id, input });
            } else {
                await dochoMutate(CREATE_DOCHO_LIBRARY, { input });
            }
            makeToast(library ? t`Library saved` : t`Library added; scanning it now`, 'success');
            onSaved();
        } catch (e) {
            makeToast(t`Could not save the library`, 'error', getErrorMessage(e));
        } finally {
            setSaving(false);
        }
    };

    const toggle = (key: keyof typeof form, label: string, help?: string) => (
        <FormControlLabel
            control={<Switch checked={form[key] as boolean} onChange={(e) => set(key, e.target.checked as never)} />}
            label={
                <Box>
                    <Typography>{label}</Typography>
                    {help && (
                        <Typography variant="body2" color="text.secondary">
                            {help}
                        </Typography>
                    )}
                </Box>
            }
            sx={{ alignItems: 'flex-start', my: 0.75, '& .MuiSwitch-root': { mt: -0.5 } }}
        />
    );

    return (
        <Dialog open onClose={onClose} fullWidth maxWidth="sm">
            <DialogTitle>{library ? t`Edit ${library.name}` : t`Add library`}</DialogTitle>
            <Tabs value={tab} onChange={(_, v) => setTab(v)} variant="fullWidth">
                <Tab label={t`General`} />
                <Tab label={t`Folders`} />
                <Tab label={t`File types`} />
                <Tab label={t`Advanced`} />
            </Tabs>
            <DialogContent dividers sx={{ minHeight: 380 }}>
                {tab === 0 && (
                    <Stack sx={{ gap: 2 }}>
                        <TextField
                            label={t`Name`}
                            value={form.name}
                            onChange={(e) => set('name', e.target.value)}
                            autoFocus
                            helperText={t`The library also becomes a category of the same name.`}
                        />
                        <TextField
                            select
                            label={t`Type`}
                            value={form.type}
                            onChange={(e) => {
                                const type = e.target.value as DochoLibraryType;
                                setForm((f) => ({
                                    ...f,
                                    type,
                                    fileTypes: DEFAULT_FILE_TYPES[type],
                                    folderCollections: type === 'BOOK',
                                }));
                            }}
                            helperText={LIBRARY_TYPES.find((it) => it.value === form.type)?.help}
                        >
                            {LIBRARY_TYPES.map((it) => (
                                <MenuItem key={it.value} value={it.value}>
                                    {it.label}
                                </MenuItem>
                            ))}
                        </TextField>
                    </Stack>
                )}
                {tab === 1 && (
                    <Stack sx={{ gap: 1 }}>
                        <Typography variant="body2" color="text.secondary">
                            {t`Folders on the server to scan. In Docker, these are the paths inside the container (such as /books/manga).`}
                        </Typography>
                        {form.folders.map((folder, index) => (
                            <Stack key={folder} direction="row" sx={{ alignItems: "center", gap: 1 }}>
                                <FolderIcon color="action" />
                                <Typography sx={{ flexGrow: 1, wordBreak: 'break-all' }}>{folder}</Typography>
                                <IconButton
                                    onClick={() =>
                                        set(
                                            'folders',
                                            form.folders.filter((_, i) => i !== index),
                                        )
                                    }
                                >
                                    <DeleteIcon />
                                </IconButton>
                            </Stack>
                        ))}
                        <Button startIcon={<AddIcon />} onClick={() => setPicking(true)} sx={{ alignSelf: 'flex-start' }}>
                            {t`Add folder`}
                        </Button>
                        {picking && (
                            <FolderPicker
                                onClose={() => setPicking(false)}
                                onPick={(path) => {
                                    if (!form.folders.includes(path)) set('folders', [...form.folders, path]);
                                    setPicking(false);
                                }}
                            />
                        )}
                    </Stack>
                )}
                {tab === 2 && (
                    <Stack sx={{ gap: 2 }}>
                        <FormGroup>
                            {FILE_TYPES.map((it) => (
                                <FormControlLabel
                                    key={it.value}
                                    label={it.label}
                                    control={
                                        <Checkbox
                                            checked={form.fileTypes.includes(it.value)}
                                            onChange={(e) =>
                                                set(
                                                    'fileTypes',
                                                    e.target.checked
                                                        ? [...form.fileTypes, it.value]
                                                        : form.fileTypes.filter((v) => v !== it.value),
                                                )
                                            }
                                        />
                                    }
                                />
                            ))}
                        </FormGroup>
                        <TextField
                            label={t`Exclude patterns`}
                            multiline
                            minRows={3}
                            value={form.excludePatterns.join('\n')}
                            onChange={(e) => set('excludePatterns', e.target.value.split('\n'))}
                            helperText={t`One glob pattern per line, relative to the library folder, such as **/Scans/** or *.tmp`}
                        />
                    </Stack>
                )}
                {tab === 3 && (
                    <Stack>
                        {toggle('useMetadata', t`Use metadata`, t`Read ComicInfo.xml and EPUB metadata for titles, numbers, authors and genres.`)}
                        {toggle('manageCollections', t`Collections from metadata`, t`Make collections from ComicInfo SeriesGroup.`)}
                        {toggle('manageGroups', t`Series groups from metadata`, t`Read series that share a ComicInfo SeriesGroup as one group.`)}
                        {toggle('folderCollections', t`Folders become collections`, t`Each subfolder becomes a collection; useful for book libraries.`)}
                        {toggle('folderWatching', t`Folder watching`, t`Scan when files in the folders change.`)}
                        {toggle('includeInDashboard', t`Include in dashboard`)}
                        {toggle('includeInSearch', t`Include in search`)}
                        <TextField
                            select
                            label={t`Scheduled scan`}
                            value={form.scanIntervalMinutes}
                            onChange={(e) => set('scanIntervalMinutes', Number(e.target.value))}
                            sx={{ mt: 2 }}
                        >
                            {SCAN_INTERVALS.map((it) => (
                                <MenuItem key={it.value} value={it.value}>
                                    {it.label}
                                </MenuItem>
                            ))}
                        </TextField>
                    </Stack>
                )}
            </DialogContent>
            <DialogActions>
                <Button onClick={onClose}>{t`Cancel`}</Button>
                <Button variant="contained" disabled={saving || !form.name.trim()} onClick={save}>
                    {library ? t`Save` : t`Add`}
                </Button>
            </DialogActions>
        </Dialog>
    );
}

/** Scans the library against the trackers signed in on the server, for a list to review. */
function DochoTrackerFillCard() {
    const { t } = useLingui();
    const [compareAll, setCompareAll] = useState(true);
    const [forgetChoices, setForgetChoices] = useState(false);
    const [reviewing, setReviewing] = useState(false);
    const { data, refetch } = useDochoQuery<{ dochoTrackerFillStatus: DochoTrackerFillStatus }>(
        GET_DOCHO_TRACKER_FILL_STATUS,
        undefined,
        { pollInterval: 3000 },
    );
    const status = data?.dochoTrackerFillStatus;

    const start = async () => {
        // eslint-disable-next-line no-alert
        if (waiting && !window.confirm(t`A new scan replaces the list waiting for review. Scan again?`)) {
            return;
        }
        try {
            await dochoMutate(START_DOCHO_TRACKER_FILL, { compareAll, forgetChoices });
            setForgetChoices(false);
            refetch();
        } catch (e) {
            makeToast(t`Could not start the scan`, 'error', getErrorMessage(e));
        }
    };

    const cancel = async () => {
        try {
            await dochoMutate(CANCEL_DOCHO_TRACKER_FILL, {});
            refetch();
        } catch (e) {
            makeToast(t`Could not stop the scan`, 'error', getErrorMessage(e));
        }
    };

    if (!status) {
        return null;
    }
    const waiting = status.ready + status.conflicts;
    return (
        <Card variant="outlined">
            {status.running && (
                <LinearProgress
                    variant={status.total ? 'determinate' : 'indeterminate'}
                    value={status.total ? (status.done / status.total) * 100 : 0}
                />
            )}
            <CardContent>
                <Typography variant="h6">{t`Fill details from trackers`}</Typography>
                <Typography variant="body2" color="text.secondary">
                    {t`Scans your library using the trackers signed in on this server, then lists what it found for you to review. No series changes until you apply it. Applied fields are locked like any edit and reach the apps through Dōchō Sync.`}
                </Typography>
                {!status.running && (
                    <FormGroup sx={{ mt: 1 }}>
                        <FormControlLabel
                            control={<Checkbox checked={compareAll} onChange={(e) => setCompareAll(e.target.checked)} />}
                            label={t`Also compare series with no empty fields (takes longer, finds more conflicts)`}
                        />
                        <FormControlLabel
                            control={
                                <Checkbox checked={forgetChoices} onChange={(e) => setForgetChoices(e.target.checked)} />
                            }
                            label={t`Ask again about everything I kept or skipped`}
                        />
                    </FormGroup>
                )}
                {status.running && (
                    <Typography variant="body2" sx={{ mt: 1 }}>
                        {t`Scanning series ${status.done} of ${status.total}`}
                    </Typography>
                )}
                {Number(status.finishedAt) > 0 && !status.running && (
                    <Typography variant="body2" sx={{ mt: 1 }}>
                        {t`Last scan: ${status.done} series looked at, ${status.unchanged} with nothing to add, ${status.failed} tracker errors`}
                    </Typography>
                )}
                {!!waiting && (
                    <Typography variant="body2" sx={{ mt: 1 }}>
                        {t`Waiting for review: ${status.conflicts} conflicts, ${status.ready} ready to apply`}
                    </Typography>
                )}
            </CardContent>
            <CardActions>
                {status.running ? (
                    <Button color="error" onClick={cancel}>{t`Stop`}</Button>
                ) : (
                    <Button onClick={start}>{t`Scan`}</Button>
                )}
                <Button variant="contained" disabled={!waiting} onClick={() => setReviewing(true)}>
                    {t`Review`}
                </Button>
            </CardActions>
            {reviewing && <DochoTrackerFillReview onClose={() => setReviewing(false)} onChanged={refetch} />}
        </Card>
    );
}

export function DochoLibraries() {
    const { t } = useLingui();
    useAppTitle(t`Libraries`);
    const [editing, setEditing] = useState<DochoLibrary | 'new' | null>(null);
    const { data, loading, error, refetch } = useDochoQuery<{ dochoLibraries: DochoLibrary[] }>(
        GET_DOCHO_LIBRARIES,
        undefined,
        { pollInterval: 4000 },
    );

    if (loading && !data) return <LoadingPlaceholder />;
    if (error && !data) {
        return (
            <EmptyViewAbsoluteCentered
                message={t`Could not load libraries`}
                messageExtra={getErrorMessage(error)}
                retry={() => refetch()}
            />
        );
    }
    const libraries = data?.dochoLibraries ?? [];

    const scan = async (library: DochoLibrary) => {
        try {
            await dochoMutate(SCAN_DOCHO_LIBRARY, { id: library.id });
            makeToast(t`Scanning ${library.name}`, 'info');
            refetch();
        } catch (e) {
            makeToast(t`Could not start the scan`, 'error', getErrorMessage(e));
        }
    };

    const remove = async (library: DochoLibrary) => {
        // eslint-disable-next-line no-alert
        if (!window.confirm(t`Remove ${library.name}? Its series leave the server; the files stay where they are.`)) return;
        try {
            await dochoMutate(DELETE_DOCHO_LIBRARY, { id: library.id });
            refetch();
        } catch (e) {
            makeToast(t`Could not remove the library`, 'error', getErrorMessage(e));
        }
    };

    return (
        <Box sx={{ p: 2, pb: 12 }}>
            {!libraries.length && (
                <EmptyViewAbsoluteCentered
                    message={t`No libraries yet`}
                    messageExtra={t`Add a folder of manga, comics or books, and it is scanned into series like Kavita does.`}
                />
            )}
            <Stack sx={{ gap: 2 }}>
                <DochoTrackerFillCard />
                {libraries.map((library) => (
                    <Card key={library.id} variant="outlined">
                        {library.scanning && <LinearProgress />}
                        <CardContent>
                            <Stack direction="row" sx={{ alignItems: "center", gap: 1, mb: 1 }}>
                                <Typography variant="h6" sx={{ flexGrow: 1 }}>
                                    {library.name}
                                </Typography>
                                <Chip size="small" label={LIBRARY_TYPES.find((it) => it.value === library.type)?.label} />
                                <Chip size="small" variant="outlined" label={t`${library.seriesCount} series`} />
                            </Stack>
                            {library.folders.map((folder) => (
                                <Typography key={folder} variant="body2" color="text.secondary" sx={{ wordBreak: 'break-all' }}>
                                    {folder}
                                </Typography>
                            ))}
                            <Typography variant="body2" sx={{ mt: 1 }}>
                                {library.scanning
                                    ? t`Scanning…`
                                    : library.lastScannedAt
                                      ? `${new Date(library.lastScannedAt).toLocaleString()}: ${library.lastScanResult ?? ''}`
                                      : t`Not scanned yet`}
                            </Typography>
                        </CardContent>
                        <CardActions>
                            <Button component={Link} to={AppRoutes.sources.children.browse.path(library.sourceId)}>
                                {t`Browse`}
                            </Button>
                            <Button disabled={library.scanning} onClick={() => scan(library)}>
                                {t`Scan`}
                            </Button>
                            <Button onClick={() => setEditing(library)}>{t`Edit`}</Button>
                            <Box sx={{ flexGrow: 1 }} />
                            <IconButton onClick={() => remove(library)}>
                                <DeleteIcon />
                            </IconButton>
                        </CardActions>
                    </Card>
                ))}
            </Stack>
            <Fab
                color="primary"
                variant="extended"
                sx={{ position: 'fixed', bottom: 16, right: 16 }}
                onClick={() => setEditing('new')}
            >
                <AddIcon sx={{ mr: 1 }} />
                {t`Add library`}
            </Fab>
            {editing && (
                <LibraryDialog
                    library={editing === 'new' ? undefined : editing}
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
