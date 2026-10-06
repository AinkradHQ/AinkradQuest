import Foundation

/// What a link is being attached to. One enum rather than separate project and
/// item APIs, so validation, activity logging and trashed-target refusal cannot
/// drift apart between the two.
enum LinkTarget: Sendable, Equatable, Hashable {
    case project(UUID)
    case item(UUID)
}
