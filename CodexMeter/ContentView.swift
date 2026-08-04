//
//  ContentView.swift
//  CodexMeter
//
//  Created by raycal on 8/5/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var service: CodexUsageService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            if service.isLoading && service.windows.isEmpty {
                loadingView
            } else if let errorMessage = service.errorMessage,
                      service.windows.isEmpty {
                errorView(errorMessage)
            } else {
                usageView
            }

            Divider()

            footer
        }
        .padding(16)
        .frame(width: 340)
        .task {
            service.start()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Meter")
                    .font(.headline)

                Text(service.accountDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                service.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新额度")
            .disabled(service.isLoading)
        }
    }

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取 Codex 额度…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("暂时无法读取额度", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("重试") {
                service.refresh()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
    }

    private var usageView: some View {
        VStack(spacing: 14) {
            ForEach(service.windows) { window in
                UsageWindowRow(window: window)
            }

            if let errorMessage = service.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let lastUpdated = service.lastUpdated {
                Text("更新于 \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("本机 Codex App Server")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

private struct UsageWindowRow: View {
    let window: CodexUsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.name)
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text("剩余 \(window.remainingPercent)%")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(window.tint)
            }

            ProgressView(value: Double(window.remainingPercent), total: 100)
                .tint(window.tint)

            HStack {
                Text("已使用 \(window.usedPercent)%")

                Spacer()

                if let resetsAt = window.resetsAt {
                    Text("重置：\(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
