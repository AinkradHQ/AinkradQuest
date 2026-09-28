import SwiftUI
import AinkradAppKit

/// Quest's **basic** mode: Today, and nothing else.
///
/// Today already exists and is already the surface you want when you open Quest
/// to see what is on — so basic mode is not a new screen, it is that one screen
/// without the shell around it. No `ProjectSidebar`, no `QuestHeader`, no
/// surface switcher, and none of `OverviewSurface` / `ListSurface` /
/// `BoardSurface` / `TimelineSurface` is constructed.
///
/// Opening an item escalates to advanced rather than being refused. Today's
/// `onOpen` navigates to the item's list, and basic has no list — so the honest
/// response is to hand the user the mode that does, not to make the row inert.
struct QuestBasicView: View {
    @Bindable var store: ProjectStore

    @Environment(\.ainkradToastCenter) private var toasts
    @Environment(\.ainkradSetPaneMode) private var setPaneMode

    var body: some View {
        AinkradBasicShell(icon: "checklist", title: "Quest", subtitle: subtitle) {
            TodaySurface(store: store,
                         report: { toasts.show($0, status: $1) },
                         // Escalates AND carries the target. An earlier version
                         // dropped the item: `QuestShell` is rebuilt on the
                         // switch, so `surface` starts `.landing` — you tapped
                         // an item and arrived nowhere near it.
                         onOpen: { item in
                             store.pendingOpenItem = item
                             setPaneMode(.advanced)
                         })
        }
    }

    /// The count is the whole reason to glance at Quest, so it belongs in the
    /// header rather than needing the content to be read first.
    private var subtitle: String {
        let n = store.projects.count
        return n == 1 ? "1 project" : "\(n) projects"
    }
}
