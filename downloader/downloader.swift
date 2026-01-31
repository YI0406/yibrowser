//
//  downloader.swift
//  downloader
//
//  Created by 詹子逸 on 2026/1/27.
//

import WidgetKit
import SwiftUI

struct SimpleEntry: TimelineEntry {
    let date: Date
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        let entry = SimpleEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct DownloaderWidgetView: View {
    var body: some View {
        VStack(spacing: 12) {
            Link(destination: URL(string: "yibrowser://downloads")!) {
                Label("下載清單", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)

            Link(destination: URL(string: "yibrowser://media")!) {
                Label("媒體櫃", systemImage: "play.rectangle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct downloader: Widget {
    let kind: String = "downloader"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { _ in
            DownloaderWidgetView()
        }
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    downloader()
} timeline: {
    SimpleEntry(date: .now)
}
