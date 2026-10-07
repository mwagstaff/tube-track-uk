import { readFileSync } from 'node:fs';

export const NATIONAL_RAIL_DIRECTION_DATA = JSON.parse(readFileSync(
    new URL('../../data/national-rail-directions.json', import.meta.url), 'utf8'));
const coordinates = NATIONAL_RAIL_DIRECTION_DATA.coordinatesByStation;
const normalized = (code) => typeof code === 'string' ? code.trim().toUpperCase() : '';

/** Mirrors NationalRailDirection.resolve in TubeTrackCore.
 * Diagonal bearings join north/south; east/west cover bearings within 22.5°
 * of those points. Every portion of a dividing train must agree.
 */
export function nationalRailDirection({ station, destinations = [] }) {
    const start = coordinates[normalized(station)];
    if (!Array.isArray(start) || start.length !== 2 || !destinations.length) return null;
    const directions = destinations.map((destination) => {
        const end = coordinates[normalized(destination)];
        if (!Array.isArray(end) || end.length !== 2 || start[0] === end[0] && start[1] === end[1]) return null;
        const latitude = start[0] * Math.PI / 180;
        const destinationLatitude = end[0] * Math.PI / 180;
        const longitudeDelta = (end[1] - start[1]) * Math.PI / 180;
        const east = Math.sin(longitudeDelta) * Math.cos(destinationLatitude);
        const north = Math.cos(latitude) * Math.sin(destinationLatitude)
            - Math.sin(latitude) * Math.cos(destinationLatitude) * Math.cos(longitudeDelta);
        const bearing = (Math.atan2(east, north) * 180 / Math.PI + 360) % 360;
        if (bearing >= 67.5 && bearing < 112.5) return 'eastbound';
        if (bearing >= 112.5 && bearing < 247.5) return 'southbound';
        if (bearing >= 247.5 && bearing < 292.5) return 'westbound';
        return 'northbound';
    });
    return directions[0] && directions.every((direction) => direction === directions[0]) ? directions[0] : null;
}
