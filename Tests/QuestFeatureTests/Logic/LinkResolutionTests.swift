import Foundation
import Testing

@testable import QuestFeature

@Suite("LinkResolution")
struct LinkResolutionTests {
    private func link(
        _ scheme: LinkScheme, _ identifier: String,
        repo: String? = nil
    ) -> Link {
        Link(scheme: scheme, identifier: identifier, label: "L", repo: repo)
    }

    @Test("an http url opens on the web")
    func webURL() {
        guard case .web(let url) = LinkResolution.route(for: link(.url, "https://example.com"))
        else { return #expect(Bool(false), "expected .web") }
        #expect(url.absoluteString == "https://example.com")
    }

    @Test("a plain http url is accepted too")
    func plainHTTP() {
        guard case .web = LinkResolution.route(for: link(.url, "http://example.com"))
        else { return #expect(Bool(false), "expected .web") }
    }

    @Test("a url identifier that is not http(s) is inert, not handed to the system opener")
    func nonHTTPURLRefused() {
        for identifier in [
            "file:///etc/passwd", "not a url", "ftp://example.com",
            "javascript:alert(1)", "",
        ] {
            guard case .inert(let reason) = LinkResolution.route(for: link(.url, identifier))
            else { return #expect(Bool(false), "expected .inert for \(identifier)") }
            #expect(!reason.isEmpty)
        }
    }

    @Test("a folder with an absolute path opens the folder")
    func folder() {
        guard case .openFolder(let url) = LinkResolution.route(for: link(.folder, "/tmp/x"))
        else { return #expect(Bool(false), "expected .openFolder") }
        #expect(url.path == "/tmp/x")
    }

    @Test("a file with an absolute path is revealed, not launched")
    func file() {
        guard case .reveal(let url) = LinkResolution.route(for: link(.file, "/tmp/x.md"))
        else { return #expect(Bool(false), "expected .reveal") }
        #expect(url.path == "/tmp/x.md")
    }

    @Test("a relative or empty path is inert for both file and folder")
    func relativePathsRefused() {
        for scheme in [LinkScheme.file, .folder] {
            for identifier in ["relative/path", "~/tilde", "", "   "] {
                guard case .inert = LinkResolution.route(for: link(scheme, identifier))
                else { return #expect(Bool(false), "expected .inert for \(scheme) \(identifier)") }
            }
        }
    }

    @Test("git schemes are inert and name Git Mage as their future home")
    func gitSchemesInert() {
        for scheme in [LinkScheme.repo, .branch, .pr, .commit] {
            guard
                case .inert(let reason) = LinkResolution.route(
                    for: link(scheme, "/tmp/repo", repo: "quest"))
            else { return #expect(Bool(false), "expected .inert for \(scheme)") }
            #expect(reason.lowercased().contains("git mage"))
        }
    }

    @Test("an unknown scheme is inert with a reason")
    func unknownInert() {
        guard case .inert(let reason) = LinkResolution.route(for: link(.unknown, "whatever"))
        else { return #expect(Bool(false), "expected .inert") }
        #expect(!reason.isEmpty)
    }

    @Test("every scheme produces a route — no scheme falls through unhandled")
    func totality() {
        for scheme in [LinkScheme.file, .folder, .url, .repo, .branch, .pr, .commit, .unknown] {
            _ = LinkResolution.route(for: link(scheme, "/tmp/x"))
        }
    }
}
