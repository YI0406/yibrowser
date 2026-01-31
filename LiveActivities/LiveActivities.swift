import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
struct DownloadActivityView: View {
  let context: ActivityViewContext<DownloadActivityAttributes>

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(context.attributes.title)
        .font(.headline)
        .lineLimit(1)
      Text(context.state.subtitle)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .lineLimit(1)
      if let progress = context.state.progress {
        ProgressView(value: progress)
      } else {
        ProgressView()
      }
      if context.state.totalCount > 1 {
        Text("\(context.state.activeCount)/\(context.state.totalCount)")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
    .padding(.vertical, 8)
  }
}

@available(iOS 16.1, *)
@main
struct DownloadLiveActivities: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
      DownloadActivityView(context: context)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.attributes.title)
            .font(.caption)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if let progress = context.state.progress {
            Text("\(Int(progress * 100))%")
              .font(.caption)
          } else {
            Text("…")
              .font(.caption)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          if let progress = context.state.progress {
            ProgressView(value: progress)
          } else {
            ProgressView()
          }
        }
      } compactLeading: {
        Text("DL")
      } compactTrailing: {
        if let progress = context.state.progress {
          Text("\(Int(progress * 100))%")
        } else {
          Text("…")
        }
      } minimal: {
        if let progress = context.state.progress {
          Text("\(Int(progress * 100))%")
        } else {
          Text("…")
        }
      }
      .widgetURL(URL(string: "yibrowser://downloads"))
    }
  }
}
