import AutopingCore
import Charts
import SwiftUI

/// Shown when clicking the menu bar item: live status, a latency chart of the last
/// five minutes and the statistics of the old "Statistics" window.
struct PopoverView: View {
    let monitor: ConnectionMonitor
    let preferences: Preferences
    let state: PopoverState
    let actions: StatusItemController.Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusHeader(monitor: monitor)
            MetricsRow(monitor: monitor)
            LatencyChart(samples: monitor.history, threshold: Double(preferences.slowPingThreshold))
                .frame(height: 120)
            StatisticsSection(monitor: monitor, state: state)
            Divider()
            HStack {
                Button("Settings…", action: actions.openSettings)
                Spacer()
                Button(action: actions.showAbout) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help(Text("About \(AppInfo.name)"))
                Button("Quit", action: actions.quit)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 340)
    }
}

// MARK: - Header

private struct StatusHeader: View {
    let monitor: ConnectionMonitor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private var title: LocalizedStringKey {
        if monitor.paused { return "Paused" }
        if monitor.failed { return "Connection down" }
        if monitor.connecting { return "Connecting…" }
        return switch monitor.bars {
        case 5: "Excellent connection"
        case 4: "Good connection"
        case 3: "Fair connection"
        case 2: "Poor connection"
        default: "Bad connection"
        }
    }

    private var subtitle: String {
        if monitor.failed, let problem = monitor.problem { return problem }
        guard let address = monitor.address, address.text != monitor.host else { return monitor.host }
        return "\(monitor.host) (\(address.text))"
    }

    private var color: Color {
        if monitor.failed { return .red }
        if monitor.connecting || monitor.paused { return .gray }
        return switch monitor.bars {
        case 4...: .green
        case 3: .yellow
        default: .orange
        }
    }
}

// MARK: - Metrics

private struct MetricsRow: View {
    let monitor: ConnectionMonitor

    var body: some View {
        HStack(spacing: 10) {
            tile("Latency") {
                Text(monitor.latestPingTime.map(Formatting.milliseconds) ?? "–")
            }
            tile("Packet loss") {
                Text(Formatting.percent(monitor.recentLossPercent))
            }
            tile("Quality") {
                SignalBars(active: monitor.failed || monitor.connecting ? 0 : monitor.bars)
                    .frame(height: 18)
            }
        }
    }

    private func tile(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .font(.title3.monospacedDigit().weight(.semibold))
                .frame(height: 22, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SignalBars: View {
    let active: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<BarsIcon.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < active ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: 5, height: 6 + CGFloat(index) * 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("\(active) of 5 bars"))
    }
}

// MARK: - Chart

private struct LatencyChart: View {
    let samples: [ConnectionMonitor.Sample]
    let threshold: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let end = context.date
            let start = end.addingTimeInterval(-ConnectionMonitor.historyLength)
            let answered = samples.compactMap { sample in sample.milliseconds.map { (sample, $0) } }
            let maximum = answered.map(\.1).max() ?? 0

            Chart {
                ForEach(segments, id: \.sample.id) { entry in
                    if let milliseconds = entry.sample.milliseconds {
                        LineMark(
                            x: .value("Time", entry.sample.date),
                            y: .value("Latency", milliseconds),
                            series: .value("Segment", entry.segment)
                        )
                        .foregroundStyle(.tint)
                        .interpolationMethod(.monotone)
                    } else {
                        RuleMark(x: .value("Time", entry.sample.date))
                            .foregroundStyle(.red.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                RuleMark(y: .value("Slow ping threshold", threshold))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...max(threshold * 1.2, maximum * 1.1, 10))
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute)) { _ in
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let milliseconds = value.as(Double.self) {
                            Text(verbatim: "\(Int(milliseconds))")
                        }
                    }
                }
            }
            .overlay {
                if samples.isEmpty {
                    Text("Waiting for replies…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(Text("Latency over the last five minutes"))
    }

    /// Splits the line at lost pings so a gap shows where replies were missing.
    private var segments: [(sample: ConnectionMonitor.Sample, segment: Int)] {
        var segment = 0
        return samples.map { sample in
            if sample.milliseconds == nil { segment += 1 }
            return (sample, segment)
        }
    }
}

// MARK: - Statistics

/// View state of the popover that has to survive re-renders. (Kept in an observable
/// object instead of `@State`, whose macro needs Xcode and is missing from the
/// Command Line Tools.)
@MainActor @Observable
final class PopoverState {
    enum Scope: Hashable { case session, allTime }

    var scope = Scope.session
    var confirmingReset = false
}

private struct StatisticsSection: View {
    let monitor: ConnectionMonitor
    @Bindable var state: PopoverState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Statistics", selection: $state.scope) {
                Text("Current Session").tag(PopoverState.Scope.session)
                Text("All Time").tag(PopoverState.Scope.allTime)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)

            let stats = state.scope == .session ? monitor.sessionStats : monitor.allTimeStats
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Pings sent", "\(stats.sent)")
                row("Replies lost", "\(stats.lost)")
                row("Packet loss", Formatting.percent(stats.lossPercent, fractionDigits: 2))
                row("Average response", stats.replied > 0 ? Formatting.preciseMilliseconds(stats.averageTime) : "–")
                row("Fastest response", stats.replied > 0 ? Formatting.preciseMilliseconds(stats.fastest) : "–")
                row("Slowest response", stats.replied > 0 ? Formatting.preciseMilliseconds(stats.slowest) : "–")
            }
            .font(.callout)

            HStack {
                Spacer()
                Button(state.scope == .session ? "Reset Session Stats" : "Reset All Time Stats") {
                    if state.scope == .session {
                        monitor.resetSessionStats()
                    } else {
                        state.confirmingReset = true
                    }
                }
                .controlSize(.small)
            }
        }
        .alert("Reset all time statistics for \(monitor.host)?", isPresented: $state.confirmingReset) {
            Button("Reset", role: .destructive) { monitor.resetAllTimeStats() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
