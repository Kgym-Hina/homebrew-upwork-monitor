import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSettings = false

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(selection: $model.selectedFeed) {
                Section("Jobs") {
                    ForEach(FeedKind.allCases) { feed in
                        Label(feed.title, systemImage: feed == .bestMatches ? "sparkles" : "clock")
                            .tag(feed)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                SidebarStatusView()
            }
        } detail: {
            JobListView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshSelectedFeed() }
                } label: {
                    if model.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(!model.isConnected || model.isLoading)
                .help("Refresh jobs")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task {
            await model.restoreConnection()
            model.startMonitoring()
        }
        .alert(
            "Upwork Monitor",
            isPresented: Binding(
                get: { model.errorMessage != nil && !showingSettings },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        #else
        NavigationStack {
            JobListView()
                .navigationTitle(model.selectedFeed.title)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(FeedKind.allCases) { feed in
                                Button {
                                    model.selectedFeed = feed
                                } label: {
                                    Label(feed.title, systemImage: feed == .bestMatches ? "sparkles" : "clock")
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            Task { await model.refreshSelectedFeed() }
                        } label: {
                            if model.isLoading {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(!model.isConnected || model.isLoading)

                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .task {
            await model.restoreConnection()
        }
        .alert(
            "Upwork Monitor",
            isPresented: Binding(
                get: { model.errorMessage != nil && !showingSettings },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        #endif
    }
}

struct SidebarStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                if model.isRestoringConnection {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(model.isConnected ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(model.isConnected ? "Connected" : "Not connected")
                        .foregroundStyle(.secondary)
                }
            }
            if let date = model.lastUpdated {
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Feed", selection: $model.selectedFeed) {
                ForEach(FeedKind.allCases) { feed in
                    Text(feed.title).tag(feed)
                }
            }
            .pickerStyle(.menu)

            if model.currentJobs.isEmpty {
                if model.isRestoringConnection || model.isLoading {
                    Label("Loading jobs…", systemImage: "arrow.trianglehead.2.clockwise")
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.isConnected ? "No jobs loaded" : "Connect to Upwork in Settings")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.currentJobs.prefix(5)) { job in
                    MenuBarJobRow(job: job)
                }
            }

            Divider()
            HStack {
                Button("Refresh") {
                    Task { await model.refreshSelectedFeed() }
                }
                .disabled(!model.isConnected || model.isLoading)
                Button("Open") {
                    #if os(macOS)
                    NSWorkspace.shared.open(URL(string: "com.hina.upworkmonitor.macos:/")!)
                    #endif
                }
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

struct MenuBarJobRow: View {
    @EnvironmentObject private var model: AppModel
    let job: UpworkJob

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let budget = job.budgetLabel {
                        Text(budget)
                    }
                    if let location = job.client?.location?.displayName, !location.isEmpty {
                        Text(location)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if job.proposalCountDisplay != nil {
                    ProposalCountBadge(job: job)
                }
            }
            Spacer(minLength: 4)
            Button {
                model.copy(job: job)
            } label: {
                Image(systemName: model.copiedJobID == job.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy project and client information")
        }
    }
}
