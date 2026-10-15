import Combine
import Foundation

#if os(macOS)
import AppKit
import ServiceManagement
#else
import UIKit
#endif

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet { settingsStore.save(settings) }
    }
    @Published var aiSettings: AISettings
    @Published private(set) var hasAIAPIKey: Bool
    @Published private(set) var aiConfigurationError: String?
    @Published var selectedFeed: FeedKind = .bestMatches
    @Published private(set) var jobsByFeed: [FeedKind: [UpworkJob]] = [:]
    @Published private(set) var accounts: [UpworkAccount] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRestoringConnection = true
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isConnected = false
    @Published private(set) var detailLoadingIDs = Set<String>()
    @Published var errorMessage: String?
    @Published var copiedJobID: String?
    @Published var copyingJobID: String?

    private let mcpClient: UpworkMCPClient
    private let oauthCoordinator: OAuthCoordinator
    private let settingsStore: SettingsStore
    private let aiSettingsStore: AISettingsStore
    private let aiReplyClient: AIReplyClient
    private let copyFormatter = JobCopyFormatter()
    private static let aiAPIKeyKey = "ai-provider-api-key"
    private var detailsByID: [String: UpworkJob] = [:]
    private var monitorTask: Task<Void, Never>?
    private var didRestoreConnection = false

    init(
        mcpClient: UpworkMCPClient = UpworkMCPClient(),
        oauthCoordinator: OAuthCoordinator = OAuthCoordinator(),
        settingsStore: SettingsStore = .shared,
        aiSettingsStore: AISettingsStore = .shared,
        aiReplyClient: AIReplyClient = AIReplyClient()
    ) {
        self.mcpClient = mcpClient
        self.oauthCoordinator = oauthCoordinator
        self.settingsStore = settingsStore
        self.aiSettingsStore = aiSettingsStore
        self.aiReplyClient = aiReplyClient
        self.settings = settingsStore.load()
        self.aiSettings = aiSettingsStore.load()
        self.hasAIAPIKey = false
        self.isConnected = false
    }

    var currentJobs: [UpworkJob] { jobsByFeed[selectedFeed] ?? [] }

    var selectedAccount: UpworkAccount? {
        if let selected = settings.selectedAccountUID,
           let account = accounts.first(where: { $0.orgUID == selected }) {
            return account
        }
        return accounts.first(where: {
            let role = "\($0.role) \($0.roleLabel)".lowercased()
            return role.contains("talent") || role.contains("freelancer")
        }) ?? accounts.first
    }

    func enrichedJob(_ job: UpworkJob) -> UpworkJob {
        detailsByID[job.id] ?? job
    }

    func restoreConnection() async {
        guard !didRestoreConnection else { return }
        didRestoreConnection = true
        defer { isRestoringConnection = false }
        await oauthCoordinator.restoreFromKeychain()
        let storedAIAPIKey = try? await KeychainStore.shared.load(String.self, for: Self.aiAPIKeyKey)
        hasAIAPIKey = storedAIAPIKey?.isEmpty == false
        guard oauthCoordinator.hasCredentials else {
            isConnected = false
            return
        }

        do {
            let token = try await oauthCoordinator.validAccessToken()
            try await loadAccounts(accessToken: token)
            isConnected = true
            await refreshAll(notifyNewJobs: false)
        } catch {
            await recoverOrReport(error)
        }
    }

    func connect() async {
        errorMessage = nil
        do {
            let credentials = try await oauthCoordinator.connect()
            isConnected = true
            mcpClient.resetSession()
            try await loadAccounts(accessToken: credentials.accessToken)
            #if os(macOS)
            if settings.notificationsEnabled {
                _ = await NotificationManager.shared.requestAuthorization()
            }
            #endif
            await refreshAll(notifyNewJobs: false)
        } catch {
            errorMessage = error.localizedDescription
            isConnected = oauthCoordinator.hasCredentials
        }
    }

    func disconnect() async {
        stopMonitoring()
        await oauthCoordinator.disconnect()
        mcpClient.resetSession()
        isConnected = false
        accounts = []
        jobsByFeed = [:]
        detailsByID = [:]
        lastUpdated = nil
        errorMessage = nil
    }

    func selectAccount(_ accountUID: String) {
        guard accounts.contains(where: { $0.orgUID == accountUID }),
              settings.selectedAccountUID != accountUID else { return }
        settings.selectedAccountUID = accountUID
        jobsByFeed = [:]
        detailsByID = [:]
        Task { await refreshAll(notifyNewJobs: false) }
    }

    func refreshSelectedFeed() async {
        await refresh(feed: selectedFeed, notifyNewJobs: false)
    }

    func refreshAll(notifyNewJobs: Bool) async {
        guard isConnected, selectedAccount != nil else { return }
        isLoading = true
        defer { isLoading = false }
        for feed in FeedKind.allCases {
            await loadFeed(feed, notifyNewJobs: notifyNewJobs)
        }
        lastUpdated = Date()
    }

    func refresh(feed: FeedKind, notifyNewJobs: Bool) async {
        guard isConnected, selectedAccount != nil else { return }
        isLoading = true
        defer { isLoading = false }
        await loadFeed(feed, notifyNewJobs: notifyNewJobs)
    }

    func loadDetails(for job: UpworkJob) async {
        do {
            _ = try await fetchDetails(for: job)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startMonitoring() {
        #if os(macOS)
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            if self.isConnected && self.settings.notificationsEnabled {
                _ = await NotificationManager.shared.requestAuthorization()
            }
            while !Task.isCancelled {
                await self.refreshAll(notifyNewJobs: true)
                let minutes = max(1, self.settings.pollingIntervalMinutes)
                let duration = UInt64(minutes) * 60 * 1_000_000_000
                try? await Task.sleep(nanoseconds: duration)
            }
        }
        #endif
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func requestNotificationPermission() async {
        settings.notificationsEnabled = await NotificationManager.shared.requestAuthorization()
    }

    func copy(job: UpworkJob) {
        guard copyingJobID == nil else { return }
        copyingJobID = job.id
        Task { [weak self] in
            guard let self else { return }
            var copySource = self.enrichedJob(job)
            if !copySource.detailLoaded {
                do {
                    copySource = try await self.fetchDetails(for: copySource)
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
            ClipboardService.copy(self.copyFormatter.text(for: copySource))
            self.copiedJobID = job.id
            self.copyingJobID = nil
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.copiedJobID == job.id { self.copiedJobID = nil }
        }
    }

    func saveAIConfiguration(settings: AISettings, apiKey: String) async {
        do {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                try await KeychainStore.shared.save(key, for: Self.aiAPIKeyKey)
                hasAIAPIKey = true
            }
            aiSettings = settings
            aiSettingsStore.save(settings)
            aiConfigurationError = nil
        } catch {
            aiConfigurationError = error.localizedDescription
        }
    }

    func removeAIAPIKey() async {
        do {
            try await KeychainStore.shared.delete(key: Self.aiAPIKeyKey)
            hasAIAPIKey = false
            aiConfigurationError = nil
        } catch {
            aiConfigurationError = error.localizedDescription
        }
    }

    func generateAIReply(for job: UpworkJob) async throws -> String {
        guard let apiKey = try await KeychainStore.shared.load(String.self, for: Self.aiAPIKeyKey),
              !apiKey.isEmpty else {
            throw AIReplyError.missingConfiguration
        }

        var source = enrichedJob(job)
        if !source.detailLoaded, isConnected, !detailLoadingIDs.contains(job.id) {
            source = (try? await fetchDetails(for: source)) ?? source
        }
        return try await aiReplyClient.generateReply(job: source, settings: aiSettings, apiKey: apiKey)
    }

    #if os(macOS)
    func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
            errorMessage = nil
        } catch {
            settings.launchAtLogin = false
            errorMessage = error.localizedDescription
        }
    }
    #endif

    private func loadAccounts(accessToken: String) async throws {
        let result = try await withAuthorizationRecovery(accessToken: accessToken) { token in
            try await self.mcpClient.listAccounts(accessToken: token)
        }
        guard !result.isEmpty else { throw UpworkMCPError.invalidAccounts }
        accounts = result
        if let selectedAccountUID = settings.selectedAccountUID,
           !result.contains(where: { $0.orgUID == selectedAccountUID }) {
            settings.selectedAccountUID = nil
        }
    }

    private func loadFeed(_ feed: FeedKind, notifyNewJobs: Bool) async {
        guard let account = selectedAccount else { return }
        do {
            let jobs = try await withAuthorizationRecovery { token in
                try await self.mcpClient.fetchJobs(feed: feed, account: account, accessToken: token)
            }
            jobsByFeed[feed] = jobs.map { detailsByID[$0.id] ?? $0 }
            lastUpdated = Date()
            errorMessage = nil
            await handleNewJobs(jobs, feed: feed, notify: notifyNewJobs)
        } catch {
            await recoverOrReport(error)
        }
    }

    private func fetchDetails(for job: UpworkJob) async throws -> UpworkJob {
        if let cached = detailsByID[job.id] { return cached }
        guard let account = selectedAccount else { throw UpworkMCPError.invalidAccounts }
        detailLoadingIDs.insert(job.id)
        defer { detailLoadingIDs.remove(job.id) }
        let detailed = try await withAuthorizationRecovery { token in
            try await self.mcpClient.fetchJobDetails(for: job, account: account, accessToken: token)
        }
        detailsByID[job.id] = detailed
        for (feed, jobs) in jobsByFeed {
            jobsByFeed[feed] = jobs.map { $0.id == job.id ? detailed : $0 }
        }
        return detailed
    }

    private func withAuthorizationRecovery<T>(
        accessToken: String? = nil,
        operation: (String) async throws -> T
    ) async throws -> T {
        let token: String
        if let accessToken {
            token = accessToken
        } else {
            token = try await oauthCoordinator.validAccessToken()
        }
        do {
            return try await operation(token)
        } catch UpworkMCPError.unauthorized {
            let renewed = try await oauthCoordinator.validAccessToken(forceRefresh: true)
            return try await operation(renewed)
        }
    }

    private func recoverOrReport(_ error: Error) async {
        if case UpworkMCPError.unauthorized = error {
            isConnected = false
            mcpClient.resetSession()
        }
        errorMessage = error.localizedDescription
    }

    private func handleNewJobs(_ jobs: [UpworkJob], feed: FeedKind, notify: Bool) async {
        let accountKey = selectedAccount?.orgUID ?? "default"
        let key = "seen-job-ids-\(accountKey)-\(feed.rawValue)"
        let primedKey = "primed-\(accountKey)-\(feed.rawValue)"
        let notifiedKey = "notified-job-ids-\(accountKey)"
        let existing = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let notified = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        let isPrimed = UserDefaults.standard.bool(forKey: primedKey)
        let newJobs = jobs.filter { !existing.contains($0.id) && !notified.contains($0.id) }

        UserDefaults.standard.set(Array(Set(jobs.map(\.id))), forKey: key)
        UserDefaults.standard.set(true, forKey: primedKey)

        guard notify, isPrimed, settings.notificationsEnabled else { return }
        let jobsToNotify = Array(newJobs.prefix(10))
        for job in jobsToNotify {
            NotificationManager.shared.notify(job: job)
        }
        UserDefaults.standard.set(
            Array(notified.union(jobsToNotify.map(\.id))),
            forKey: notifiedKey
        )
    }
}

enum ClipboardService {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
