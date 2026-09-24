// Mirrors TubeTrackCore's `LineServiceCondition`, so a pushed board tints and
// captions itself exactly as the app and widgets would.
//
// Only the rank and the headline cross the wire; the client rebuilds the rest
// from them (`LineServiceCondition.init(severityRank:headline:)`).

export const SEVERITY_RANKS = Object.freeze({
    majorDisruption: 0,
    minorDisruption: 1,
    overnightClosure: 2,
    updating: 3,
    good: 4
});

const RESUMPTION_PHRASES = [
    'service will resume',
    'resume later this morning',
    'service is closed'
];

function isGoodService(entry) {
    return entry.statusSeverity === 10 || entry.statusSeverity === 18;
}

function isOvernightClosure(entry) {
    if (entry.statusSeverity !== 20) return false;
    const reason = String(entry.reason ?? '').toLowerCase();
    return RESUMPTION_PHRASES.some((phrase) => reason.includes(phrase));
}

function isActionableIssue(entry) {
    return !isGoodService(entry) && !isOvernightClosure(entry);
}

/**
 * The condition for one line, from TfL's `/Line/Mode/.../Status` rows.
 *
 * Returns `{ rank, headline }`, where `headline` is null for a healthy line —
 * a Live Activity showing "Good service" under every departure is noise.
 */
export function conditionFor(lineStatus) {
    const entries = Array.isArray(lineStatus?.lineStatuses) ? lineStatus.lineStatuses : [];
    if (entries.length === 0) {
        return { rank: SEVERITY_RANKS.updating, headline: null };
    }

    const closure = entries.find(isOvernightClosure);
    if (closure) {
        return {
            rank: SEVERITY_RANKS.overnightClosure,
            headline: closure.statusSeverityDescription ?? 'Service closed'
        };
    }

    const major = entries.find(
        (entry) => isActionableIssue(entry) && entry.statusSeverity !== 9
    );
    if (major) {
        return {
            rank: SEVERITY_RANKS.majorDisruption,
            headline: major.statusSeverityDescription ?? 'Severe delays'
        };
    }

    const minor = entries.find(isActionableIssue);
    if (minor) {
        return {
            rank: SEVERITY_RANKS.minorDisruption,
            headline: minor.statusSeverityDescription ?? 'Minor delays'
        };
    }

    return { rank: SEVERITY_RANKS.good, headline: null };
}

/** Indexes a whole `/api/v1/status` response by line id. */
export function conditionsByLine(statuses) {
    const conditions = new Map();
    for (const lineStatus of Array.isArray(statuses) ? statuses : []) {
        if (!lineStatus?.id) continue;
        conditions.set(lineStatus.id, conditionFor(lineStatus));
    }
    return conditions;
}
