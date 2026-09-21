import Foundation
import Testing
@testable import TubeTrackCore

struct DeepLinkTests {
    @Test func linksRoundTripThroughURLs() throws {
        let links: [DeepLink] = [
            .status,
            .line(.central),
            .line(.hammersmithCity),
            .station(id: "940GZZLUOXC", line: nil),
            .station(id: "HUBKGX", line: .victoria),
        ]
        for link in links {
            #expect(DeepLink(url: link.url) == link)
        }
    }

    @Test func urlsUseTheExpectedShape() {
        #expect(DeepLink.status.url.absoluteString == "tubetrack://status")
        #expect(DeepLink.line(.waterlooCity).url.absoluteString == "tubetrack://line/waterloo-city")
        #expect(
            DeepLink.station(id: "940GZZLUOXC", line: .central).url.absoluteString
                == "tubetrack://station/940GZZLUOXC?line=central"
        )
    }

    @Test func malformedURLsAreRejected() throws {
        for value in [
            "https://status",
            "tubetrack://line",
            "tubetrack://line/not-a-line",
            "tubetrack://station",
            "tubetrack://status/extra",
            "tubetrack://unknown",
        ] {
            let url = try #require(URL(string: value))
            #expect(DeepLink(url: url) == nil, "\(value)")
        }
        let unknownLine = try #require(URL(string: "tubetrack://station/940GZZLUOXC?line=nope"))
        #expect(DeepLink(url: unknownLine) == .station(id: "940GZZLUOXC", line: nil))
    }
}
