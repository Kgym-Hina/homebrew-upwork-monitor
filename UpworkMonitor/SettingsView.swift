import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isConnecting = false
    @State private var aiSettings = AISettings()
    @State private var aiAPIKeyInput = ""
    @State private var didSaveAISettings = false

    var body: some View {
        Group {
            #if os(macOS)
            settingsForm
                .formStyle(.grouped)
                .navigationTitle("Upwork Monitor Settings")
                .frame(width: 520)
            #else
            NavigationStack {
                settingsForm
                    .formStyle(.grouped)
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            .frame(minWidth: 420, minHeight: 420)
            #endif
        }
        .onAppear {
            aiSettings = model.aiSettings
            aiAPIKeyInput = ""
            didSaveAISettings = false
        }
        .onChange(of: aiSettings) { _, _ in
            didSaveAISettings = false
        }
        .onChange(of: aiAPIKeyInput) { _, newValue in
            if !newValue.isEmpty {
                didSaveAISettings = false
            }
        }
    }

    private var settingsForm: some View {
        Form {
            Section("Upwork connection") {
                if model.isRestoringConnection {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading saved connection…")
                            .foregroundStyle(.secondary)
                    }
                } else if model.isConnected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if model.accounts.count > 1 {
                        Picker(
                            "Upwork account",
                            selection: Binding(
                                get: { model.selectedAccount?.orgUID ?? "" },
                                set: { model.selectAccount($0) }
                            )
                        ) {
                            ForEach(model.accounts) { account in
                                Text(account.displayName).tag(account.orgUID)
                            }
                        }
                    }
                    Button("Disconnect Upwork", role: .destructive) {
                        Task { await model.disconnect() }
                    }
                } else {
                    Button {
                        isConnecting = true
                        Task {
                            await model.connect()
                            isConnecting = false
                        }
                    } label: {
                        HStack {
                            Text(isConnecting ? "Connecting to Upwork…" : "Connect Upwork")
                            Spacer()
                            if isConnecting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isConnecting)
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Section("Monitoring") {
                Picker("Refresh interval", selection: $model.settings.pollingIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }

                Toggle("New job notifications", isOn: $model.settings.notificationsEnabled)
                    .onChange(of: model.settings.notificationsEnabled) { _, enabled in
                        if enabled {
                            Task { await model.requestNotificationPermission() }
                        }
                    }

                #if os(macOS)
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { model.settings.launchAtLogin },
                        set: { model.updateLaunchAtLogin($0) }
                    )
                )
                #endif
            }

            Section("Proposal highlights") {
                ForEach(ProposalTier.allCases) { tier in
                    Picker(
                        tier.title,
                        selection: Binding(
                            get: { model.settings.proposalHighlightColors[tier] ?? .off },
                            set: { model.settings.proposalHighlightColors[tier] = $0 }
                        )
                    ) {
                        ForEach(ProposalHighlightColor.allCases) { color in
                            Text(color.title).tag(color)
                        }
                    }
                }
            }

            Section("AI reply") {
                TextField("API address", text: $aiSettings.apiAddress)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                TextField("Model", text: $aiSettings.model)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField(model.hasAIAPIKey ? "Replace API key" : "API key", text: $aiAPIKeyInput)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                if model.hasAIAPIKey {
                    Label("API key stored in Keychain", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Button("Remove API key", role: .destructive) {
                        Task {
                            await model.removeAIAPIKey()
                            aiAPIKeyInput = ""
                        }
                    }
                }

                Toggle("Enable thinking", isOn: $aiSettings.thinkingEnabled)
                Picker("Reasoning effort", selection: $aiSettings.reasoningEffort) {
                    ForEach(AIReasoningEffort.allCases) { effort in
                        Text(effort.title).tag(effort)
                    }
                }

                Text("Additional parameters (JSON)")
                TextEditor(text: $aiSettings.additionalParametersJSON)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 76)

                Text("System prompt")
                TextEditor(text: $aiSettings.systemPrompt)
                    .frame(minHeight: 140)

                Button("Save AI settings") {
                    Task {
                        await model.saveAIConfiguration(settings: aiSettings, apiKey: aiAPIKeyInput)
                        aiAPIKeyInput = ""
                        didSaveAISettings = model.aiConfigurationError == nil
                    }
                }

                if didSaveAISettings {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                if let error = model.aiConfigurationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
