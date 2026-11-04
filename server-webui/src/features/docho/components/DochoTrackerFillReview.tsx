/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { useState } from 'react';
import Button from '@mui/material/Button';
import Card from '@mui/material/Card';
import CardActions from '@mui/material/CardActions';
import CardContent from '@mui/material/CardContent';
import Dialog from '@mui/material/Dialog';
import DialogActions from '@mui/material/DialogActions';
import DialogContent from '@mui/material/DialogContent';
import DialogTitle from '@mui/material/DialogTitle';
import FormControl from '@mui/material/FormControl';
import FormControlLabel from '@mui/material/FormControlLabel';
import FormLabel from '@mui/material/FormLabel';
import LinearProgress from '@mui/material/LinearProgress';
import List from '@mui/material/List';
import ListItemButton from '@mui/material/ListItemButton';
import ListItemText from '@mui/material/ListItemText';
import Radio from '@mui/material/Radio';
import RadioGroup from '@mui/material/RadioGroup';
import Stack from '@mui/material/Stack';
import Tab from '@mui/material/Tab';
import Tabs from '@mui/material/Tabs';
import TextField from '@mui/material/TextField';
import Typography from '@mui/material/Typography';
import { useLingui } from '@lingui/react/macro';
import { Link } from 'react-router-dom';
import { AppRoutes } from '@/base/AppRoute.constants.ts';
import { makeToast } from '@/base/utils/Toast.ts';
import { getErrorMessage } from '@/lib/HelperFunctions.ts';
import {
    APPLY_READY_DOCHO_TRACKER_FILL,
    DISMISS_DOCHO_TRACKER_FILL_CONFLICTS,
    dochoMutate,
    GET_DOCHO_TRACKER_FILL_ITEMS,
    PICK_DOCHO_TRACKER_FILL_MATCH,
    RESOLVE_DOCHO_TRACKER_FILL_ITEM,
    SEARCH_DOCHO_TRACKER_FILL_ITEM,
    SKIP_DOCHO_TRACKER_FILL_ITEM,
    useDochoQuery,
} from '@/features/docho/DochoApi.ts';
import type {
    DochoSeriesField,
    DochoTrackerFillChange,
    DochoTrackerFillItem,
} from '@/features/docho/DochoApi.ts';

const PAGE_SIZE = 50;
/** Stands for keeping what the series has, among a field's options. */
const KEEP = '';

function useLabels() {
    const { t } = useLingui();
    const statuses: Record<string, string> = {
        '0': t`Unknown`,
        '1': t`Ongoing`,
        '2': t`Completed`,
        '3': t`Licensed`,
        '4': t`Publishing finished`,
        '5': t`Cancelled`,
        '6': t`On hiatus`,
    };
    const fields: Partial<Record<DochoSeriesField, string>> = {
        WRITERS: t`Writers`,
        ARTISTS: t`Artists`,
        SUMMARY: t`Summary`,
        STATUS: t`Status`,
    };
    return {
        field: (field: DochoSeriesField) => fields[field] ?? field,
        value: (change: DochoTrackerFillChange, value: string) =>
            change.field === 'STATUS' ? (statuses[value] ?? value) : value,
    };
}

/** Starts on the tracker's value when the field is empty, and on the series' own when it isn't. */
const startingChoice = (change: DochoTrackerFillChange) => {
    const isEmpty = change.field === 'STATUS' ? change.current === '0' : !change.current.trim();
    return !change.conflict || isEmpty ? change.options[0].value : KEEP;
};

function ItemTitle({ item }: { item: DochoTrackerFillItem }) {
    return (
        <Typography
            variant="subtitle1"
            component={Link}
            to={AppRoutes.manga.path(item.mangaId)}
            target="_blank"
            sx={{ color: 'inherit' }}
        >
            {item.title}
        </Typography>
    );
}

/** A series whose fields need deciding, or that's ready to apply. */
function ChangesCard({
    item,
    busy,
    run,
}: {
    item: DochoTrackerFillItem;
    busy: boolean;
    run: (action: () => Promise<unknown>) => Promise<void>;
}) {
    const { t } = useLingui();
    const labels = useLabels();
    const [choices, setChoices] = useState<Record<string, string>>(() =>
        Object.fromEntries(item.changes.map((change) => [change.field, startingChoice(change)])),
    );

    const apply = () =>
        run(() =>
            dochoMutate(RESOLVE_DOCHO_TRACKER_FILL_ITEM, {
                mangaId: item.mangaId,
                choices: item.changes.map((change) => ({
                    field: change.field,
                    value: choices[change.field] === KEEP ? null : choices[change.field],
                })),
            }),
        );

    return (
        <Card variant="outlined">
            <CardContent>
                <ItemTitle item={item} />
                <Stack sx={{ gap: 1.5, mt: 1 }}>
                    {item.changes.map((change) =>
                        change.conflict ? (
                            <FormControl key={change.field}>
                                <FormLabel>{labels.field(change.field)}</FormLabel>
                                <RadioGroup
                                    value={choices[change.field]}
                                    onChange={(e) => setChoices({ ...choices, [change.field]: e.target.value })}
                                >
                                    {!!change.current.trim() && change.current !== '0' && (
                                        <FormControlLabel
                                            value={KEEP}
                                            control={<Radio size="small" />}
                                            label={t`Keep: ${labels.value(change, change.current)}`}
                                        />
                                    )}
                                    {change.options.map((option) => (
                                        <FormControlLabel
                                            key={option.value}
                                            value={option.value}
                                            control={<Radio size="small" />}
                                            label={`${option.trackerName}: ${labels.value(change, option.value)}`}
                                        />
                                    ))}
                                </RadioGroup>
                            </FormControl>
                        ) : (
                            <Typography key={change.field} variant="body2" sx={{ overflowWrap: 'anywhere' }}>
                                <strong>{labels.field(change.field)}:</strong>{' '}
                                {labels.value(change, change.options[0].value).slice(0, 240)}{' '}
                                <Typography component="span" variant="caption" color="text.secondary">
                                    ({change.options[0].trackerName})
                                </Typography>
                            </Typography>
                        ),
                    )}
                </Stack>
            </CardContent>
            <CardActions>
                <Button disabled={busy} variant="contained" onClick={apply}>{t`Apply`}</Button>
                <Button
                    disabled={busy}
                    onClick={() => run(() => dochoMutate(SKIP_DOCHO_TRACKER_FILL_ITEM, { mangaId: item.mangaId }))}
                >
                    {t`Keep everything`}
                </Button>
            </CardActions>
        </Card>
    );
}

/** A series with no clear match: pick one of the results, search again, or leave it. */
function MatchCard({
    item,
    busy,
    run,
}: {
    item: DochoTrackerFillItem;
    busy: boolean;
    run: (action: () => Promise<unknown>) => Promise<void>;
}) {
    const { t } = useLingui();
    const [query, setQuery] = useState(item.title);

    return (
        <Card variant="outlined">
            <CardContent>
                <ItemTitle item={item} />
                <Typography variant="body2" color="text.secondary">
                    {item.problem === 'SEVERAL_MATCHES'
                        ? t`Several results could be this series. Which is it?`
                        : t`No tracker has this exact title. Is it one of these?`}
                </Typography>
                {!!item.candidates.length && (
                    <List dense>
                        {item.candidates.map((candidate, index) => (
                            <ListItemButton
                                // eslint-disable-next-line react/no-array-index-key
                                key={index}
                                disabled={busy}
                                onClick={() =>
                                    run(() => dochoMutate(PICK_DOCHO_TRACKER_FILL_MATCH, { mangaId: item.mangaId, index }))
                                }
                            >
                                <ListItemText
                                    primary={candidate.title}
                                    secondary={[
                                        candidate.trackerName,
                                        candidate.writers.join(', '),
                                        candidate.publishingStatus,
                                    ]
                                        .filter(Boolean)
                                        .join(' · ')}
                                />
                            </ListItemButton>
                        ))}
                    </List>
                )}
                <Stack direction="row" sx={{ gap: 1, mt: 1 }}>
                    <TextField
                        size="small"
                        fullWidth
                        label={t`Search for another title`}
                        value={query}
                        onChange={(e) => setQuery(e.target.value)}
                    />
                    <Button
                        disabled={busy || !query.trim()}
                        onClick={() =>
                            run(() => dochoMutate(SEARCH_DOCHO_TRACKER_FILL_ITEM, { mangaId: item.mangaId, query }))
                        }
                    >
                        {t`Search`}
                    </Button>
                </Stack>
            </CardContent>
            <CardActions>
                <Button
                    disabled={busy}
                    onClick={() => run(() => dochoMutate(SKIP_DOCHO_TRACKER_FILL_ITEM, { mangaId: item.mangaId }))}
                >
                    {t`Skip this series`}
                </Button>
            </CardActions>
        </Card>
    );
}

/** The list a scan left: conflicts to decide on, and series ready to apply. */
export function DochoTrackerFillReview({ onClose, onChanged }: { onClose: () => void; onChanged: () => void }) {
    const { t } = useLingui();
    const [tab, setTab] = useState<'conflicts' | 'ready'>('conflicts');
    const [shown, setShown] = useState(PAGE_SIZE);
    const [busy, setBusy] = useState(false);
    const { data, loading, refetch } = useDochoQuery<{ dochoTrackerFillItems: DochoTrackerFillItem[] }>(
        GET_DOCHO_TRACKER_FILL_ITEMS,
    );
    const items = data?.dochoTrackerFillItems ?? [];
    const ready = items.filter((item) => item.problem === 'READY');
    const conflicts = items.filter((item) => item.problem !== 'READY');
    const list = tab === 'ready' ? ready : conflicts;

    const run = async (action: () => Promise<unknown>) => {
        setBusy(true);
        try {
            await action();
            await refetch();
            onChanged();
        } catch (e) {
            makeToast(t`That didn't work`, 'error', getErrorMessage(e));
        } finally {
            setBusy(false);
        }
    };

    const applyReady = () =>
        run(async () => {
            const result = await dochoMutate<
                { applyReadyDochoTrackerFill: { applied: number; failed: number } },
                Record<string, never>
            >(APPLY_READY_DOCHO_TRACKER_FILL, {});
            const { applied, failed } = result.applyReadyDochoTrackerFill;
            makeToast(t`Applied ${applied} series, ${failed} failed`, failed ? 'warning' : 'success');
        });

    const dismiss = () => {
        // eslint-disable-next-line no-alert
        if (window.confirm(t`Keep what every series has and clear all ${conflicts.length} conflicts?`)) {
            run(() => dochoMutate(DISMISS_DOCHO_TRACKER_FILL_CONFLICTS, {}));
        }
    };

    return (
        <Dialog open onClose={onClose} fullWidth maxWidth="md">
            <DialogTitle>{t`Review tracker details`}</DialogTitle>
            {(busy || (loading && !data)) && <LinearProgress />}
            <Tabs
                value={tab}
                onChange={(_, value) => {
                    setTab(value);
                    setShown(PAGE_SIZE);
                }}
            >
                <Tab value="conflicts" label={t`Conflicts (${conflicts.length})`} />
                <Tab value="ready" label={t`Ready (${ready.length})`} />
            </Tabs>
            <DialogContent dividers>
                <Stack sx={{ gap: 2 }}>
                    {!list.length && !loading && (
                        <Typography color="text.secondary">
                            {tab === 'ready' ? t`Nothing is ready to apply.` : t`No conflicts left.`}
                        </Typography>
                    )}
                    {list.slice(0, shown).map((item) =>
                        item.changes.length ? (
                            <ChangesCard key={item.mangaId} item={item} busy={busy} run={run} />
                        ) : (
                            <MatchCard key={item.mangaId} item={item} busy={busy} run={run} />
                        ),
                    )}
                    {list.length > shown && (
                        <Button onClick={() => setShown(shown + PAGE_SIZE)}>{t`Show more`}</Button>
                    )}
                </Stack>
            </DialogContent>
            <DialogActions>
                {tab === 'ready' && !!ready.length && (
                    <Button disabled={busy} variant="contained" onClick={applyReady} sx={{ mr: 'auto' }}>
                        {t`Apply all ${ready.length}`}
                    </Button>
                )}
                {tab === 'conflicts' && !!conflicts.length && (
                    <Button disabled={busy} color="error" onClick={dismiss} sx={{ mr: 'auto' }}>
                        {t`Keep everything for all`}
                    </Button>
                )}
                <Button onClick={onClose}>{t`Close`}</Button>
            </DialogActions>
        </Dialog>
    );
}
