import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
struct DownloadActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    var progress: Double?
    var activeCount: Int
    var totalCount: Int
    var subtitle: String?
  }

  var title: String
  var mode: String
}

@available(iOS 16.1, *)
struct DownloadActivityView: View {
  let context: ActivityViewContext<DownloadActivityAttributes>

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(context.attributes.title)
          .font(.headline)
          .lineLimit(1)
        if let subtitle = context.state.subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
      }
      if let progress = context.state.progress {
        ProgressView(value: progress)
          .tint(accent)
      } else {
        ProgressView()
      }
      HStack(spacing: 8) {
        ActivityPill(text: taskCountText, tint: accent)
        Spacer()
        if let percentText = percentText {
          Text(percentText)
            .font(.caption)
            .monospacedDigit()
        }
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(backgroundColor)
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(accent.opacity(0.18), lineWidth: 1)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(
              colors: [accent.opacity(0.12), .clear],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ))
        )
    )
  }

  private var accent: Color {
    Color("AccentColor")
  }

  private var backgroundColor: Color {
    Color("WidgetBackground").opacity(0.9)
  }

  private var taskCountText: String {
    let active = max(0, context.state.activeCount)
    let total = max(active, context.state.totalCount)
    return "\(active)/\(total)"
  }

  private var percentText: String? {
    guard let value = context.state.progress else { return nil }
    let clamped = min(max(value, 0), 1)
    return "\(Int((clamped * 100).rounded()))%"
  }
}

@available(iOS 16.1, *)
struct DownloadLiveActivities: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
      DownloadActivityView(context: context)
        .activityBackgroundTint(Color("WidgetBackground"))
        .activitySystemActionForegroundColor(.primary)
    } dynamicIsland: { context in
      let activeCount = max(0, context.state.activeCount)
      let totalCount = max(activeCount, context.state.totalCount)
      let taskCountText = "\(activeCount)/\(totalCount)"
      let percentText = context.state.progress.map {
        "\(Int((min(max($0, 0), 1) * 100).rounded()))%"
      }
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          VStack(alignment: .leading, spacing: 2) {
            Text(context.attributes.title)
              .font(.caption)
              .lineLimit(1)
            Text(taskCountText)
              .font(.caption2)
              .foregroundColor(.secondary)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(spacing: 6) {
            if let progress = context.state.progress {
              ProgressView(value: progress)
            } else {
              ProgressView()
            }
            HStack {
              ActivityPill(text: taskCountText, tint: .white)
              Spacer()
              if let percentText = percentText {
                Text(percentText)
                  .font(.caption2)
                  .monospacedDigit()
              }
            }
          }
        }
      } compactLeading: {
        Text("DL")
      } compactTrailing: {
        if let percentText = percentText {
          Text(percentText)
            .font(.caption2)
            .monospacedDigit()
        }
      } minimal: {
        if let percentText = percentText {
          Text(percentText)
            .font(.caption2)
            .monospacedDigit()
        } else {
          Text("…")
            .font(.caption2)
        }
      }
      .widgetURL(URL(string: "yibrowser://downloads"))
      .keylineTint(.white)
    }
  }
}

@available(iOS 16.1, *)
private struct ActivityPill: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text)
      .font(.caption2)
      .monospacedDigit()
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Capsule(style: .continuous)
          .fill(tint.opacity(0.15))
      )
  }
}

@available(iOS 16.1, *)
private struct ActivityProgressRing: View {
  let progress: Double?
  let size: CGFloat
  let lineWidth: CGFloat
  let tint: Color
  let showsText: Bool

  private var clamped: Double {
    min(max(progress ?? 0, 0), 1)
  }

  var body: some View {
    ZStack {
      Circle()
        .stroke(tint.opacity(0.2), lineWidth: lineWidth)
      if progress != nil {
        Circle()
          .trim(from: 0, to: clamped)
          .stroke(
            tint,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
      }
      if showsText {
        if progress != nil {
          Text("\(Int((clamped * 100).rounded()))%")
            .font(.caption2)
            .monospacedDigit()
        } else {
          Image(systemName: "arrow.down.circle.fill")
            .font(.caption2)
            .foregroundColor(tint)
        }
      }
    }
    .frame(width: size, height: size)
  }
}
