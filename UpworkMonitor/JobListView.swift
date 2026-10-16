import SwiftUI

struct JobListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedJob: UpworkJob?

    var body: some View {
        Group {
            #if os(macOS)
            jobContent
                .navigationTitle(model.selectedFeed.title)
            #else
            VStack(spacing: 0) {
                FeedHeaderView()
                Divider()
                jobContent
            }
            #endif
        }
        .sheet(item: $selectedJob, onDismiss: model.clearNotificationJobToOpen) { job in
            NavigationStack {
                JobDetailView(job: job)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { selectedJob = nil }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 600)
            #else
            .presentationDetents([.large])
            #endif
        }
        .onChange(of: model.notificationJobToOpen) { _, job in
            if let job { selectedJob = job }
        }
        .task {
            if let job = model.notificationJobToOpen {
                selectedJob = job
            }
        }
    }

    @ViewBuilder
    private var jobContent: some View {
        if model.currentJobs.isEmpty {
            EmptyJobsView()
        } else {
            List {
                ForEach(model.currentJobs) { job in
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            selectedJob = job
                        } label: {
                            JobRow(job: job)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                model.copy(job: job)
                            } label: {
                                Label("Copy project and client information", systemImage: "doc.on.doc")
                            }
                            if let url = job.webURL {
                                Link(destination: url) {
                                    Label("Open on Upwork", systemImage: "arrow.up.right.square")
                                }
                            }
                        }

                        Button {
                            model.copy(job: job)
                        } label: {
                            Group {
                                if model.copyingJobID == job.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: model.copiedJobID == job.id ? "checkmark.circle.fill" : "doc.on.doc")
                                        .foregroundStyle(model.copiedJobID == job.id ? .green : .primary)
                                }
                            }
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.copyingJobID != nil)
                        .help("Copy project and client information")
                        .accessibilityLabel("Copy project and client information")
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

struct FeedHeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            #if os(iOS)
            Picker("Feed", selection: $model.selectedFeed) {
                ForEach(FeedKind.allCases) { feed in
                    Text(feed.title).tag(feed)
                }
            }
            .pickerStyle(.segmented)
            #else
            Text(model.selectedFeed.title)
                .font(.title2.weight(.semibold))
            #endif

            Spacer()
            if let date = model.lastUpdated {
                Text(date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

struct EmptyJobsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            if model.isRestoringConnection || model.isLoading {
                ProgressView()
                    .controlSize(.large)
                Text("Loading jobs…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: model.isConnected ? "tray" : "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(model.isConnected ? "No jobs loaded" : "Connect to Upwork in Settings")
                    .font(.headline)
            }
            #if os(iOS)
            if !model.isConnected && !model.isRestoringConnection {
                Text("Connect your Upwork account in Settings to load jobs.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct JobRow: View {
    let job: UpworkJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let date = job.publishedDate {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(job.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                #if os(macOS)
                .lineLimit(2)
                #else
                .lineLimit(3)
                #endif

            HStack(spacing: 12) {
                if let budget = job.budgetLabel {
                    Label(budget, systemImage: "dollarsign.circle")
                }
                if let location = job.client?.location?.displayName, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                }
                if let score = job.client?.totalFeedback {
                    Label(String(format: "%.2f", score), systemImage: "star.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if job.proposalCountDisplay != nil {
                ProposalCountBadge(job: job)
            }

            if !job.skillNames.isEmpty {
                #if os(macOS)
                Text(job.skillNames.prefix(5).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                #else
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(job.skillNames.prefix(6), id: \.self) { skill in
                            Text(skill)
                                .font(.caption2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                #endif
            }
        }
        .padding(.vertical, 8)
    }
}

struct ProposalCountBadge: View {
    @EnvironmentObject private var model: AppModel
    let job: UpworkJob

    private var highlightColor: ProposalHighlightColor {
        guard let tier = job.proposalTier else { return .off }
        return model.settings.proposalHighlightColors[tier] ?? .off
    }

    private var foregroundColor: Color {
        switch highlightColor {
        case .green: .green
        case .yellow: .orange
        case .red: .red
        case .off: .secondary
        }
    }

    private var backgroundColor: Color {
        switch highlightColor {
        case .green: .green.opacity(0.12)
        case .yellow: .yellow.opacity(0.18)
        case .red: .red.opacity(0.12)
        case .off: .clear
        }
    }

    var body: some View {
        if let proposalCount = job.proposalCountDisplay {
            Label(proposalCount, systemImage: "person.2")
                .font(.caption.weight(highlightColor == .off ? .regular : .semibold))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(backgroundColor, in: Capsule())
                .accessibilityLabel("Proposals: \(proposalCount)")
        }
    }
}
