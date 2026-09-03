const SECRET_KEY_PATTERN = /(?:api[_-]?key|authorization|password|secret|token)/i;

function serializeError(error) {
    if (!(error instanceof Error)) {
        return String(error);
    }
    return {
        name: error.name,
        message: error.message,
        code: error.code,
        status: error.status
    };
}

function redact(value, seen = new WeakSet()) {
    if (value instanceof Error) {
        return serializeError(value);
    }
    if (Array.isArray(value)) {
        return value.map((item) => redact(item, seen));
    }
    if (!value || typeof value !== 'object') {
        return value;
    }
    if (seen.has(value)) {
        return '[Circular]';
    }
    seen.add(value);

    return Object.fromEntries(
        Object.entries(value).map(([key, item]) => [
            key,
            SECRET_KEY_PATTERN.test(key) ? '[REDACTED]' : redact(item, seen)
        ])
    );
}

export function createLogger(output = console) {
    function write(level, event, details = {}) {
        const record = {
            timestamp: new Date().toISOString(),
            level,
            event,
            ...redact(details)
        };
        const method = level === 'error' ? 'error' : level === 'warn' ? 'warn' : 'log';
        output[method](JSON.stringify(record));
    }

    return Object.freeze({
        info: (event, details) => write('info', event, details),
        warn: (event, details) => write('warn', event, details),
        error: (event, details) => write('error', event, details)
    });
}
