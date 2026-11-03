/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { useId } from 'react';
import type { SvgIconProps } from '@mui/material/SvgIcon';
import SvgIcon from '@mui/material/SvgIcon';

/**
 * Dōchō Server's icon: a server with a Dōchō sticker on it (server/branding/docho-server-icon.svg).
 * It keeps Suwayomi's name and props, so upstream code that shows the logo needs no changes; the
 * colour props are ignored.
 */
export const SuwayomiLogo = ({
    circleRingColor: _ring,
    circleFillColor: _fill,
    ...props
}: SvgIconProps & { circleRingColor?: string; circleFillColor?: string }) => {
    const id = useId().replace(/:/g, '');
    const clip = `docho-logo-clip-${id}`;
    const shadow = `docho-logo-shadow-${id}`;
    return (
        <SvgIcon {...props} viewBox="0 0 432 432">
            <defs>
            <clipPath id={clip}><circle cx="216" cy="216" r="216"/></clipPath>
            <filter id={shadow} x="-20%" y="-20%" width="140%" height="140%">
            <feDropShadow dx="0" dy="6" stdDeviation="6" floodColor="#000" floodOpacity="0.35"/>
            </filter>
            </defs>
            <g clipPath={`url(#${clip})`}>
            <rect width="432" height="432" fill="#3D8FD9"/>
            <g filter={`url(#${shadow})`}>
            <g transform="translate(0,92)">
            <rect x="92" y="0" width="248" height="76" rx="14" fill="#1C2733"/>
            <rect x="92" y="0" width="248" height="10" rx="5" fill="#2A3A4A"/>
            <rect x="106" y="18" width="226" height="50" rx="8" fill="#16202A"/>
            <g fill="#2C3D4E"><rect x="246" y="30" width="72" height="5" rx="2.5"/><rect x="246" y="40" width="72" height="5" rx="2.5"/><rect x="246" y="50" width="72" height="5" rx="2.5"/></g>
            <circle cx="226" cy="42" r="6" fill="#5BE37D"/>
            <circle cx="208" cy="42" r="6" fill="#3D8FD9"/>
            </g>
            <g transform="translate(0,178)">
            <rect x="92" y="0" width="248" height="76" rx="14" fill="#1C2733"/>
            <rect x="92" y="0" width="248" height="10" rx="5" fill="#2A3A4A"/>
            <rect x="106" y="18" width="226" height="50" rx="8" fill="#16202A"/>
            <g fill="#2C3D4E"><rect x="246" y="30" width="72" height="5" rx="2.5"/><rect x="246" y="40" width="72" height="5" rx="2.5"/><rect x="246" y="50" width="72" height="5" rx="2.5"/></g>
            <circle cx="226" cy="42" r="6" fill="#5BE37D"/>
            <circle cx="208" cy="42" r="6" fill="#3D8FD9"/>
            </g>
            <g transform="translate(0,264)">
            <rect x="92" y="0" width="248" height="76" rx="14" fill="#1C2733"/>
            <rect x="92" y="0" width="248" height="10" rx="5" fill="#2A3A4A"/>
            <rect x="106" y="18" width="226" height="50" rx="8" fill="#16202A"/>
            <g fill="#2C3D4E"><rect x="246" y="30" width="72" height="5" rx="2.5"/><rect x="246" y="40" width="72" height="5" rx="2.5"/><rect x="246" y="50" width="72" height="5" rx="2.5"/></g>
            <circle cx="226" cy="42" r="6" fill="#5BE37D"/>
            <circle cx="208" cy="42" r="6" fill="#3D8FD9"/>
            </g>
            </g>
            <g transform="translate(166,222) rotate(-9) scale(0.66) translate(-216,-215.5)" filter={`url(#${shadow})`}>
            <ellipse cx="216.07" cy="215.5" rx="122" ry="119" fill="#FFFFFF"/>
            <path d="M322.13,215.5C322.13,272.66 274.64,319 216.07,319C157.49,319 110,272.66 110,215.5C110,158.34 157.49,112 216.07,112C274.64,112 322.13,158.34 322.13,215.5Z" fill="#FFFFFF"/>
            <path d="M216.07,299.59C263.66,299.59 302.24,261.94 302.24,215.5C302.24,169.06 263.66,131.41 216.07,131.41C168.47,131.41 129.89,169.06 129.89,215.5C129.89,261.94 168.47,299.59 216.07,299.59ZM216.07,319C274.64,319 322.13,272.66 322.13,215.5C322.13,158.34 274.64,112 216.07,112C157.49,112 110,158.34 110,215.5C110,272.66 157.49,319 216.07,319Z" fill="#0058A0" fillRule="evenodd"/>
            <path d="M188.91 187.31H242.75V198.17H188.91ZM193.99 206.37H205.83V249.73H193.99ZM200.47 206.37H237.97V242.58H200.47V231.89H226.04V216.96H200.47ZM170.19 167.5H256.24V179.68H182.73V263.46H170.19ZM249.11 167.5H261.81V248.63Q261.81 253.62 260.61 256.57Q259.4 259.51 256.31 261.03Q253.25 262.64 248.6 263.08Q243.95 263.52 237.18 263.5Q236.99 261.73 236.3 259.4Q235.62 257.07 234.72 254.76Q233.82 252.44 232.83 250.76Q237.06 250.95 241.12 250.99Q245.19 251.03 246.59 251.01Q248 250.91 248.55 250.34Q249.11 249.78 249.11 248.45Z" fill="#031019"/>
            </g>
            </g>
        </SvgIcon>
    );
};
