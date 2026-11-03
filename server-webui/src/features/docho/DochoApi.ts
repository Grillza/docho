/*
 * Copyright (C) Contributors to the Dōchō project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import gql from 'graphql-tag';
import { useMutation, useQuery } from '@apollo/client/react';
import { requestManager } from '@/lib/requests/RequestManager.ts';

// Dōchō Server's own API: Kavita-style libraries, series groups and collections.
// Written by hand rather than generated, so the upstream codegen setup stays untouched.

export type DochoLibraryType = 'MANGA' | 'COMIC' | 'BOOK' | 'LIGHT_NOVEL' | 'IMAGE';
export type DochoFileType = 'ARCHIVE' | 'EPUB' | 'PDF' | 'IMAGES';
export type DochoGroupSortMode = 'MANUAL' | 'PART_NUMBER' | 'RELEASE_YEAR' | 'TITLE';
export type DochoChapterLabelStyle = 'LABEL_PREFIX' | 'CONTINUOUS' | 'CONTINUOUS_WITH_LABEL' | 'ORIGINAL';

export type DochoManga = {
    id: number;
    title: string;
    thumbnailUrl?: string | null;
    sourceId: string;
    inLibrary: boolean;
};

export type DochoLibrary = {
    id: number;
    name: string;
    type: DochoLibraryType;
    folders: string[];
    fileTypes: DochoFileType[];
    excludePatterns: string[];
    includeInDashboard: boolean;
    includeInSearch: boolean;
    useMetadata: boolean;
    manageCollections: boolean;
    manageGroups: boolean;
    folderCollections: boolean;
    folderWatching: boolean;
    scanIntervalMinutes: number;
    sortOrder: number;
    sourceId: string;
    lastScannedAt: number;
    lastScanResult?: string | null;
    scanning: boolean;
    seriesCount: number;
};

export type DochoLibraryInput = Partial<
    Pick<
        DochoLibrary,
        | 'name'
        | 'type'
        | 'folders'
        | 'fileTypes'
        | 'excludePatterns'
        | 'includeInDashboard'
        | 'includeInSearch'
        | 'useMetadata'
        | 'manageCollections'
        | 'manageGroups'
        | 'folderCollections'
        | 'folderWatching'
        | 'scanIntervalMinutes'
        | 'sortOrder'
    >
>;

export type DochoGroupMember = {
    mangaId: number;
    position: number;
    label?: string | null;
    displayLabel: string;
    title: string;
    manga?: DochoManga | null;
};

export type DochoSeriesGroup = {
    id: number;
    name: string;
    description: string;
    sortMode: DochoGroupSortMode;
    chapterLabel: DochoChapterLabelStyle;
    hideMembers: boolean;
    coverMangaId?: number | null;
    mangaId?: number | null;
    members: DochoGroupMember[];
};

export type DochoGroupInput = Partial<
    Pick<DochoSeriesGroup, 'name' | 'description' | 'sortMode' | 'chapterLabel' | 'hideMembers' | 'coverMangaId'>
>;

export type DochoGroupSuggestion = {
    name: string;
    mangaIds: number[];
    labels: string[];
    series: DochoManga[];
};

export type DochoSeriesField =
    | 'TITLE'
    | 'LOCALIZED_NAME'
    | 'SORT_NAME'
    | 'SUMMARY'
    | 'WRITERS'
    | 'ARTISTS'
    | 'GENRES'
    | 'STATUS'
    | 'PUBLISHER'
    | 'RELEASE_YEAR'
    | 'AGE_RATING'
    | 'LANGUAGE';

export type DochoSeriesDetails = {
    mangaId: number;
    editable: boolean;
    libraryId: number | null;
    title: string | null;
    localizedName: string | null;
    sortName: string | null;
    summary: string | null;
    writers: string[];
    artists: string[];
    genres: string[];
    status: number | null;
    publisher: string | null;
    releaseYear: number | null;
    ageRating: string | null;
    language: string | null;
    format: string | null;
    pageCount: number | null;
    editedFields: DochoSeriesField[];
    collections: { id: number; name: string }[];
    group: { id: number; name: string; mangaId: number } | null;
};

export type DochoSeriesEditInput = {
    mangaId: number;
    title?: string;
    localizedName?: string;
    sortName?: string;
    summary?: string;
    writers?: string[];
    artists?: string[];
    genres?: string[];
    status?: number;
    publisher?: string;
    releaseYear?: number;
    ageRating?: string;
    language?: string;
    reset?: DochoSeriesField[];
};

/** Library sources have ids 0x0D0C000000000000 + library id; the Series Groups source is the base itself. */
const LIBRARY_SOURCE_BASE = BigInt('0x0D0C000000000000');

export const isDochoLibrarySource = (sourceId: string | number | null | undefined): boolean => {
    if (sourceId === null || sourceId === undefined) return false;
    try {
        const id = BigInt(sourceId);
        return id > LIBRARY_SOURCE_BASE && id <= LIBRARY_SOURCE_BASE + BigInt(0x7fffffff);
    } catch {
        return false;
    }
};

export type DochoCollection = {
    id: number;
    name: string;
    summary: string;
    origin: 'MANUAL' | 'METADATA' | 'FOLDER';
    libraryId?: number | null;
    promoted: boolean;
    seriesCount: number;
    series: DochoManga[];
};

const MANGA_FIELDS = gql`
    fragment DochoMangaFields on MangaType {
        id
        title
        thumbnailUrl
        sourceId
        inLibrary
    }
`;

const LIBRARY_FIELDS = gql`
    fragment DochoLibraryFields on DochoLibrary {
        id
        name
        type
        folders
        fileTypes
        excludePatterns
        includeInDashboard
        includeInSearch
        useMetadata
        manageCollections
        manageGroups
        folderCollections
        folderWatching
        scanIntervalMinutes
        sortOrder
        sourceId
        lastScannedAt
        lastScanResult
        scanning
        seriesCount
    }
`;

const GROUP_FIELDS = gql`
    ${MANGA_FIELDS}
    fragment DochoGroupFields on DochoSeriesGroup {
        id
        name
        description
        sortMode
        chapterLabel
        hideMembers
        coverMangaId
        mangaId
        members {
            mangaId
            position
            label
            displayLabel
            title
            manga {
                ...DochoMangaFields
            }
        }
    }
`;

export const GET_DOCHO_LIBRARIES = gql`
    ${LIBRARY_FIELDS}
    query DochoLibraries {
        dochoLibraries {
            ...DochoLibraryFields
        }
    }
`;

export const GET_DOCHO_LIBRARY_ROOT = gql`
    query DochoLibraryRoot {
        dochoServerInfo {
            libraryRoot
        }
    }
`;

export const GET_DOCHO_FOLDERS = gql`
    query DochoFolders($path: String) {
        dochoFolders(path: $path) {
            name
            path
        }
    }
`;

export const CREATE_DOCHO_LIBRARY = gql`
    ${LIBRARY_FIELDS}
    mutation CreateDochoLibrary($input: LibraryInput!) {
        createDochoLibrary(input: $input) {
            ...DochoLibraryFields
        }
    }
`;

export const UPDATE_DOCHO_LIBRARY = gql`
    ${LIBRARY_FIELDS}
    mutation UpdateDochoLibrary($id: Int!, $input: LibraryInput!) {
        updateDochoLibrary(id: $id, input: $input) {
            ...DochoLibraryFields
        }
    }
`;

export const DELETE_DOCHO_LIBRARY = gql`
    mutation DeleteDochoLibrary($id: Int!) {
        deleteDochoLibrary(id: $id)
    }
`;

export const SCAN_DOCHO_LIBRARY = gql`
    mutation ScanDochoLibrary($id: Int!) {
        scanDochoLibrary(id: $id)
    }
`;

export const GET_DOCHO_GROUPS = gql`
    ${GROUP_FIELDS}
    query DochoSeriesGroups {
        dochoSeriesGroups {
            ...DochoGroupFields
        }
        dochoGroupSuggestions {
            name
            mangaIds
            labels
            series {
                ...DochoMangaFields
            }
        }
    }
`;

export const SEARCH_LIBRARY_MANGAS = gql`
    ${MANGA_FIELDS}
    query DochoLibraryMangas($query: String!) {
        mangas(
            filter: { inLibrary: { equalTo: true }, title: { includesInsensitive: $query } }
            first: 40
            order: [{ by: TITLE }]
        ) {
            nodes {
                ...DochoMangaFields
            }
        }
    }
`;

export const SUGGEST_LABELS = gql`
    query DochoSuggestLabels($name: String!, $mangaIds: [Int!]!) {
        dochoSuggestLabels(name: $name, mangaIds: $mangaIds)
    }
`;

export const CREATE_DOCHO_GROUP = gql`
    ${GROUP_FIELDS}
    mutation CreateDochoSeriesGroup($name: String!, $mangaIds: [Int!]!, $labels: [String], $input: GroupInput) {
        createDochoSeriesGroup(name: $name, mangaIds: $mangaIds, labels: $labels, input: $input) {
            ...DochoGroupFields
        }
    }
`;

export const UPDATE_DOCHO_GROUP = gql`
    ${GROUP_FIELDS}
    mutation UpdateDochoSeriesGroup($id: Int!, $input: GroupInput!) {
        updateDochoSeriesGroup(id: $id, input: $input) {
            ...DochoGroupFields
        }
    }
`;

export const SET_DOCHO_GROUP_MEMBERS = gql`
    ${GROUP_FIELDS}
    mutation SetDochoSeriesGroupMembers($id: Int!, $mangaIds: [Int!]!) {
        setDochoSeriesGroupMembers(id: $id, mangaIds: $mangaIds) {
            ...DochoGroupFields
        }
    }
`;

export const SET_DOCHO_GROUP_LABEL = gql`
    ${GROUP_FIELDS}
    mutation SetDochoSeriesGroupLabel($id: Int!, $mangaId: Int!, $label: String) {
        setDochoSeriesGroupLabel(id: $id, mangaId: $mangaId, label: $label) {
            ...DochoGroupFields
        }
    }
`;

export const AUTO_LABEL_DOCHO_GROUP = gql`
    ${GROUP_FIELDS}
    mutation AutoLabelDochoSeriesGroup($id: Int!) {
        autoLabelDochoSeriesGroup(id: $id) {
            ...DochoGroupFields
        }
    }
`;

export const DELETE_DOCHO_GROUP = gql`
    mutation DeleteDochoSeriesGroup($id: Int!) {
        deleteDochoSeriesGroup(id: $id)
    }
`;

export const GET_DOCHO_COLLECTIONS = gql`
    ${MANGA_FIELDS}
    query DochoCollections {
        dochoCollections {
            id
            name
            summary
            origin
            libraryId
            promoted
            seriesCount
            series {
                ...DochoMangaFields
            }
        }
    }
`;

export const CREATE_DOCHO_COLLECTION = gql`
    mutation CreateDochoCollection($name: String!, $summary: String, $mangaIds: [Int!]) {
        createDochoCollection(name: $name, summary: $summary, mangaIds: $mangaIds) {
            id
        }
    }
`;

export const UPDATE_DOCHO_COLLECTION = gql`
    mutation UpdateDochoCollection($id: Int!, $name: String, $summary: String, $promoted: Boolean) {
        updateDochoCollection(id: $id, name: $name, summary: $summary, promoted: $promoted) {
            id
        }
    }
`;

export const SET_DOCHO_COLLECTION_SERIES = gql`
    mutation SetDochoCollectionSeries($id: Int!, $mangaIds: [Int!]!) {
        setDochoCollectionSeries(id: $id, mangaIds: $mangaIds) {
            id
        }
    }
`;

export const DELETE_DOCHO_COLLECTION = gql`
    mutation DeleteDochoCollection($id: Int!) {
        deleteDochoCollection(id: $id)
    }
`;

const SERIES_DETAILS_FIELDS = `
    mangaId
    editable
    libraryId
    title
    localizedName
    sortName
    summary
    writers
    artists
    genres
    status
    publisher
    releaseYear
    ageRating
    language
    format
    pageCount
    editedFields
    collections {
        id
        name
    }
    group {
        id
        name
        mangaId
    }
`;

export const GET_DOCHO_SERIES_INFO = gql`
    query DochoSeriesInfo($mangaId: Int!) {
        dochoSeriesInfo(mangaId: $mangaId) {
            ${SERIES_DETAILS_FIELDS}
        }
    }
`;

export const EDIT_DOCHO_SERIES = gql`
    mutation EditDochoSeries($input: DochoSeriesEditInput!) {
        editDochoSeries(input: $input) {
            ${SERIES_DETAILS_FIELDS}
        }
    }
`;

export const dochoClient = () => requestManager.graphQLClient.client;

export const useDochoQuery = <TData, TVars extends Record<string, unknown> = Record<string, never>>(
    document: ReturnType<typeof gql>,
    variables?: TVars,
    options: { skip?: boolean; pollInterval?: number } = {},
) => {
    const result = useQuery<TData, TVars>(document, {
        client: dochoClient(),
        variables: variables as TVars,
        fetchPolicy: 'cache-and-network',
        ...options,
    } as any);
    // These queries always ask for whole objects, so the data is complete once it arrives.
    return { ...result, data: result.data as TData | undefined };
};

export const useDochoMutation = <TData, TVars extends Record<string, unknown>>(document: ReturnType<typeof gql>) =>
    useMutation<TData, TVars>(document, { client: dochoClient() } as any);

export const dochoMutate = async <TData, TVars extends Record<string, unknown>>(
    document: ReturnType<typeof gql>,
    variables: TVars,
): Promise<TData> => {
    const result = await dochoClient().mutate<TData, TVars>({ mutation: document, variables } as any);
    return result.data as TData;
};

export const dochoQuery = async <TData, TVars extends Record<string, unknown>>(
    document: ReturnType<typeof gql>,
    variables: TVars,
): Promise<TData> => {
    const result = await dochoClient().query<TData, TVars>({ query: document, variables, fetchPolicy: 'network-only' } as any);
    return result.data as TData;
};

export const thumbnailOf = (manga?: Pick<DochoManga, 'thumbnailUrl'> | null): string | undefined =>
    manga?.thumbnailUrl ? requestManager.getValidImgUrlFor(manga.thumbnailUrl) : undefined;
