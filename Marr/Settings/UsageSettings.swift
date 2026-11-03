import AppKit
import Carbon
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

struct CompactUsageSettingsPanel: View {
    @ObservedObject var usageStore: TokenUsageStore
    @ObservedObject var historyStore: ConversationHistoryStore

    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        // One aggregation per render, shared by every cell and month label.
        let totals = dailyTotals
        let peakDailyTokens = totals.values.max() ?? 0
        let streaks = streaks(totals: totals)
        let dailyBuckets = dailyBuckets(totals: totals)
        let monthMarkers = monthMarkers(buckets: dailyBuckets)
        VStack(alignment: .leading, spacing: MarrSettingsLayout.sectionSpacing) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                    Text("Recorded tokens")
                        .marrTextStyle(.secondary, weight: .medium)
                        .foregroundStyle(.secondary)
                    Text(compactTokenCount(totalTokens))
                        .marrTextStyle(.hero)
                        .monospacedDigit()
                    Text("From local API usage records")
                        .marrTextStyle(.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                MarrIcon("chart.bar", size: MarrUI.Icon.hero)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: MarrUI.Spacing.large) {
                CompactUsageMetric(value: compactTokenCount(peakDailyTokens), title: "Peak Day")
                CompactUsageMetric(value: durationLabel(longestConversationDuration), title: "Longest Chat")
                CompactUsageMetric(value: "\(streaks.current) days", title: "Current Streak")
                CompactUsageMetric(value: "\(streaks.longest) days", title: "Longest Streak")
            }

            CompactSettingsGroup("Daily activity") {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: MarrUI.Spacing.regular) {
                            LazyHGrid(
                                rows: Array(repeating: GridItem(.fixed(7), spacing: MarrUI.Spacing.tight), count: 7),
                                spacing: 2
                            ) {
                                ForEach(dailyBuckets) { bucket in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(activityColor(tokens: bucket.tokens, maximum: peakDailyTokens))
                                        .frame(width: 7, height: 7)
                                        .overlay {
                                            if calendar.isDateInToday(bucket.start) {
                                                RoundedRectangle(cornerRadius: 2)
                                                    .stroke(Color.accentColor, lineWidth: 1)
                                            }
                                        }
                                        .help("\(bucket.label) · \(bucket.tokens.formatted()) tokens")
                                        .id(bucket.id)
                                }
                            }

                            HStack(spacing: MarrUI.Spacing.tight) {
                                ForEach(monthMarkers) { marker in
                                    Color.clear
                                        .frame(width: 7, height: 16)
                                        .overlay(alignment: .leading) {
                                            if let label = marker.label {
                                                Text(label)
                                                    .marrTextStyle(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize()
                                            }
                                        }
                                }
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo(calendar.startOfDay(for: Date()), anchor: .trailing)
                        }
                    }
                }
                HStack(spacing: MarrUI.Spacing.tight) {
                    Text("Less")
                    ForEach(0..<4) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level == 0 ? Color.primary.opacity(0.055) : Color.accentColor.opacity(Double(level) / 3))
                            .frame(width: 7, height: 7)
                    }
                    Text("More")
                }
                .marrTextStyle(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 6)
            }
        }
    }

    private var totalTokens: Int {
        usageStore.events.reduce(0) { $0 + $1.totalTokens }
    }

    private var dailyTotals: [Date: Int] {
        Dictionary(grouping: usageStore.events) { calendar.startOfDay(for: $0.date) }
            .mapValues { $0.reduce(0) { $0 + $1.totalTokens } }
    }

    private var longestConversationDuration: TimeInterval {
        historyStore.conversations.map { max(0, $0.updatedAt.timeIntervalSince($0.createdAt)) }.max() ?? 0
    }

    private func streaks(totals: [Date: Int]) -> (current: Int, longest: Int) {
        let days = totals.keys.sorted()
        guard !days.isEmpty else { return (0, 0) }

        var longest = 1
        var run = 1
        for index in 1..<days.count {
            if calendar.dateComponents([.day], from: days[index - 1], to: days[index]).day == 1 {
                run += 1
                longest = max(longest, run)
            } else {
                run = 1
            }
        }

        let today = calendar.startOfDay(for: Date())
        let gap = calendar.dateComponents([.day], from: days.last ?? today, to: today).day ?? 0
        return (gap <= 1 ? run : 0, longest)
    }

    private func dailyBuckets(totals: [Date: Int]) -> [UsageBucket] {
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let firstDay = calendar.date(byAdding: .weekOfYear, value: -52, to: weekStart) ?? today
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "MMM d, yyyy"

        return (0..<371).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return UsageBucket(
                start: date,
                tokens: date > today ? 0 : (totals[date] ?? 0),
                label: formatter.string(from: date)
            )
        }
    }

    private func monthMarkers(buckets: [UsageBucket]) -> [UsageMonthMarker] {
        let weekStarts = stride(from: 0, to: buckets.count, by: 7).map { buckets[$0].start }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMM")

        return weekStarts.enumerated().map { index, date in
            let previousDate = index > 0 ? weekStarts[index - 1] : nil
            let showsLabel = previousDate == nil
                || calendar.component(.month, from: previousDate!) != calendar.component(.month, from: date)
            return UsageMonthMarker(date: date, label: showsLabel ? formatter.string(from: date) : nil)
        }
    }

    private func activityColor(tokens: Int, maximum: Int) -> Color {
        guard tokens > 0, maximum > 0 else { return .primary.opacity(0.055) }
        let ratio = sqrt(Double(tokens) / Double(maximum))
        return Color.accentColor.opacity(0.25 + ratio * 0.75)
    }

    private func compactTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(of: ".0K", with: "K")
        }
        return value.formatted()
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds >= 3_600 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}

private struct CompactUsageMetric: View {
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: MarrUI.Spacing.tight) {
            Text(value)
                .marrTextStyle(.pageTitle, weight: .semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title)
                .marrTextStyle(.secondary)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
    }
}

private struct UsageMonthMarker: Identifiable {
    let date: Date
    let label: String?
    var id: Date { date }
}

private struct UsageBucket: Identifiable {
    let start: Date
    let tokens: Int
    let label: String
    var id: Date { start }
}
