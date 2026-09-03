function optionalString(value) {
    return typeof value === 'string' && value.length > 0 ? value : null;
}

function optionalInteger(value) {
    return Number.isFinite(value) ? Math.max(0, Math.trunc(value)) : null;
}

function secondsUntil(expectedArrival, timestamp) {
    const expected = Date.parse(expectedArrival);
    const observed = Date.parse(timestamp);
    if (!Number.isFinite(expected) || !Number.isFinite(observed)) {
        return null;
    }
    return Math.max(0, Math.round((expected - observed) / 1_000));
}

export function normaliseArrival(prediction, fallbackMode) {
    if (!prediction || typeof prediction !== 'object') {
        return null;
    }

    const id = optionalString(prediction.id);
    const stopId = optionalString(prediction.naptanId);
    const lineId = optionalString(prediction.lineId);
    if (!id || !stopId || !lineId) {
        return null;
    }

    const expectedArrival = optionalString(prediction.expectedArrival);
    const timestamp = optionalString(prediction.timestamp);
    const timeToStation = optionalInteger(prediction.timeToStation)
        ?? secondsUntil(expectedArrival, timestamp);

    return Object.freeze({
        id,
        vehicleId: optionalString(prediction.vehicleId),
        stopId,
        stationName: optionalString(prediction.stationName),
        lineId,
        mode: optionalString(prediction.modeName) ?? fallbackMode,
        platformName: optionalString(prediction.platformName),
        direction: optionalString(prediction.direction),
        destinationStopId: optionalString(prediction.destinationNaptanId),
        destinationName: optionalString(prediction.destinationName),
        timeToStation,
        expectedArrival,
        currentLocation: optionalString(prediction.currentLocation),
        towards: optionalString(prediction.towards),
        timestamp
    });
}

export function normaliseArrivals(predictions, fallbackMode) {
    if (!Array.isArray(predictions)) {
        throw new TypeError(`TfL arrivals for ${fallbackMode} must be an array`);
    }

    return predictions
        .map((prediction) => normaliseArrival(prediction, fallbackMode))
        .filter(Boolean);
}
