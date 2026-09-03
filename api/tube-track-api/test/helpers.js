export function prediction({
    id = 'prediction-1',
    vehicleId = 'vehicle-1',
    naptanId = '940GZZLUSVS',
    lineId = 'victoria',
    modeName = 'tube',
    timeToStation = 90
} = {}) {
    return {
        id,
        vehicleId,
        naptanId,
        stationName: 'Seven Sisters Underground Station',
        lineId,
        lineName: 'Victoria',
        platformName: 'Northbound - Platform 3',
        direction: 'outbound',
        destinationNaptanId: '940GZZLUWWL',
        destinationName: 'Walthamstow Central Underground Station',
        timestamp: '2026-09-02T18:05:39.933Z',
        currentLocation: 'Between stations',
        towards: 'Walthamstow Central',
        expectedArrival: '2026-09-02T18:07:09.933Z',
        timeToStation,
        modeName
    };
}
