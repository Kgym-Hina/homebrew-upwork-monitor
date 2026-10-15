import Foundation

enum FeedKind: String, CaseIterable, Identifiable, Codable {
    case bestMatches
    case mostRecent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bestMatches: "Best Matches"
        case .mostRecent: "Most Recent"
        }
    }

    var mcpMode: String {
        switch self {
        case .bestMatches: "best_match"
        case .mostRecent: "most_recent"
        }
    }
}

enum ProposalTier: String, CaseIterable, Codable, Hashable, Identifiable {
    case fewerThan5
    case fiveTo10
    case tenTo15
    case fifteenTo20
    case twentyTo50
    case fiftyPlus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fewerThan5: "Fewer than 5"
        case .fiveTo10: "5 to 10"
        case .tenTo15: "10 to 15"
        case .fifteenTo20: "15 to 20"
        case .twentyTo50: "20 to 50"
        case .fiftyPlus: "50+"
        }
    }

    static func from(count: Int) -> ProposalTier? {
        guard count >= 0 else { return nil }
        return switch count {
        case 0...4: .fewerThan5
        case 5...9: .fiveTo10
        case 10...14: .tenTo15
        case 15...19: .fifteenTo20
        case 20...49: .twentyTo50
        default: .fiftyPlus
        }
    }

    static func from(label: String) -> ProposalTier? {
        let normalized = label.lowercased()
        let numbers = label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let first = numbers.first else { return nil }

        if normalized.contains("fewer") || normalized.contains("less than") || normalized.contains("<") {
            return .fewerThan5
        }
        if normalized.contains("+") || normalized.contains("more than") || normalized.contains("over ") {
            return first >= 50 ? .fiftyPlus : nil
        }
        if numbers.count == 1 { return from(count: first) }

        return switch first {
        case 0..<5: .fewerThan5
        case 5..<10: .fiveTo10
        case 10..<15: .tenTo15
        case 15..<20: .fifteenTo20
        case 20..<50: .twentyTo50
        default: .fiftyPlus
        }
    }
}

enum ProposalHighlightColor: String, CaseIterable, Codable, Hashable, Identifiable {
    case green
    case yellow
    case red
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .green: "Green"
        case .yellow: "Yellow"
        case .red: "Red"
        case .off: "Off"
        }
    }

    static let defaults: [ProposalTier: ProposalHighlightColor] = [
        .fewerThan5: .green,
        .fiveTo10: .green,
        .tenTo15: .green,
        .fifteenTo20: .yellow,
        .twentyTo50: .red,
        .fiftyPlus: .red
    ]
}

struct UpworkAccount: Codable, Hashable, Identifiable {
    let name: String
    let orgUID: String
    let role: String
    let roleLabel: String

    var id: String { orgUID }

    var displayName: String {
        roleLabel.isEmpty ? name : "\(name) · \(roleLabel)"
    }
}

struct UpworkJob: Hashable, Identifiable {
    let id: String
    let title: String
    let description: String
    let urlString: String?
    let publishedDateTime: String?
    let createdDateTime: String?
    let displayBudget: String?
    let hourlyBudgetMin: UpworkMoney?
    let hourlyBudgetMax: UpworkMoney?
    let experienceLevel: String?
    let category: String?
    let subcategory: String?
    let totalApplicants: Int?
    let proposalsLabel: String?
    let skills: [UpworkSkill]
    let client: UpworkClient?
    let applied: Bool?
    let detailLoaded: Bool

    var webURL: URL? {
        if let urlString, let url = URL(string: urlString) {
            return url
        }
        return URL(string: "https://www.upwork.com/jobs/~\(id)")
    }

    var publishedDate: Date? {
        guard let value = publishedDateTime ?? createdDateTime else { return nil }
        return ISO8601DateFormatter().date(from: value)
            ?? ISO8601DateFormatter().date(from: value.replacingOccurrences(of: ".", with: ":"))
    }

    var budgetLabel: String? {
        if let displayBudget, !displayBudget.isEmpty { return displayBudget }
        let minimum = hourlyBudgetMin?.formatted
        let maximum = hourlyBudgetMax?.formatted
        return switch (minimum, maximum) {
        case let (minimum?, maximum?): "\(minimum)–\(maximum)/hr"
        case let (minimum?, nil): "From \(minimum)/hr"
        case let (nil, maximum?): "Up to \(maximum)/hr"
        default: nil
        }
    }

    var proposalCountDisplay: String? {
        if let totalApplicants, totalApplicants >= 0 {
            return "\(totalApplicants) proposals"
        }
        guard let proposalsLabel = proposalsLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !proposalsLabel.isEmpty else { return nil }
        if proposalsLabel.localizedCaseInsensitiveContains("proposal") {
            return proposalsLabel
        }
        return "\(proposalsLabel) proposals"
    }

    var proposalTier: ProposalTier? {
        if let proposalsLabel, let tier = ProposalTier.from(label: proposalsLabel) {
            return tier
        }
        if let totalApplicants {
            return ProposalTier.from(count: totalApplicants)
        }
        return nil
    }

    var skillNames: [String] {
        skills.compactMap { $0.prettyName ?? $0.name }
    }

    init(
        id: String,
        title: String,
        description: String,
        urlString: String? = nil,
        publishedDateTime: String? = nil,
        createdDateTime: String? = nil,
        displayBudget: String? = nil,
        hourlyBudgetMin: UpworkMoney? = nil,
        hourlyBudgetMax: UpworkMoney? = nil,
        experienceLevel: String? = nil,
        category: String? = nil,
        subcategory: String? = nil,
        totalApplicants: Int? = nil,
        proposalsLabel: String? = nil,
        skills: [UpworkSkill] = [],
        client: UpworkClient? = nil,
        applied: Bool? = nil,
        detailLoaded: Bool = false
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.urlString = urlString
        self.publishedDateTime = publishedDateTime
        self.createdDateTime = createdDateTime
        self.displayBudget = displayBudget
        self.hourlyBudgetMin = hourlyBudgetMin
        self.hourlyBudgetMax = hourlyBudgetMax
        self.experienceLevel = experienceLevel
        self.category = category
        self.subcategory = subcategory
        self.totalApplicants = totalApplicants
        self.proposalsLabel = proposalsLabel
        self.skills = skills
        self.client = client
        self.applied = applied
        self.detailLoaded = detailLoaded
    }
}

struct UpworkMoney: Hashable {
    let displayValue: String?
    let currency: String?

    var formatted: String {
        guard let displayValue, !displayValue.isEmpty else { return currency ?? "—" }
        guard let currency, !currency.isEmpty,
              !displayValue.localizedCaseInsensitiveContains(currency) else { return displayValue }
        return "\(displayValue) \(currency)"
    }

    init(displayValue: String?, currency: String? = nil) {
        self.displayValue = displayValue
        self.currency = currency
    }
}

struct UpworkSkill: Hashable {
    let name: String?
    let prettyName: String?
}

struct UpworkClient: Hashable {
    let location: UpworkLocation?
    let totalHires: Int?
    let jobsWithHires: Int?
    let totalPostedJobs: Int?
    let totalSpent: UpworkMoney?
    let verificationStatus: String?
    let totalReviews: Int?
    let totalFeedback: Double?
    let activeContracts: Int?
    let totalContracts: Int?
    let totalHours: Double?
    let openJobs: Int?
    let latestContractTitle: String?
    let hasFinancialPrivacy: Bool?
    let reviews: [UpworkClientReview]

    static let empty = UpworkClient(
        location: nil,
        totalHires: nil,
        jobsWithHires: nil,
        totalPostedJobs: nil,
        totalSpent: nil,
        verificationStatus: nil,
        totalReviews: nil,
        totalFeedback: nil,
        activeContracts: nil,
        totalContracts: nil,
        totalHours: nil,
        openJobs: nil,
        latestContractTitle: nil,
        hasFinancialPrivacy: nil,
        reviews: []
    )
}

struct UpworkLocation: Hashable {
    let city: String?
    let state: String?
    let country: String?
    let timezone: String?

    var displayName: String {
        [city, state, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct UpworkClientReview: Hashable {
    let date: String?
    let score: Double?
    let contractTitle: String?
    let comment: String?
}

struct MCPAuthRegistration: Codable, Hashable {
    let clientID: String
    let createdAt: Date
}

struct MCPAuthCredentials: Codable, Hashable {
    let clientID: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60)
    }
}

struct AppSettings: Codable, Hashable {
    var pollingIntervalMinutes = 1
    var notificationsEnabled = true
    var launchAtLogin = false
    var selectedAccountUID: String?
    var proposalHighlightColors = ProposalHighlightColor.defaults

    init() {}

    private enum CodingKeys: String, CodingKey {
        case pollingIntervalMinutes
        case notificationsEnabled
        case launchAtLogin
        case selectedAccountUID
        case proposalHighlightColors
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pollingIntervalMinutes = try values.decodeIfPresent(Int.self, forKey: .pollingIntervalMinutes) ?? 1
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        selectedAccountUID = try values.decodeIfPresent(String.self, forKey: .selectedAccountUID)
        let savedColors = try values.decodeIfPresent(
            [ProposalTier: ProposalHighlightColor].self,
            forKey: .proposalHighlightColors
        ) ?? [:]
        proposalHighlightColors = ProposalHighlightColor.defaults.merging(savedColors) { _, saved in saved }
    }
}

enum AIReasoningEffort: String, CaseIterable, Codable, Hashable, Identifiable {
    case automatic
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Default"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

struct AISettings: Codable, Hashable {
    var apiAddress = ""
    var model = ""
    var thinkingEnabled = false
    var reasoningEffort: AIReasoningEffort = .automatic
    var additionalParametersJSON = "{}"
    var systemPrompt = Self.initialSystemPrompt

    static let initialSystemPrompt = """
    You are a careful freelance professional. Draft a concise, tailored proposal for the Upwork job below. Write in the language used by the job post. Focus on the client's stated needs and a practical next step. Do not invent experience, credentials, results, availability, pricing, or other facts that were not provided. Return only the message body, with no analysis, heading, or claim that the proposal was submitted.
    """

    private enum CodingKeys: String, CodingKey {
        case apiAddress
        case model
        case thinkingEnabled
        case reasoningEffort
        case additionalParametersJSON
        case systemPrompt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        apiAddress = try values.decodeIfPresent(String.self, forKey: .apiAddress) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        thinkingEnabled = try values.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
        reasoningEffort = try values.decodeIfPresent(AIReasoningEffort.self, forKey: .reasoningEffort) ?? .automatic
        additionalParametersJSON = try values.decodeIfPresent(String.self, forKey: .additionalParametersJSON) ?? "{}"
        systemPrompt = try values.decodeIfPresent(String.self, forKey: .systemPrompt) ?? Self.initialSystemPrompt
    }
}
