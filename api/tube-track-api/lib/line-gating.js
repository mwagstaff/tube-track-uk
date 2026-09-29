// Released app builds decode line identifiers strictly, so one unknown line
// makes them reject an entire status or planned-works response. Lines added
// after those builds are only served to clients that ask for them by name.
export const GATED_LINE_IDS = Object.freeze(new Set(['thameslink']));

export function includedLineIDs(query) {
    const value = query?.include;
    if (typeof value !== 'string') return new Set();
    return new Set(value.split(',').map((part) => part.trim().toLowerCase())
        .filter((lineID) => GATED_LINE_IDS.has(lineID)));
}

export function isVisibleLine(lineID, included) {
    return !GATED_LINE_IDS.has(lineID) || included.has(lineID);
}

export function visibleLines(items, included, lineID = (item) => item?.id) {
    return Array.isArray(items) ? items.filter((item) => isVisibleLine(lineID(item), included)) : items;
}
