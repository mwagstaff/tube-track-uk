# TfL Map Structural Fidelity Audit

## Anti-pattern verdict

Pass for the audited map layer. The artwork is authored, data-driven, and restrained; the current risk is fidelity drift, not generic decorative UI. This report does not assess unrelated screens.

## Executive summary

- Reference: Transport for London Standard Tube Map (April 2026)
- Artwork: `tube-track-uk.beck.full-underground.v1`
- Findings: 115 total (high: 80, medium: 35)
- Status: candidate deviations require visual confirmation against the locked reference before geometry changes

### Most important next steps

1. Review every high-severity connector and route-angle candidate against the official reference.
2. Resolve detached roundels, connector endpoints, or non-perpendicular ticks before cosmetic tuning.
3. Pin source-profile-correct line colours and add masked visual comparisons.
4. Convert confirmed corrections into station- and segment-specific regression fixtures.

## Detailed findings by severity

### Critical (0)

No findings.

### High (80)

#### `connector-angle-review` - 910GBARKING primitive 0

- Category: connectors
- Description: An internal connector is 28.178 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":28.178,"deviationDegrees":16.822,"end":[3587.523,1525.187],"kind":"connector","length":51.653,"nearestCanonicalAngle":45.0,"start":[3541.992,1549.578],"stationID":"910GBARKING","stationName":"Barking"}`

#### `connector-angle-review` - 910GCLPHMJC primitive 0

- Category: connectors
- Description: An internal connector is 42.099 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":42.099,"deviationDegrees":2.901,"end":[1477.407,2266.062],"kind":"connector","length":43.653,"nearestCanonicalAngle":45.0,"start":[1509.797,2295.328],"stationID":"910GCLPHMJC","stationName":"Clapham Junction"}`

#### `connector-endpoint-without-roundel` - 910GCNDAW primitive 0

- Category: connectors
- Description: The connector start does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[2705.0,1918.0],"endpoint":"start","kind":"connector","nearestDistance":24.197,"nearestRoundel":{"primitiveIndex":1,"stationID":"910GCNDAW"},"stationID":"910GCNDAW"}`

#### `connector-angle-review` - 910GEUSTON primitive 0

- Category: connectors
- Description: An internal connector is 38.005 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":38.005,"deviationDegrees":6.995,"end":[1962.828,1345.609],"kind":"connector","length":41.591,"nearestCanonicalAngle":45.0,"start":[1995.6,1320.0],"stationID":"910GEUSTON","stationName":"London Euston"}`

#### `connector-angle-review` - 910GKENOLYM primitive 0

- Category: connectors
- Description: An internal connector is 4.948 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":4.948,"deviationDegrees":4.948,"end":[1306.969,1766.473],"kind":"connector","length":28.983,"nearestCanonicalAngle":0.0,"start":[1335.844,1763.973],"stationID":"910GKENOLYM","stationName":"Kensington (Olympia)"}`

#### `connector-endpoint-without-roundel` - 910GKENOLYM primitive 0

- Category: connectors
- Description: The connector start does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[1335.844,1763.973],"endpoint":"start","kind":"connector","nearestDistance":28.983,"nearestRoundel":{"primitiveIndex":1,"stationID":"910GKENOLYM"},"stationID":"910GKENOLYM"}`

#### `connector-angle-review` - 910GLIVST primitive 0

- Category: connectors
- Description: An internal connector is 47.380 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":47.38,"deviationDegrees":2.38,"end":[2444.88,1426.488],"kind":"connector","length":81.002,"nearestCanonicalAngle":45.0,"start":[2390.031,1486.094],"stationID":"910GLIVST","stationName":"London Liverpool Street"}`

#### `connector-angle-review` - 910GSEVNSIS primitive 0

- Category: connectors
- Description: An internal connector is 43.386 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":43.386,"deviationDegrees":1.614,"end":[2708.25,935.207],"kind":"connector","length":35.776,"nearestCanonicalAngle":45.0,"start":[2734.25,959.782],"stationID":"910GSEVNSIS","stationName":"Seven Sisters"}`

#### `connector-angle-review` - 910GSHADWEL primitive 0

- Category: connectors
- Description: An internal connector is 42.976 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":42.976,"deviationDegrees":2.024,"end":[2704.938,1718.422],"kind":"connector","length":58.356,"nearestCanonicalAngle":45.0,"start":[2747.634,1758.203],"stationID":"910GSHADWEL","stationName":"Shadwell"}`

#### `connector-angle-review` - 910GSHPDSB primitive 0

- Category: connectors
- Description: An internal connector is 21.961 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":21.961,"deviationDegrees":21.961,"end":[1275.747,1701.756],"kind":"connector","length":51.78,"nearestCanonicalAngle":0.0,"start":[1323.77,1682.391],"stationID":"910GSHPDSB","stationName":"Shepherds Bush"}`

#### `connector-endpoint-without-roundel` - 910GSHPDSB primitive 0

- Category: connectors
- Description: The connector start does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[1323.77,1682.391],"endpoint":"start","kind":"connector","nearestDistance":51.78,"nearestRoundel":{"primitiveIndex":1,"stationID":"910GSHPDSB"},"stationID":"910GSHPDSB"}`

#### `connector-angle-review` - 910GUPMNSTR primitive 0

- Category: connectors
- Description: An internal connector is 85.626 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":85.626,"deviationDegrees":4.374,"end":[3940.062,1171.437],"kind":"connector","length":30.357,"nearestCanonicalAngle":90.0,"start":[3937.747,1201.706],"stationID":"910GUPMNSTR","stationName":"Upminster"}`

#### `connector-angle-review` - 910GWBRMPTN primitive 0

- Category: connectors
- Description: An internal connector is 4.647 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":4.647,"deviationDegrees":4.647,"end":[1306.969,1947.455],"kind":"connector","length":28.907,"nearestCanonicalAngle":0.0,"start":[1335.781,1949.797],"stationID":"910GWBRMPTN","stationName":"West Brompton"}`

#### `connector-endpoint-without-roundel` - 910GWBRMPTN primitive 0

- Category: connectors
- Description: The connector start does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[1335.781,1949.797],"endpoint":"start","kind":"connector","nearestDistance":28.907,"nearestRoundel":{"primitiveIndex":1,"stationID":"910GWBRMPTN"},"stationID":"910GWBRMPTN"}`

#### `connector-angle-review` - 910GWHMDSTD primitive 0

- Category: connectors
- Description: An internal connector is 19.509 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":19.509,"deviationDegrees":19.509,"end":[1544.828,1174.922],"kind":"connector","length":47.401,"nearestCanonicalAngle":0.0,"start":[1500.148,1159.092],"stationID":"910GWHMDSTD","stationName":"West Hampstead"}`

#### `connector-angle-review` - 910GWLTWCEN primitive 0

- Category: connectors
- Description: An internal connector is 12.915 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":12.915,"deviationDegrees":12.915,"end":[2986.293,954.805],"kind":"connector","length":22.268,"nearestCanonicalAngle":0.0,"start":[3007.998,959.782],"stationID":"910GWLTWCEN","stationName":"Walthamstow Central"}`

#### `connector-angle-review` - 940GZZCRWCR primitive 0

- Category: connectors
- Description: An internal connector is 52.756 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":52.756,"deviationDegrees":7.756,"end":[2670.517,2669.516],"kind":"connector","length":56.875,"nearestCanonicalAngle":45.0,"start":[2704.938,2624.24],"stationID":"940GZZCRWCR","stationName":"West Croydon"}`

#### `connector-angle-review` - 940GZZCRWMB primitive 0

- Category: connectors
- Description: An internal connector is 49.587 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":49.587,"deviationDegrees":4.587,"end":[1387.281,2406.609],"kind":"connector","length":79.439,"nearestCanonicalAngle":45.0,"start":[1335.781,2346.125],"stationID":"940GZZCRWMB","stationName":"Wimbledon"}`

#### `connector-angle-review` - 940GZZDLCGT primitive 0

- Category: connectors
- Description: An internal connector is 28.024 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":28.024,"deviationDegrees":16.976,"end":[3289.016,1726.297],"kind":"connector","length":67.908,"nearestCanonicalAngle":45.0,"start":[3229.07,1758.203],"stationID":"940GZZDLCGT","stationName":"Canning Town DLR Station"}`

#### `connector-angle-review` - 940GZZDLSTD primitive 0

- Category: connectors
- Description: An internal connector is 2.887 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":2.887,"deviationDegrees":2.887,"end":[3252.75,1271.032],"kind":"connector","length":23.749,"nearestCanonicalAngle":0.0,"start":[3229.031,1269.836],"stationID":"940GZZDLSTD","stationName":"Stratford DLR Station"}`

#### `connector-angle-review` - 940GZZLUBKF primitive 0

- Category: connectors
- Description: An internal connector is 72.938 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":72.938,"deviationDegrees":17.062,"end":[2178.679,1810.696],"kind":"connector","length":4.502,"nearestCanonicalAngle":90.0,"start":[2180.0,1815.0],"stationID":"940GZZLUBKF","stationName":"Blackfriars"}`

#### `connector-angle-review` - 940GZZLUBKF primitive 1

- Category: connectors
- Description: An internal connector is 63.175 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":63.175,"deviationDegrees":18.175,"end":[2182.043,1819.04],"kind":"connector","length":4.527,"nearestCanonicalAngle":45.0,"start":[2180.0,1815.0],"stationID":"940GZZLUBKF","stationName":"Blackfriars"}`

#### `connector-angle-review` - 940GZZLUBND primitive 0

- Category: connectors
- Description: An internal connector is 31.015 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":31.015,"deviationDegrees":13.985,"end":[1682.0,1620.0],"kind":"connector","length":53.674,"nearestCanonicalAngle":45.0,"start":[1728.0,1592.344],"stationID":"940GZZLUBND","stationName":"Bond Street"}`

#### `connector-angle-review` - 940GZZLUBND primitive 1

- Category: connectors
- Description: An internal connector is 37.369 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":37.369,"deviationDegrees":7.631,"end":[1767.999,1561.797],"kind":"connector","length":50.329,"nearestCanonicalAngle":45.0,"start":[1728.0,1592.344],"stationID":"940GZZLUBND","stationName":"Bond Street"}`

#### `connector-angle-review` - 940GZZLUBST primitive 0

- Category: connectors
- Description: An internal connector is 57.189 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":57.189,"deviationDegrees":12.189,"end":[1710.489,1385.796],"kind":"connector","length":52.614,"nearestCanonicalAngle":45.0,"start":[1681.979,1430.016],"stationID":"940GZZLUBST","stationName":"Baker Street"}`

#### `connector-angle-review` - 940GZZLUCST primitive 0

- Category: connectors
- Description: An internal connector is 70.257 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":70.257,"deviationDegrees":19.743,"end":[2263.25,1726.124],"kind":"connector","length":5.181,"nearestCanonicalAngle":90.0,"start":[2265.0,1731.0],"stationID":"940GZZLUCST","stationName":"Cannon Street"}`

#### `connector-angle-review` - 940GZZLUCST primitive 1

- Category: connectors
- Description: An internal connector is 74.163 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":74.163,"deviationDegrees":15.837,"end":[2266.125,1734.966],"kind":"connector","length":4.122,"nearestCanonicalAngle":90.0,"start":[2265.0,1731.0],"stationID":"940GZZLUCST","stationName":"Cannon Street"}`

#### `connector-angle-review` - 940GZZLUCYF primitive 0

- Category: connectors
- Description: An internal connector is 29.370 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":29.37,"deviationDegrees":15.63,"end":[3027.29,1903.547],"kind":"connector","length":70.421,"nearestCanonicalAngle":45.0,"start":[2965.92,1938.085],"stationID":"940GZZLUCYF","stationName":"Canary Wharf"}`

#### `connector-angle-review` - 940GZZLUEMB primitive 0

- Category: connectors
- Description: An internal connector is 46.128 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":46.128,"deviationDegrees":1.128,"end":[1990.353,1868.606],"kind":"connector","length":34.305,"nearestCanonicalAngle":45.0,"start":[1966.578,1843.876],"stationID":"940GZZLUEMB","stationName":"Embankment"}`

#### `connector-angle-review` - 940GZZLUEUS primitive 0

- Category: connectors
- Description: An internal connector is 31.368 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":31.368,"deviationDegrees":13.632,"end":[2028.407,1300.0],"kind":"connector","length":38.423,"nearestCanonicalAngle":45.0,"start":[1995.6,1320.0],"stationID":"940GZZLUEUS","stationName":"Euston"}`

#### `connector-angle-review` - 940GZZLUEUS primitive 1

- Category: connectors
- Description: An internal connector is 53.625 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":53.625,"deviationDegrees":8.625,"end":[2027.754,1363.652],"kind":"connector","length":54.216,"nearestCanonicalAngle":45.0,"start":[1995.6,1320.0],"stationID":"940GZZLUEUS","stationName":"Euston"}`

#### `connector-angle-review` - 940GZZLUHSC primitive 0

- Category: connectors
- Description: An internal connector is 51.100 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":51.1,"deviationDegrees":6.1,"end":[1168.656,1789.903],"kind":"connector","length":13.063,"nearestCanonicalAngle":45.0,"start":[1176.859,1800.069],"stationID":"940GZZLUHSC","stationName":"Hammersmith (H&C Line)"}`

#### `connector-angle-review` - 940GZZLUMGT primitive 0

- Category: connectors
- Description: An internal connector is 49.685 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":49.685,"deviationDegrees":4.685,"end":[2354.687,1521.438],"kind":"connector","length":36.721,"nearestCanonicalAngle":45.0,"start":[2330.929,1549.438],"stationID":"940GZZLUMGT","stationName":"Moorgate"}`

#### `connector-angle-review` - 940GZZLUNHG primitive 0

- Category: connectors
- Description: An internal connector is 14.800 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":14.8,"deviationDegrees":14.8,"end":[1410.266,1683.976],"kind":"connector","length":6.205,"nearestCanonicalAngle":0.0,"start":[1416.265,1682.391],"stationID":"940GZZLUNHG","stationName":"Notting Hill Gate"}`

#### `connector-angle-review` - 940GZZLUPAC primitive 0

- Category: connectors
- Description: An internal connector is 33.189 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":33.189,"deviationDegrees":11.811,"end":[1414.989,1381.627],"kind":"connector","length":53.78,"nearestCanonicalAngle":45.0,"start":[1369.982,1352.188],"stationID":"940GZZLUPAC","stationName":"Paddington"}`

#### `connector-angle-review` - 940GZZLUPAC primitive 1

- Category: connectors
- Description: An internal connector is 29.097 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":29.097,"deviationDegrees":15.903,"end":[1459.978,1406.664],"kind":"connector","length":51.487,"nearestCanonicalAngle":45.0,"start":[1414.989,1381.627],"stationID":"940GZZLUPAC","stationName":"Paddington"}`

#### `connector-angle-review` - 940GZZLUSTD primitive 0

- Category: connectors
- Description: An internal connector is 55.232 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":55.232,"deviationDegrees":10.232,"end":[3229.031,1269.836],"kind":"connector","length":30.83,"nearestCanonicalAngle":45.0,"start":[3211.45,1244.51],"stationID":"940GZZLUSTD","stationName":"Stratford"}`

#### `connector-angle-review` - 940GZZLUTCR primitive 0

- Category: connectors
- Description: An internal connector is 51.943 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":51.943,"deviationDegrees":6.943,"end":[1966.983,1561.804],"kind":"connector","length":38.786,"nearestCanonicalAngle":45.0,"start":[1943.074,1592.344],"stationID":"940GZZLUTCR","stationName":"Tottenham Court Road"}`

#### `connector-angle-review` - 940GZZLUTWH primitive 0

- Category: connectors
- Description: An internal connector is 77.253 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":77.253,"deviationDegrees":12.747,"end":[2528.968,1687.438],"kind":"connector","length":4.677,"nearestCanonicalAngle":90.0,"start":[2530.0,1692.0],"stationID":"940GZZLUTWH","stationName":"Tower Hill"}`

#### `connector-angle-review` - 940GZZLUTWH primitive 1

- Category: connectors
- Description: An internal connector is 61.766 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":61.766,"deviationDegrees":16.766,"end":[2532.005,1695.734],"kind":"connector","length":4.238,"nearestCanonicalAngle":45.0,"start":[2530.0,1692.0],"stationID":"940GZZLUTWH","stationName":"Tower Hill"}`

#### `connector-angle-review` - 940GZZLUVIC primitive 0

- Category: connectors
- Description: An internal connector is 52.056 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":52.056,"deviationDegrees":7.056,"end":[1729.02,1844.839],"kind":"connector","length":30.492,"nearestCanonicalAngle":45.0,"start":[1710.271,1868.885],"stationID":"940GZZLUVIC","stationName":"Victoria"}`

#### `connector-angle-review` - 940GZZLUWHM primitive 0

- Category: connectors
- Description: An internal connector is 28.137 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":28.137,"deviationDegrees":16.863,"end":[3280.781,1545.945],"kind":"connector","length":58.66,"nearestCanonicalAngle":45.0,"start":[3229.053,1518.282],"stationID":"940GZZLUWHM","stationName":"West Ham"}`

#### `connector-angle-review` - 940GZZLUWPL primitive 0

- Category: connectors
- Description: An internal connector is 43.644 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":43.644,"deviationDegrees":1.356,"end":[2735.05,1516.281],"kind":"connector","length":41.611,"nearestCanonicalAngle":45.0,"start":[2704.938,1545.0],"stationID":"940GZZLUWPL","stationName":"Whitechapel"}`

#### `connector-angle-review` - 940GZZLUWSM primitive 1

- Category: connectors
- Description: An internal connector is 86.949 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":86.949,"deviationDegrees":3.051,"end":[1873.785,1873.034],"kind":"connector","length":4.04,"nearestCanonicalAngle":90.0,"start":[1874.0,1869.0],"stationID":"940GZZLUWSM","stationName":"Westminster"}`

#### `connector-angle-review` - 940GZZLUWSM primitive 2

- Category: connectors
- Description: An internal connector is 47.343 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":47.343,"deviationDegrees":2.343,"end":[1885.992,1855.985],"kind":"connector","length":17.697,"nearestCanonicalAngle":45.0,"start":[1874.0,1869.0],"stationID":"940GZZLUWSM","stationName":"Westminster"}`

#### `connector-angle-review` - 940GZZLUWYP primitive 0

- Category: connectors
- Description: An internal connector is 7.389 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":7.389,"deviationDegrees":7.389,"end":[1238.166,944.182],"kind":"connector","length":44.269,"nearestCanonicalAngle":0.0,"start":[1282.067,949.875],"stationID":"940GZZLUWYP","stationName":"Wembley Park"}`

#### `roundel-not-on-route-port` - 940GZZDLCGT primitive 1

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[3289.016,1726.297],"nearestDistance":47.229,"nearestEndpoint":{"lineID":"dlr","segmentID":"dlr:940GZZDLCGT:940GZZDLEIN","side":"to","stationID":"940GZZDLCGT"},"stationID":"940GZZDLCGT"}`

#### `roundel-not-on-route-port` - 940GZZLUEMB primitive 1

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1966.578,1843.876],"nearestDistance":24.0,"nearestEndpoint":{"lineID":"northern","segmentID":"northern:940GZZLUCHX:940GZZLUEMB","side":"to","stationID":"940GZZLUEMB"},"stationID":"940GZZLUEMB"}`

#### `roundel-not-on-route-port` - 940GZZLUERC primitive 1

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1522.017,1381.628],"nearestDistance":20.919,"nearestEndpoint":{"lineID":"district","segmentID":"district:940GZZLUERC:940GZZLUPAC","side":"to","stationID":"940GZZLUERC"},"stationID":"940GZZLUERC"}`

#### `roundel-not-on-route-port` - 940GZZLUHSC primitive 2

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1168.656,1789.903],"nearestDistance":10.166,"nearestEndpoint":{"lineID":"hammersmith-city","segmentID":"hammersmith-city:940GZZLUGHK:940GZZLUHSC","side":"from","stationID":"940GZZLUHSC"},"stationID":"940GZZLUHSC"}`

#### `roundel-not-on-route-port` - 940GZZLUKNG primitive 2

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1976.0,2257.0],"nearestDistance":34.351,"nearestEndpoint":{"lineID":"northern","segmentID":"northern:940GZZLUKNG:940GZZLUOVL","side":"from","stationID":"940GZZLUKNG"},"stationID":"940GZZLUKNG"}`

#### `roundel-not-on-route-port` - 940GZZLUMGT primitive 1

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[2330.929,1549.438],"nearestDistance":23.763,"nearestEndpoint":{"lineID":"northern","segmentID":"northern:940GZZLUBNK:940GZZLUMGT","side":"from","stationID":"940GZZLUMGT"},"stationID":"940GZZLUMGT"}`

#### `roundel-not-on-route-port` - 940GZZLUMGT primitive 2

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[2354.687,1521.438],"nearestDistance":19.828,"nearestEndpoint":{"lineID":"hammersmith-city","segmentID":"hammersmith-city:940GZZLUBBN:940GZZLUMGT","side":"to","stationID":"940GZZLUMGT"},"stationID":"940GZZLUMGT"}`

#### `roundel-not-on-route-port` - 940GZZLUSTD primitive 1

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[3211.45,1244.51],"nearestDistance":12.115,"nearestEndpoint":{"lineID":"central","segmentID":"central:940GZZLUMED:940GZZLUSTD","side":"to","stationID":"940GZZLUSTD"},"stationID":"940GZZLUSTD"}`

#### `roundel-not-on-route-port` - 940GZZLUVIC primitive 1

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1710.271,1868.885],"nearestDistance":18.749,"nearestEndpoint":{"lineID":"victoria","segmentID":"victoria:940GZZLUPCO:940GZZLUVIC","side":"to","stationID":"940GZZLUVIC"},"stationID":"940GZZLUVIC"}`

#### `roundel-not-on-route-port` - 940GZZLUVIC primitive 2

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1729.02,1844.839],"nearestDistance":19.923,"nearestEndpoint":{"lineID":"circle","segmentID":"circle:940GZZLUSJP:940GZZLUVIC","side":"from","stationID":"940GZZLUVIC"},"stationID":"940GZZLUVIC"}`

#### `non-canonical-straight-runs` - central

- Category: routes
- Description: 3 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":47.857,"commandIndex":1,"deviationDegrees":2.857,"length":67.741,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.central.east-connector.v1.4","segmentID":"central:940GZZLUBLG:940GZZLULVT"},{"angleDegrees":30.018,"commandIndex":1,"deviationDegrees":14.982,"length":100.71,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.central.east-connector.v1.3","segmentID":"central:940GZZLUBNK:940GZZLULVT"},{"angleDegrees":79.295,"commandIndex":3,"deviationDegrees":10.705,"length":40.215,"nearestCanonicalAngle":90.0,"pathID":"beck.v1.path.central.east-connector.v1.2","segmentID":"central:940GZZLUBNK:940GZZLUSPU"}],"count":3,"lineID":"central","maximumDeviationDegrees":14.982}`

#### `non-canonical-straight-runs` - circle

- Category: routes
- Description: 4 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":36.777,"commandIndex":1,"deviationDegrees":8.223,"length":116.884,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.circle.shared-central.full.v1.6","segmentID":"circle:940GZZLUBBN:940GZZLUFCN"},{"angleDegrees":3.204,"commandIndex":3,"deviationDegrees":3.204,"length":81.628,"nearestCanonicalAngle":0.0,"pathID":"beck.v1.path.circle.east-connector.v1.0","segmentID":"circle:940GZZLUCST:940GZZLUMMT"},{"angleDegrees":36.777,"commandIndex":1,"deviationDegrees":8.223,"length":112.713,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.circle.shared-central.full.v1.5","segmentID":"circle:940GZZLUFCN:940GZZLUKSX"},{"angleDegrees":1.95,"commandIndex":1,"deviationDegrees":1.95,"length":134.046,"nearestCanonicalAngle":0.0,"pathID":"beck.v1.path.circle.east-connector.v1.1","segmentID":"circle:940GZZLUMMT:940GZZLUTWH"}],"count":4,"lineID":"circle","maximumDeviationDegrees":8.223}`

#### `non-canonical-straight-runs` - district

- Category: routes
- Description: 2 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":2.633,"commandIndex":3,"deviationDegrees":2.633,"length":81.617,"nearestCanonicalAngle":0.0,"pathID":"beck.v1.path.district.east-connector.v1.0","segmentID":"district:940GZZLUCST:940GZZLUMMT"},{"angleDegrees":1.753,"commandIndex":1,"deviationDegrees":1.753,"length":120.556,"nearestCanonicalAngle":0.0,"pathID":"beck.v1.path.district.east-connector.v1.1","segmentID":"district:940GZZLUMMT:940GZZLUTWH"}],"count":2,"lineID":"district","maximumDeviationDegrees":2.633}`

#### `non-canonical-straight-runs` - elizabeth

- Category: routes
- Description: 3 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":42.021,"commandIndex":1,"deviationDegrees":2.979,"length":120.011,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.elizabeth.stratford-liverpool-mainline.official.v1.0","segmentID":"elizabeth:910GLIVST:910GSTFD"},{"angleDegrees":49.05,"commandIndex":1,"deviationDegrees":4.05,"length":88.554,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.elizabeth.shenfield-stratford.official.v1.11","segmentID":"elizabeth:910GMRYLAND:910GSTFD"},{"angleDegrees":42.021,"commandIndex":1,"deviationDegrees":2.979,"length":120.011,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.elizabeth.stratford-whitechapel.official.v1.0","segmentID":"elizabeth:910GSTFD:910GWCHAPXR"}],"count":3,"lineID":"elizabeth","maximumDeviationDegrees":4.05}`

#### `non-canonical-straight-runs` - hammersmith-city

- Category: routes
- Description: 2 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":36.775,"commandIndex":1,"deviationDegrees":8.225,"length":116.892,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.hammersmith-city.shared-central.full.v1.6","segmentID":"hammersmith-city:940GZZLUBBN:940GZZLUFCN"},{"angleDegrees":36.775,"commandIndex":1,"deviationDegrees":8.225,"length":112.717,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.hammersmith-city.shared-central.full.v1.5","segmentID":"hammersmith-city:940GZZLUFCN:940GZZLUKSX"}],"count":2,"lineID":"hammersmith-city","maximumDeviationDegrees":8.225}`

#### `non-canonical-straight-runs` - jubilee

- Category: routes
- Description: 2 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":50.792,"commandIndex":1,"deviationDegrees":5.792,"length":63.24,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.jubilee.northwest-connector.v1.9","segmentID":"jubilee:940GZZLUFYR:940GZZLUWHP"},{"angleDegrees":38.715,"commandIndex":1,"deviationDegrees":6.285,"length":57.948,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.jubilee.northwest-connector.v1.8","segmentID":"jubilee:940GZZLUKBN:940GZZLUWHP"}],"count":2,"lineID":"jubilee","maximumDeviationDegrees":6.285}`

#### `non-canonical-straight-runs` - metropolitan

- Category: routes
- Description: 4 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":36.789,"commandIndex":1,"deviationDegrees":8.211,"length":117.062,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.metropolitan.shared-central.full.v1.4","segmentID":"metropolitan:940GZZLUBBN:940GZZLUFCN"},{"angleDegrees":53.462,"commandIndex":2,"deviationDegrees":8.462,"length":42.291,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.metropolitan.uxbridge-main.northwest-connector.v1.12","segmentID":"metropolitan:940GZZLUBST:940GZZLUFYR"},{"angleDegrees":41.465,"commandIndex":1,"deviationDegrees":3.535,"length":73.79,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.metropolitan.uxbridge-main.northwest-connector.v1.5","segmentID":"metropolitan:940GZZLUEAE:940GZZLURYL"},{"angleDegrees":36.789,"commandIndex":1,"deviationDegrees":8.211,"length":112.644,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.metropolitan.shared-central.full.v1.3","segmentID":"metropolitan:940GZZLUFCN:940GZZLUKSX"}],"count":4,"lineID":"metropolitan","maximumDeviationDegrees":8.462}`

#### `non-canonical-straight-runs` - mildmay

- Category: routes
- Description: 2 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":43.693,"commandIndex":3,"deviationDegrees":1.307,"length":32.955,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.mildmay.stratford-clapham.official.v1.3","segmentID":"mildmay:910GDALSKLD:910GHACKNYC"},{"angleDegrees":43.831,"commandIndex":5,"deviationDegrees":1.169,"length":69.377,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.mildmay.stratford-clapham.official.v1.3","segmentID":"mildmay:910GDALSKLD:910GHACKNYC"}],"count":2,"lineID":"mildmay","maximumDeviationDegrees":1.307}`

#### `non-canonical-straight-runs` - northern

- Category: routes
- Description: 4 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":46.939,"commandIndex":1,"deviationDegrees":1.939,"length":16.844,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.northern.bank.east-connector.v1.0","segmentID":"northern:940GZZLUAGL:940GZZLUKSX"},{"angleDegrees":89.727,"commandIndex":1,"deviationDegrees":0.273,"length":12.597,"nearestCanonicalAngle":90.0,"pathID":"beck.v1.path.northern.high-barnet.north-connector.v1.10","segmentID":"northern:940GZZLUCTN:940GZZLUMTC"},{"angleDegrees":43.177,"commandIndex":8,"deviationDegrees":1.823,"length":17.912,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.northern.bank-join.north-connector.v1.1","segmentID":"northern:940GZZLUEUS:940GZZLUKSX"},{"angleDegrees":89.436,"commandIndex":1,"deviationDegrees":0.564,"length":41.155,"nearestCanonicalAngle":90.0,"pathID":"beck.v1.path.northern.charing-cross.central-core-join.v1.2","segmentID":"northern:940GZZLUGDG:940GZZLUTCR"}],"count":4,"lineID":"northern","maximumDeviationDegrees":1.939}`

#### `non-canonical-straight-runs` - piccadilly

- Category: routes
- Description: 1 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":41.465,"commandIndex":1,"deviationDegrees":3.535,"length":73.788,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.piccadilly.uxbridge.western-fan.v1.5","segmentID":"piccadilly:940GZZLUEAE:940GZZLURYL"}],"count":1,"lineID":"piccadilly","maximumDeviationDegrees":3.535}`

#### `non-canonical-straight-runs` - suffragette

- Category: routes
- Description: 1 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":48.633,"commandIndex":1,"deviationDegrees":3.633,"length":90.233,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.suffragette.gospel-barking-riverside.official.v1.11","segmentID":"suffragette:910GBARKING:910GBARKRIV"}],"count":1,"lineID":"suffragette","maximumDeviationDegrees":3.633}`

#### `non-canonical-straight-runs` - victoria

- Category: routes
- Description: 4 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":0.936,"commandIndex":2,"deviationDegrees":0.936,"length":92.48,"nearestCanonicalAngle":0.0,"pathID":"beck.v1.path.victoria.north-connector.v1.0","segmentID":"victoria:940GZZLUEUS:940GZZLUKSX"},{"angleDegrees":3.414,"commandIndex":1,"deviationDegrees":3.414,"length":25.358,"nearestCanonicalAngle":0.0,"pathID":"beck.v1.path.victoria.north-connector.v1.1","segmentID":"victoria:940GZZLUHAI:940GZZLUKSX"},{"angleDegrees":44.203,"commandIndex":5,"deviationDegrees":0.797,"length":88.994,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.victoria.north-connector.v1.1","segmentID":"victoria:940GZZLUHAI:940GZZLUKSX"},{"angleDegrees":44.483,"commandIndex":7,"deviationDegrees":0.517,"length":22.032,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.victoria.north-connector.v1.1","segmentID":"victoria:940GZZLUHAI:940GZZLUKSX"}],"count":4,"lineID":"victoria","maximumDeviationDegrees":3.414}`

#### `non-canonical-straight-runs` - weaver

- Category: routes
- Description: 1 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":47.077,"commandIndex":3,"deviationDegrees":2.077,"length":40.104,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.weaver.liverpool-chingford.official.v1.4","segmentID":"weaver:910GCLAPTON:910GHAKNYNM"}],"count":1,"lineID":"weaver","maximumDeviationDegrees":2.077}`

#### `non-canonical-straight-runs` - windrush

- Category: routes
- Description: 1 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":26.508,"commandIndex":2,"deviationDegrees":18.492,"length":60.536,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.windrush.surrey-clapham.official.v1.0","segmentID":"windrush:910GPCKHMQD:910GSURREYQ"}],"count":1,"lineID":"windrush","maximumDeviationDegrees":18.492}`

#### `tick-not-perpendicular` - 940GZZLUEAE primitive 0

- Category: ticks
- Description: A station tick is not perpendicular to the local route tangent.
- Impact: The station grammar looks skewed and less like the official TfL artwork.
- Recommendation: Recreate the tick normal from the reviewed local route tangent.
- Evidence: `{"angleDegrees":86.465,"deviationDegrees":3.535,"lineID":"metropolitan","segmentID":"metropolitan:940GZZLUEAE:940GZZLURYL","stationID":"940GZZLUEAE"}`

#### `tick-not-perpendicular` - 940GZZLUEAE primitive 1

- Category: ticks
- Description: A station tick is not perpendicular to the local route tangent.
- Impact: The station grammar looks skewed and less like the official TfL artwork.
- Recommendation: Recreate the tick normal from the reviewed local route tangent.
- Evidence: `{"angleDegrees":86.465,"deviationDegrees":3.535,"lineID":"piccadilly","segmentID":"piccadilly:940GZZLUEAE:940GZZLURSM","stationID":"940GZZLUEAE"}`

#### `tick-not-on-route-port` - 940GZZLUGHK primitive 1

- Category: ticks
- Description: A station tick is not centred on its line's authored endpoint.
- Impact: The station mark can float beside the route or attach to the wrong line.
- Recommendation: Align the route port and tick centre from the same source coordinate.
- Evidence: `{"centre":[1168.656,1731.963],"lineID":"hammersmith-city","nearestDistance":12.082,"stationID":"940GZZLUGHK"}`

#### `tick-not-perpendicular` - 940GZZLUGTR primitive 0

- Category: ticks
- Description: A station tick is not perpendicular to the local route tangent.
- Impact: The station grammar looks skewed and less like the official TfL artwork.
- Recommendation: Recreate the tick normal from the reviewed local route tangent.
- Evidence: `{"angleDegrees":0.0,"deviationDegrees":90.0,"lineID":"circle","segmentID":"circle:940GZZLUGTR:940GZZLUHSK","stationID":"940GZZLUGTR"}`

#### `tick-not-perpendicular` - 940GZZLUGTR primitive 1

- Category: ticks
- Description: A station tick is not perpendicular to the local route tangent.
- Impact: The station grammar looks skewed and less like the official TfL artwork.
- Recommendation: Recreate the tick normal from the reviewed local route tangent.
- Evidence: `{"angleDegrees":0.001,"deviationDegrees":89.999,"lineID":"district","segmentID":"district:940GZZLUGTR:940GZZLUSKS","stationID":"940GZZLUGTR"}`

#### `tick-not-perpendicular` - 940GZZLUMSH primitive 0

- Category: ticks
- Description: A station tick is not perpendicular to the local route tangent.
- Impact: The station grammar looks skewed and less like the official TfL artwork.
- Recommendation: Recreate the tick normal from the reviewed local route tangent.
- Evidence: `{"angleDegrees":0.001,"deviationDegrees":89.999,"lineID":"circle","segmentID":"circle:940GZZLUCST:940GZZLUMSH","stationID":"940GZZLUMSH"}`

#### `tick-not-perpendicular` - 940GZZLUMSH primitive 1

- Category: ticks
- Description: A station tick is not perpendicular to the local route tangent.
- Impact: The station grammar looks skewed and less like the official TfL artwork.
- Recommendation: Recreate the tick normal from the reviewed local route tangent.
- Evidence: `{"angleDegrees":0.003,"deviationDegrees":89.997,"lineID":"district","segmentID":"district:940GZZLUCST:940GZZLUMSH","stationID":"940GZZLUMSH"}`

#### `tick-not-on-route-port` - 940GZZLURYO primitive 0

- Category: ticks
- Description: A station tick is not centred on its line's authored endpoint.
- Impact: The station mark can float beside the route or attach to the wrong line.
- Recommendation: Align the route port and tick centre from the same source coordinate.
- Evidence: `{"centre":[1382.062,1394.063],"lineID":"circle","nearestDistance":29.204,"stationID":"940GZZLURYO"}`

#### `tick-not-on-route-port` - 940GZZLURYO primitive 1

- Category: ticks
- Description: A station tick is not centred on its line's authored endpoint.
- Impact: The station mark can float beside the route or attach to the wrong line.
- Recommendation: Align the route port and tick centre from the same source coordinate.
- Evidence: `{"centre":[1376.281,1388.203],"lineID":"hammersmith-city","nearestDistance":27.885,"stationID":"940GZZLURYO"}`

#### `tick-not-on-route-port` - 940GZZLUSBM primitive 1

- Category: ticks
- Description: A station tick is not centred on its line's authored endpoint.
- Impact: The station mark can float beside the route or attach to the wrong line.
- Recommendation: Align the route port and tick centre from the same source coordinate.
- Evidence: `{"centre":[1168.656,1691.942],"lineID":"hammersmith-city","nearestDistance":12.029,"stationID":"940GZZLUSBM"}`

### Medium (35)

#### `duplicate-connector` - (2390.031, 1486.094) to (2390.031, 1549.447)

- Category: connectors
- Description: The same connector geometry is authored 2 times.
- Impact: Duplicate strokes can darken antialiasing and create unclear ownership across semantic markers.
- Recommendation: Retain one visual primitive and associate the relevant semantic station records with it.
- Evidence: `{"count":2,"end":[2390.031,1549.447],"kind":"connector","start":[2390.031,1486.094]}`

#### `connector-endpoint-without-roundel` - 910GBARKING primitive 0

- Category: connectors
- Description: The connector start does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[3541.992,1549.578],"endpoint":"start","kind":"connector","nearestDistance":4.194,"nearestRoundel":{"primitiveIndex":0,"stationID":"940GZZLUBKG"},"stationID":"910GBARKING"}`

#### `connector-angle-review` - 910GCNNB primitive 0

- Category: connectors
- Description: An internal connector is 89.602 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":89.602,"deviationDegrees":0.398,"end":[2534.278,1205.469],"kind":"connector","length":30.497,"nearestCanonicalAngle":90.0,"start":[2534.49,1174.973],"stationID":"910GCNNB","stationName":"Canonbury"}`

#### `connector-angle-review` - 910GSTFD primitive 0

- Category: connectors
- Description: An internal connector is 0.759 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":0.759,"deviationDegrees":0.759,"end":[3229.031,1269.836],"kind":"connector","length":39.456,"nearestCanonicalAngle":0.0,"start":[3189.578,1269.313],"stationID":"910GSTFD","stationName":"Stratford (London)"}`

#### `connector-endpoint-without-roundel` - 940GZZLUBKF primitive 0

- Category: connectors
- Description: The connector end does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[2178.679,1810.696],"endpoint":"end","kind":"connector","nearestDistance":4.502,"nearestRoundel":{"primitiveIndex":2,"stationID":"940GZZLUBKF"},"stationID":"940GZZLUBKF"}`

#### `connector-endpoint-without-roundel` - 940GZZLUBKF primitive 1

- Category: connectors
- Description: The connector end does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[2182.043,1819.04],"endpoint":"end","kind":"connector","nearestDistance":4.527,"nearestRoundel":{"primitiveIndex":2,"stationID":"940GZZLUBKF"},"stationID":"940GZZLUBKF"}`

#### `connector-angle-review` - 940GZZLUBSC primitive 0

- Category: connectors
- Description: An internal connector is 89.008 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":89.008,"deviationDegrees":0.992,"end":[1240.516,1873.042],"kind":"connector","length":29.858,"nearestCanonicalAngle":90.0,"start":[1239.999,1843.188],"stationID":"940GZZLUBSC","stationName":"Barons Court"}`

#### `connector-endpoint-without-roundel` - 940GZZLUCST primitive 0

- Category: connectors
- Description: The connector end does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[2263.25,1726.124],"endpoint":"end","kind":"connector","nearestDistance":5.181,"nearestRoundel":{"primitiveIndex":2,"stationID":"940GZZLUCST"},"stationID":"940GZZLUCST"}`

#### `connector-endpoint-without-roundel` - 940GZZLUCST primitive 1

- Category: connectors
- Description: The connector end does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[2266.125,1734.966],"endpoint":"end","kind":"connector","nearestDistance":4.122,"nearestRoundel":{"primitiveIndex":2,"stationID":"940GZZLUCST"},"stationID":"940GZZLUCST"}`

#### `connector-angle-review` - 940GZZLUECT primitive 0

- Category: connectors
- Description: An internal connector is 89.351 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":89.351,"deviationDegrees":0.649,"end":[1376.479,1873.041],"kind":"connector","length":29.855,"nearestCanonicalAngle":90.0,"start":[1376.141,1843.188],"stationID":"940GZZLUECT","stationName":"Earl's Court"}`

#### `connector-angle-review` - 940GZZLUFPK primitive 0

- Category: connectors
- Description: An internal connector is 44.508 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":44.508,"deviationDegrees":0.492,"end":[2406.13,1058.002],"kind":"connector","length":18.777,"nearestCanonicalAngle":45.0,"start":[2392.739,1044.839],"stationID":"940GZZLUFPK","stationName":"Finsbury Park"}`

#### `connector-angle-review` - 940GZZLUMED primitive 1

- Category: connectors
- Description: An internal connector is 89.566 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":89.566,"deviationDegrees":0.434,"end":[2909.95,1549.594],"kind":"connector","length":6.594,"nearestCanonicalAngle":90.0,"start":[2910.0,1543.0],"stationID":"940GZZLUMED","stationName":"Mile End"}`

#### `connector-endpoint-without-roundel` - 940GZZLUMED primitive 1

- Category: connectors
- Description: The connector end does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[2909.95,1549.594],"endpoint":"end","kind":"connector","nearestDistance":6.594,"nearestRoundel":{"primitiveIndex":2,"stationID":"940GZZLUMED"},"stationID":"940GZZLUMED"}`

#### `connector-endpoint-without-roundel` - 940GZZLUNHG primitive 0

- Category: connectors
- Description: The connector end does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[1410.266,1683.976],"endpoint":"end","kind":"connector","nearestDistance":6.205,"nearestRoundel":{"primitiveIndex":1,"stationID":"940GZZLUNHG"},"stationID":"940GZZLUNHG"}`

#### `connector-angle-review` - 940GZZLUSKS primitive 0

- Category: connectors
- Description: An internal connector is 89.240 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":89.24,"deviationDegrees":0.76,"end":[1523.672,1868.887],"kind":"connector","length":25.725,"nearestCanonicalAngle":90.0,"start":[1524.013,1843.164],"stationID":"940GZZLUSKS","stationName":"South Kensington"}`

#### `connector-angle-review` - 940GZZLUTNG primitive 0

- Category: connectors
- Description: An internal connector is 89.526 degrees rather than horizontal, vertical, or 45 degrees.
- Impact: An unintended angle breaks the official interchange grammar and can make the map look loosely constructed.
- Recommendation: Compare with the locked TfL symbol; align to the reference axis or add a documented authored exception.
- Evidence: `{"angleDegrees":89.526,"deviationDegrees":0.474,"end":[919.595,1873.046],"kind":"connector","length":29.859,"nearestCanonicalAngle":90.0,"start":[919.842,1843.188],"stationID":"940GZZLUTNG","stationName":"Turnham Green"}`

#### `connector-endpoint-without-roundel` - 940GZZLUTWH primitive 0

- Category: connectors
- Description: The connector end does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[2528.968,1687.438],"endpoint":"end","kind":"connector","nearestDistance":4.677,"nearestRoundel":{"primitiveIndex":2,"stationID":"940GZZLUTWH"},"stationID":"940GZZLUTWH"}`

#### `connector-endpoint-without-roundel` - 940GZZLUTWH primitive 1

- Category: connectors
- Description: The connector end does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[2532.005,1695.734],"endpoint":"end","kind":"connector","nearestDistance":4.238,"nearestRoundel":{"primitiveIndex":2,"stationID":"940GZZLUTWH"},"stationID":"940GZZLUTWH"}`

#### `connector-endpoint-without-roundel` - 940GZZLUWSM primitive 0

- Category: connectors
- Description: The connector end does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[1874.002,1864.734],"endpoint":"end","kind":"connector","nearestDistance":4.266,"nearestRoundel":{"primitiveIndex":3,"stationID":"940GZZLUWSM"},"stationID":"940GZZLUWSM"}`

#### `connector-endpoint-without-roundel` - 940GZZLUWSM primitive 1

- Category: connectors
- Description: The connector end does not meet a roundel centre.
- Impact: The bar may visibly miss its interchange node or terminate without a station symbol.
- Recommendation: Move the endpoint and corresponding roundel together using the official source coordinate.
- Evidence: `{"coordinate":[1873.785,1873.034],"endpoint":"end","kind":"connector","nearestDistance":4.04,"nearestRoundel":{"primitiveIndex":3,"stationID":"940GZZLUWSM"},"stationID":"940GZZLUWSM"}`

#### `roundel-not-on-route-port` - 940GZZLUBKF primitive 2

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[2180.0,1815.0],"nearestDistance":4.502,"nearestEndpoint":{"lineID":"circle","segmentID":"circle:940GZZLUBKF:940GZZLUMSH","side":"from","stationID":"940GZZLUBKF"},"stationID":"940GZZLUBKF"}`

#### `roundel-not-on-route-port` - 940GZZLUBKG primitive 0

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[3541.488,1545.414],"nearestDistance":4.194,"nearestEndpoint":{"lineID":"hammersmith-city","segmentID":"hammersmith-city:940GZZLUBKG:940GZZLUEHM","side":"to","stationID":"940GZZLUBKG"},"stationID":"940GZZLUBKG"}`

#### `roundel-not-on-route-port` - 940GZZLUCST primitive 2

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[2265.0,1731.0],"nearestDistance":4.122,"nearestEndpoint":{"lineID":"district","segmentID":"district:940GZZLUCST:940GZZLUMSH","side":"to","stationID":"940GZZLUCST"},"stationID":"940GZZLUCST"}`

#### `roundel-not-on-route-port` - 940GZZLUERC primitive 2

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1522.017,1406.664],"nearestDistance":4.117,"nearestEndpoint":{"lineID":"district","segmentID":"district:940GZZLUERC:940GZZLUPAC","side":"to","stationID":"940GZZLUERC"},"stationID":"940GZZLUERC"}`

#### `roundel-not-on-route-port` - 940GZZLUMED primitive 2

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[2910.0,1543.0],"nearestDistance":1.74,"nearestEndpoint":{"lineID":"hammersmith-city","segmentID":"hammersmith-city:940GZZLUBWR:940GZZLUMED","side":"from","stationID":"940GZZLUMED"},"stationID":"940GZZLUMED"}`

#### `roundel-not-on-route-port` - 940GZZLUOXC primitive 0

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1800.0,1594.0],"nearestDistance":1.375,"nearestEndpoint":{"lineID":"bakerloo","segmentID":"bakerloo:940GZZLUOXC:940GZZLURGP","side":"to","stationID":"940GZZLUOXC"},"stationID":"940GZZLUOXC"}`

#### `roundel-not-on-route-port` - 940GZZLUPAC primitive 3

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1459.978,1406.664],"nearestDistance":4.117,"nearestEndpoint":{"lineID":"circle","segmentID":"circle:940GZZLUBWT:940GZZLUPAC","side":"to","stationID":"940GZZLUPAC"},"stationID":"940GZZLUPAC"}`

#### `roundel-not-on-route-port` - 940GZZLUPAH primitive 0

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1414.989,1381.627],"nearestDistance":6.434,"nearestEndpoint":{"lineID":"circle","segmentID":"circle:940GZZLUPAH:940GZZLURYO","side":"from","stationID":"940GZZLURYO"},"stationID":"940GZZLUPAH"}`

#### `roundel-not-on-route-port` - 940GZZLURYL primitive 0

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[660.125,862.149],"nearestDistance":4.55,"nearestEndpoint":{"lineID":"piccadilly","segmentID":"piccadilly:940GZZLUEAE:940GZZLURYL","side":"to","stationID":"940GZZLURYL"},"stationID":"940GZZLURYL"}`

#### `roundel-not-on-route-port` - 940GZZLUSKS primitive 2

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1523.672,1868.887],"nearestDistance":4.157,"nearestEndpoint":{"lineID":"district","segmentID":"district:940GZZLUGTR:940GZZLUSKS","side":"to","stationID":"940GZZLUSKS"},"stationID":"940GZZLUSKS"}`

#### `roundel-not-on-route-port` - 940GZZLUTWH primitive 2

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[2530.0,1692.0],"nearestDistance":4.238,"nearestEndpoint":{"lineID":"district","segmentID":"district:940GZZLUADE:940GZZLUTWH","side":"from","stationID":"940GZZLUTWH"},"stationID":"940GZZLUTWH"}`

#### `roundel-not-on-route-port` - 940GZZLUWLA primitive 0

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1172.758,1644.957],"nearestDistance":6.454,"nearestEndpoint":{"lineID":"circle","segmentID":"circle:940GZZLULRD:940GZZLUWLA","side":"from","stationID":"940GZZLUWLA"},"stationID":"940GZZLUWLA"}`

#### `roundel-not-on-route-port` - 940GZZLUWSM primitive 3

- Category: roundels
- Description: A roundel centre is not attached to any authored route endpoint.
- Impact: The symbol can appear visually detached or imply the wrong interchange relationship.
- Recommendation: Compare the centre with the official station artwork and move the corresponding route port and glyph together.
- Evidence: `{"centre":[1874.0,1869.0],"nearestDistance":4.04,"nearestEndpoint":{"lineID":"district","segmentID":"district:940GZZLUEMB:940GZZLUWSM","side":"from","stationID":"940GZZLUWSM"},"stationID":"940GZZLUWSM"}`

#### `non-canonical-straight-runs` - dlr

- Category: routes
- Description: 2 straight route command(s) deviate from horizontal, vertical, or 45 degrees.
- Impact: Unreviewed angles weaken the TfL map's geometric rhythm and may expose slice-seam drift.
- Recommendation: Compare each command with the locked artwork; correct only mismatches and allowlist authored exceptions.
- Evidence: `{"candidates":[{"angleDegrees":44.6,"commandIndex":1,"deviationDegrees":0.4,"length":132.724,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.dlr.stratford-lewisham.official.v1.1","segmentID":"dlr:940GZZDLBOW:940GZZDLPUD"},{"angleDegrees":44.6,"commandIndex":1,"deviationDegrees":0.4,"length":172.388,"nearestCanonicalAngle":45.0,"pathID":"beck.v1.path.dlr.stratford-lewisham.official.v1.0","segmentID":"dlr:940GZZDLPUD:940GZZDLSTD"}],"count":2,"lineID":"dlr","maximumDeviationDegrees":0.4}`

#### `unverified-line-colour-profile` - TubeLine.swift

- Category: styles
- Description: The audit manifest does not yet contain colour-profile-corrected values extracted from the locked vector source.
- Impact: Even geometrically accurate lines may render with visibly incorrect TfL colours.
- Recommendation: Extract source colours through the PDF's intended ICC profile, then pin perceptual tolerances per line.
- Evidence: `{"status":"pending source-profile extraction"}`

### Low (0)

No findings.

### Info (0)

No findings.

## Patterns and systemic issues

- Geometry correctness is strongly covered for selected showcase interchanges, but not yet for every primitive.
- Marker dimensions are consistent, while their fidelity to the official source still needs source-layer measurement.
- Route and connector angle exceptions are implicit; they need explicit, reviewable provenance.
- Colour and local crossing order are not yet pinned by the audit manifest.

## Positive findings

- All 619 authored segments retain stable semantic IDs.
- The document includes 509 marker records and 620 immutable paths.
- The official PDF and raster are checksum-pinned, protecting the comparison from silent source changes.
- Structural findings identify exact station, segment, path, and primitive locations.

## Recommendations by priority

1. Immediate: resolve critical source/topology failures, if any.
2. Short-term: visually adjudicate high-severity connector, roundel, tick, and route candidates.
3. Medium-term: implement confirmed geometry corrections in a new versioned artwork asset.
4. Long-term: add colour-managed pixel masks and local crossing-order regression tests.

## Reproduction

Run `python3 Tools/BeckMapBuilder/audit_map_fidelity.py --help` from the `ios` directory.
