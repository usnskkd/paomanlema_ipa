import SwiftUI

/// Single direction speed card (Download or Upload) styled to match the PaoManLeMa screenshot.
struct SpeedChartCard: View {
    let title: String
    let trafficTitle: String
    let metrics: DirectionMetrics
    let lineColor: Color
    let fillColor: Color
    let badgeColor: Color

    private let maxVisibleSlots = 90 // 45s at 2 Hz

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            chartSection
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.918, green: 0.925, blue: 0.945))
        )
    }

    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Color(red: 0.11, green: 0.12, blue: 0.15))

                if metrics.isRunning {
                    Text(SpeedFormatter.formatLiveBadge(metrics.currentMbps))
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                        .foregroundColor(badgeColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Text("--")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(badgeColor)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text("平均 \(SpeedFormatter.formatMbps(metrics.averageMbps))")
                    .font(.system(size: 14.5, weight: .regular).monospacedDigit())
                    .foregroundColor(Color(red: 0.25, green: 0.27, blue: 0.31))

                Text(primaryMetricText)
                    .font(.system(size: 21, weight: .bold).monospacedDigit())
                    .foregroundColor(Color(red: 0.10, green: 0.11, blue: 0.14))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("\(trafficTitle) \(SpeedFormatter.formatBytes(metrics.totalBytes))")
                    .font(.system(size: 14.5, weight: .regular).monospacedDigit())
                    .foregroundColor(Color(red: 0.25, green: 0.27, blue: 0.31))
            }
        }
    }

    private var primaryMetricText: String {
        if metrics.isRunning {
            return "实时 \(SpeedFormatter.formatMbps(metrics.currentMbps))"
        }
        return "最终 \(SpeedFormatter.formatMbps(metrics.finalMbps))"
    }

    private var chartSection: some View {
        let maxY = metrics.yAxisMaxMbps
        let midY = maxY / 2.0

        return VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // Y-axis scale labels
                VStack(alignment: .leading) {
                    Text(SpeedFormatter.formatAxisValue(maxY))
                    Spacer()
                    Text(SpeedFormatter.formatAxisValue(midY))
                    Spacer()
                    Text("0K")
                }
                .font(.system(size: 12, weight: .regular).monospacedDigit())
                .foregroundColor(Color(red: 0.26, green: 0.28, blue: 0.32))
                .frame(width: 46, height: 92, alignment: .leading)

                // Real-time rolling line chart
                ZStack(alignment: .topTrailing) {
                    Canvas { context, size in
                        drawChart(in: &context, size: size, maxY: maxY)
                    }
                    .frame(height: 92)
                    .background(Color(red: 0.875, green: 0.892, blue: 0.925))
                    .clipped()

                    if metrics.averageMbps > 0.01 {
                        let ratio = min(max(metrics.averageMbps / maxY, 0.05), 0.95)
                        let lineY = 92.0 * (1.0 - ratio)
                        let labelY = lineY > 64 ? max(4, lineY - 20) : min(72, lineY + 4)

                        Text(SpeedFormatter.formatShortM(metrics.averageMbps))
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundColor(Color(red: 0.82, green: 0.26, blue: 0.26))
                            .padding(.trailing, 5)
                            .offset(y: labelY)
                    }
                }
            }

            // X-axis time labels
            HStack {
                Spacer().frame(width: 56)
                HStack {
                    Spacer()
                    Text("-30秒")
                    Spacer()
                    Spacer()
                    Text("-15秒")
                    Spacer()
                    Spacer()
                    Text("现在")
                }
                .font(.system(size: 12.5, weight: .regular))
                .foregroundColor(Color(red: 0.26, green: 0.28, blue: 0.32))
            }
        }
    }

    private func drawChart(in context: inout GraphicsContext, size: CGSize, maxY: Double) {
        let width = size.width
        let height = size.height
        guard width > 1, height > 1, maxY > 0 else { return }

        let samples = metrics.samples
        if !samples.isEmpty {
            let count = samples.count
            let totalSlots = max(maxVisibleSlots - 1, 1)
            let startSlot = max(0, maxVisibleSlots - count)

            var linePath = Path()
            var fillPath = Path()

            for (index, sample) in samples.enumerated() {
                let slot = startSlot + index
                let x = width * CGFloat(slot) / CGFloat(totalSlots)
                let normalized = min(max(sample.mbps / maxY, 0), 1)
                let y = height * CGFloat(1.0 - normalized)

                if index == 0 {
                    linePath.move(to: CGPoint(x: x, y: y))
                    fillPath.move(to: CGPoint(x: x, y: height))
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                } else {
                    linePath.addLine(to: CGPoint(x: x, y: y))
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                }

                if index == count - 1 {
                    fillPath.addLine(to: CGPoint(x: x, y: height))
                    fillPath.closeSubpath()
                }
            }

            // If only 1 sample exists, draw a short horizontal segment so it is visible immediately
            if count == 1, let only = samples.first {
                let normalized = min(max(only.mbps / maxY, 0), 1)
                let y = height * CGFloat(1.0 - normalized)
                linePath.move(to: CGPoint(x: max(0, width - 6), y: y))
                linePath.addLine(to: CGPoint(x: width, y: y))
            }

            context.fill(fillPath, with: .color(fillColor))
            context.stroke(
                linePath,
                with: .color(lineColor),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )
        }

        // Red average reference line across plot width
        if metrics.averageMbps > 0.01 {
            let avgRatio = min(max(metrics.averageMbps / maxY, 0), 1)
            let avgY = height * CGFloat(1.0 - avgRatio)
            var avgPath = Path()
            avgPath.move(to: CGPoint(x: 0, y: avgY))
            avgPath.addLine(to: CGPoint(x: width, y: avgY))
            context.stroke(
                avgPath,
                with: .color(Color(red: 0.85, green: 0.28, blue: 0.28).opacity(0.85)),
                lineWidth: 1.1
            )
        }
    }
}
