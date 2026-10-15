import Foundation

@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private let key = "app-settings"

    func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
final class AISettingsStore {
    static let shared = AISettingsStore()

    private let key = "ai-provider-settings"

    func load() -> AISettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AISettings.self, from: data) else {
            return AISettings()
        }
        return settings
    }

    func save(_ settings: AISettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct JobCopyFormatter {
    func text(for job: UpworkJob) -> String {
        let client = job.client ?? .empty
        var lines: [String] = []
        lines.append("项目：\(job.title)")
        if let url = job.webURL?.absoluteString {
            lines.append("链接：\(url)")
        }
        if let budget = job.budgetLabel {
            lines.append("预算：\(budget)")
        }
        if let category = job.category, !category.isEmpty {
            lines.append("类别：\(category)")
        }
        if !job.skillNames.isEmpty {
            lines.append("技能：\(job.skillNames.joined(separator: ", "))")
        }

        lines.append("")
        lines.append("项目简述：")
        lines.append(job.description.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        lines.append("客户信息：")
        if let location = client.location?.displayName, !location.isEmpty {
            lines.append("地点：\(location)")
        } else {
            lines.append("地点：未提供")
        }
        if let score = client.totalFeedback {
            lines.append(String(format: "评分：%.2f/5", score))
        } else {
            lines.append("评分：未提供")
        }
        if let reviews = client.totalReviews {
            lines.append("历史评价：\(reviews) 条")
        }
        if let hires = client.totalHires {
            lines.append("雇佣人次：\(hires)")
        }
        if let contracts = client.totalContracts {
            lines.append("历史合同：\(contracts) 份")
        }
        if let postedJobs = client.totalPostedJobs {
            lines.append("历史发帖：\(postedJobs) 个")
        }
        if client.hasFinancialPrivacy == true {
            lines.append("客户总花费：隐藏")
        } else if let totalSpent = client.totalSpent?.formatted {
            lines.append("客户总花费：\(totalSpent)")
        } else {
            lines.append("客户总花费：未提供")
        }
        if let verification = client.verificationStatus, !verification.isEmpty {
            lines.append("付款验证：\(verification)")
        }
        let reviewLines = client.reviews.prefix(5).compactMap { review -> String? in
            var pieces: [String] = []
            if let date = review.date, !date.isEmpty { pieces.append(date) }
            if let score = review.score { pieces.append(String(format: "%.2f/5", score)) }
            if let title = review.contractTitle, !title.isEmpty { pieces.append(title) }
            if let comment = review.comment {
                let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append(trimmed) }
            }
            return pieces.isEmpty ? nil : "- " + pieces.joined(separator: " · ")
        }
        if !reviewLines.isEmpty {
            lines.append("客户历史记录：")
            lines.append(contentsOf: reviewLines)
        } else if let lastContract = client.latestContractTitle, !lastContract.isEmpty {
            lines.append("最近合同：\(lastContract)")
        }

        return lines.joined(separator: "\n")
    }
}

enum AIReplyError: LocalizedError {
    case missingConfiguration
    case invalidAPIAddress
    case invalidAdditionalParameters
    case unsupportedAdditionalParameter(String)
    case httpStatus(Int)
    case invalidResponse
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "Set an HTTPS API address, model, and API key in AI settings."
        case .invalidAPIAddress:
            "The API address must be a valid HTTPS URL."
        case .invalidAdditionalParameters:
            "Additional parameters must be a JSON object."
        case .unsupportedAdditionalParameter(let name):
            "The additional parameter ‘\(name)’ is reserved or unsupported."
        case .httpStatus(let status):
            "The AI provider returned HTTP \(status). Check the address, key, model, and parameters."
        case .invalidResponse:
            "The AI provider returned an unreadable response."
        case .emptyResponse:
            "The AI provider returned an empty reply."
        }
    }
}

struct AIReplyClient {
    func generateReply(job: UpworkJob, settings: AISettings, apiKey: String) async throws -> String {
        let address = settings.apiAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !model.isEmpty, !key.isEmpty, !prompt.isEmpty else {
            throw AIReplyError.missingConfiguration
        }
        guard let components = URLComponents(string: address),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            throw AIReplyError.invalidAPIAddress
        }

        let extraParameters: [String: Any]
        let extraJSON = settings.additionalParametersJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if extraJSON.isEmpty {
            extraParameters = [:]
        } else {
            guard let data = extraJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIReplyError.invalidAdditionalParameters
            }
            extraParameters = object
        }

        let reservedParameters: Set<String> = [
            "model", "messages", "stream", "tools", "tool_choice", "functions",
            "function_call", "parallel_tool_calls"
        ]
        if let reserved = extraParameters.keys.first(where: { reservedParameters.contains($0) }) {
            throw AIReplyError.unsupportedAdditionalParameter(reserved)
        }

        var requestBody = extraParameters
        requestBody["model"] = model
        requestBody["messages"] = [
            ["role": "system", "content": prompt],
            ["role": "user", "content": JobCopyFormatter().text(for: job)]
        ]
        requestBody["stream"] = false
        if settings.thinkingEnabled, requestBody["thinking"] == nil {
            requestBody["thinking"] = true
        }
        if settings.reasoningEffort != .automatic, requestBody["reasoning_effort"] == nil {
            requestBody["reasoning_effort"] = settings.reasoningEffort.rawValue
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIReplyError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AIReplyError.httpStatus(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIReplyError.invalidResponse
        }

        let content: String
        if let value = message["content"] as? String {
            content = value
        } else if let blocks = message["content"] as? [[String: Any]] {
            content = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            throw AIReplyError.invalidResponse
        }
        let reply = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw AIReplyError.emptyResponse }
        return reply
    }
}
