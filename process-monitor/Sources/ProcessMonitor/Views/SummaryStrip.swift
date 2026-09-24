import MonitorCore
import SwiftUI

/// CPU, Memory and GPU at a glance. Clicking a tile switches to its tab.
struct SummaryStrip: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        let totals = store.snapshot?.totals
        HStack(spacing: 12) {
            SummaryTile(
                metric: .cpu,
                value: Format.percent(totals?.cpuPercent),
                detail: totals.map { "\($0.logicalCPUs) cores" } ?? " ",
                history: store.history.cpu.elements,
                tint: .blue)
            SummaryTile(
                metric: .memory,
                value: memoryText(totals?.memory),
                detail: pressureText(totals?.memory?.pressure),
                history: store.history.memory.elements,
                tint: pressureColor(totals?.memory?.pressure))
            SummaryTile(
                metric: .gpu,
                value: Format.percent(totals?.gpuPercent),
                detail: "All apps",
                history: store.history.gpu.elements,
                tint: .purple)
        }
    }

    private func memoryText(_ memory: MemoryReading?) -> String {
        guard let memory else { return Format.missing }
        return Format.memoryUsage(used: memory.usedBytes, total: memory.totalBytes)
    }

    private func pressureText(_ pressure: MemoryPressure?) -> String {
        switch pressure {
        case .normal?: "Pressure normal"
        case .warning?: "Pressure high"
        case .critical?: "Pressure critical"
        case .unknown?, nil: " "
        }
    }

    private func pressureColor(_ pressure: MemoryPressure?) -> Color {
        switch pressure {
        case .warning?: .orange
        case .critical?: .red
        default: .green
        }
    }
}

private struct SummaryTile: View {
    @Environment(MonitorStore.self) private var store
    let metric: Metric
    let value: String
    let detail: String
    let history: [Double]
    let tint: Color

    var body: some View {
        let selected = store.options.metric == metric
        Button {
            store.options.metric = metric
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Sparkline(values: history, tint: tint)
                    .frame(width: 72, height: 30)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? tint.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? tint.opacity(0.55) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("Sort by \(metric.title)")
    }
}

/// A tiny line chart of the last minute, 0–100%.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                area(in: size).fill(tint.opacity(0.15))
                line(in: size).stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let clamped = min(max(value, 0), 100)
            return CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(clamped / 100)))
        }
    }

    private func line(in size: CGSize) -> Path {
        Path { path in
            let points = points(in: size)
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
    }

    private func area(in size: CGSize) -> Path {
        Path { path in
            let points = points(in: size)
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: size.height))
            for point in points { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }
}
