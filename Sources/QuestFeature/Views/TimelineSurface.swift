import AinkradAppKit
import SwiftUI

struct TimelineSurface: View {
    let document: ProjectDocument

    @Environment(\.ainkradTheme) private var theme

    /// Bar height and the vertical gap between lanes. Not literal geometry —
    /// `TimelineLayout` owns lane assignment; these only size the row that
    /// presents each lane, rounded to the `AinkradSpacing` scale.
    private let barHeight = AinkradSpacing.xl
    private let laneHeight = AinkradSpacing.xxl

    private var layout: TimelineLayout.Result {
        TimelineLayout.build(items: document.items)
    }

    var body: some View {
        let result = layout
        return ScrollView {
            VStack(alignment: .leading, spacing: AinkradSpacing.md) {
                AinkradSectionHeader(title: "Timeline")

                if result.bars.isEmpty {
                    AinkradEmptyState(
                        icon: "calendar", title: "Nothing scheduled",
                        message: "Items with due dates appear on the timeline.")
                } else {
                    GeometryReader { geometry in
                        let span = timeSpan(result.bars)
                        ForEach(result.bars) { bar in
                            let x = offset(bar.start, span: span, width: geometry.size.width)
                            let end = offset(bar.end, span: span, width: geometry.size.width)
                            AinkradCard(isSelected: bar.isDerived) {
                                Text(bar.title).lineLimit(1)
                            }
                            .frame(width: max(end - x, 60), height: barHeight, alignment: .leading)
                            .offset(x: x, y: CGFloat(bar.lane) * laneHeight)
                        }
                    }
                    .frame(height: CGFloat((result.bars.map(\.lane).max() ?? 0) + 1) * laneHeight)
                }

                if !result.unscheduled.isEmpty {
                    AinkradSectionHeader(title: "Unscheduled")
                    LazyVStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                        ForEach(result.unscheduled) { item in
                            AinkradCard {
                                Text(item.title)
                            }
                        }
                    }
                }
            }
            .padding(AinkradSpacing.lg)
        }
    }

    private func timeSpan(_ bars: [TimelineBar]) -> (start: Date, end: Date) {
        let start = bars.map(\.start).min() ?? Date()
        let end = bars.map(\.end).max() ?? start.addingTimeInterval(86_400)
        return (start, max(end, start.addingTimeInterval(86_400)))
    }

    private func offset(_ date: Date, span: (start: Date, end: Date), width: CGFloat) -> CGFloat {
        let total = span.end.timeIntervalSince(span.start)
        guard total > 0 else { return 0 }
        return width * CGFloat(date.timeIntervalSince(span.start) / total)
    }
}
