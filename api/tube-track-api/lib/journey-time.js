const formatter = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23'
});

export function londonParts(value) {
    return Object.fromEntries(formatter.formatToParts(new Date(value))
        .filter((part) => part.type !== 'literal').map((part) => [part.type, part.value]));
}

export function tflDateTime(value) {
    const p = londonParts(value);
    return { date: `${p.year}${p.month}${p.day}`, time: `${p.hour}${p.minute}` };
}

// TfL journey timestamps can omit their timezone. Never let the server's local
// timezone interpret them. At the autumn clock change use the request/leg anchor.
export function parseJourneyTime(value, anchor) {
    if (typeof value !== 'string') return null;
    if (/Z$|[+-]\d{2}:\d{2}$/.test(value)) {
        const parsed = Date.parse(value);
        return Number.isFinite(parsed) ? parsed : null;
    }
    const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?$/.exec(value);
    if (!match) return null;
    const [, year, month, day, hour, minute, second] = match;
    const utc = Date.UTC(+year, +month - 1, +day, +hour, +minute, +second);
    const candidates = [utc, utc - 3_600_000].filter((candidate) => {
        const p = londonParts(candidate);
        return p.year === year && p.month === month && p.day === day
            && p.hour === hour && p.minute === minute && p.second === second;
    });
    candidates.sort((a, b) => Math.abs(a - anchor) - Math.abs(b - anchor));
    return candidates[0] ?? null;
}

export function explicitInstant(value) {
    if (typeof value !== 'string'
        || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) return null;
    const date = value.slice(0, 10);
    if (+value.slice(11, 13) > 23 || +value.slice(14, 16) > 59 || +value.slice(17, 19) > 59) return null;
    const calendarDate = new Date(`${date}T00:00:00Z`);
    if (!Number.isFinite(+calendarDate) || calendarDate.toISOString().slice(0, 10) !== date) return null;
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : null;
}
