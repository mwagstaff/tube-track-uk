// TubeTrack UK's display palette from ios/TubeTrackUK/Models/TubeLine.swift,
// rounded to 8-bit sRGB. Keep this catalogue aligned when that palette changes.
const lines = [
    ['bakerloo', 'Bakerloo', 'tube', '#8C4512', '#FFFFFF'],
    ['central', 'Central', 'tube', '#E01F24', '#FFFFFF'],
    ['circle', 'Circle', 'tube', '#FFC70D', '#000000'],
    ['district', 'District', 'tube', '#007D38', '#FFFFFF'],
    ['hammersmith-city', 'Hammersmith & City', 'tube', '#F296B3', '#000000'],
    ['jubilee', 'Jubilee', 'tube', '#7A878C', '#000000'],
    ['metropolitan', 'Metropolitan', 'tube', '#990059', '#FFFFFF'],
    ['northern', 'Northern', 'tube', '#000000', '#FFFFFF'],
    ['piccadilly', 'Piccadilly', 'tube', '#001AA6', '#FFFFFF'],
    ['victoria', 'Victoria', 'tube', '#00A1E0', '#000000'],
    ['waterloo-city', 'Waterloo & City', 'tube', '#75D1BF', '#000000'],
    ['dlr', 'DLR', 'dlr', '#00AFAD', '#000000'],
    ['elizabeth', 'Elizabeth line', 'elizabeth-line', '#60399E', '#FFFFFF'],
    ['tram', 'London Trams', 'tram', '#69C22F', '#000000'],
    ['liberty', 'Liberty line', 'overground', '#4F5D62', '#FFFFFF'],
    ['lioness', 'Lioness line', 'overground', '#F89C0E', '#000000'],
    ['mildmay', 'Mildmay line', 'overground', '#2486CB', '#000000'],
    ['suffragette', 'Suffragette line', 'overground', '#59C364', '#000000'],
    ['weaver', 'Weaver line', 'overground', '#B0237F', '#FFFFFF'],
    ['windrush', 'Windrush line', 'overground', '#ED192E', '#000000']
];

export const LINE_COLOURS = Object.freeze(lines.map(([id, name, mode, colour, textColour]) =>
    Object.freeze({ id, name, mode, colour, textColour })
));
