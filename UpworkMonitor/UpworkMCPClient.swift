import Foundation

enum UpworkMCPError: LocalizedError {
    case unauthorized
    case httpStatus(Int, String)
    case invalidResponse
    case sessionExpired
    case server(String)
    case missingTool(String)
    case invalidAccounts
    case invalidJobs

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "The Upwork connection needs to be refreshed. Reconnect in Settings if this continues."
        case .httpStatus(let status, let message):
            "Upwork MCP returned HTTP \(status): \(message)"
        case .invalidResponse:
            "Upwork MCP returned an unreadable response."
        case .sessionExpired:
            "The Upwork MCP session expired. Try refreshing again."
        case .server(let message):
            "Upwork MCP error: \(message)"
        case .missingTool(let message):
            "Upwork MCP tool discovery failed: \(message)"
        case .invalidAccounts:
            "Upwork MCP did not return an account list."
        case .invalidJobs:
            "Upwork MCP did not return a job list."
        }
    }
}

@MainActor
final class UpworkMCPClient {
    static let endpoint = URL(string: "https://mcp.upwork.com/mcp")!
    static let protocolVersion = "2025-06-18"

    private let session: URLSession
    private var sessionID: String?
    private var initialized = false
    // The Upwork server exposes namespaced names (upwork__<tool>) on the wire,
    // while the app addresses tools by their stable, unprefixed names.
    private var availableTools: [String: String] = [:]
    private var nextRequestID = 1

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resetSession() {
        sessionID = nil
        initialized = false
        availableTools = [:]
    }

    func listAccounts(accessToken: String) async throws -> [UpworkAccount] {
        let value = try await callTool("list_accounts", arguments: [:], accessToken: accessToken)
        guard let root = dictionary(value) else { throw UpworkMCPError.invalidAccounts }
        let data = dictionary(root["data"]) ?? root
        guard let values = first(data, ["accounts", "items"]) as? [[String: Any]] else {
            throw UpworkMCPError.invalidAccounts
        }
        return values.compactMap { account in
            guard let orgUID = string(first(account, ["org_uid", "orgUID", "organization_uid"])),
                  !orgUID.isEmpty else { return nil }
            return UpworkAccount(
                name: string(first(account, ["name", "account_name", "display_name"])) ?? "Upwork account",
                orgUID: orgUID,
                role: string(account["role"]) ?? "",
                roleLabel: string(first(account, ["role_label", "roleLabel"])) ?? ""
            )
        }
    }

    func fetchJobs(feed: FeedKind, account: UpworkAccount, accessToken: String) async throws -> [UpworkJob] {
        let value = try await callTool(
            "find_jobs",
            arguments: [
                "action": "smart_search",
                "org_uid": account.orgUID,
                "params": ["mode": feed.mcpMode, "limit": 10]
            ],
            accessToken: accessToken
        )
        guard let root = dictionary(value) else { throw UpworkMCPError.invalidJobs }
        let data = dictionary(root["data"]) ?? root
        guard let jobs = first(data, ["jobs", "results", "items"]) as? [[String: Any]] else {
            throw UpworkMCPError.invalidJobs
        }
        return jobs.compactMap { mapJob($0) }
    }

    func fetchJobDetails(
        for job: UpworkJob,
        account: UpworkAccount,
        accessToken: String
    ) async throws -> UpworkJob {
        let value = try await callTool(
            "find_jobs",
            arguments: [
                "action": "get",
                "org_uid": account.orgUID,
                "params": ["id": job.id]
            ],
            accessToken: accessToken
        )
        guard let root = dictionary(value) else { return job }
        return mapJob(root, fallback: job, detail: true) ?? job
    }

    private func callTool(
        _ name: String,
        arguments: [String: Any],
        accessToken: String,
        retryingExpiredSession: Bool = false
    ) async throws -> Any {
        do {
            try await ensureInitialized(accessToken: accessToken)
            guard let serverToolName = availableTools[name] else {
                throw UpworkMCPError.missingTool("\(name) was not returned by tools/list.")
            }
            let response = try await post(
                [
                    "jsonrpc": "2.0",
                    "id": takeRequestID(),
                    "method": "tools/call",
                    "params": ["name": serverToolName, "arguments": arguments]
                ],
                accessToken: accessToken
            )
            if let error = dictionary(response["error"]) {
                throw UpworkMCPError.server(string(error["message"]) ?? "Unknown JSON-RPC error")
            }
            guard let result = dictionary(response["result"]) else { throw UpworkMCPError.invalidResponse }
            if (result["isError"] as? Bool) == true {
                throw UpworkMCPError.server(text(in: result) ?? "Tool call failed")
            }
            if let structured = result["structuredContent"] { return structured }
            if let parsed = parseToolContent(result["content"]) { return parsed }
            return result
        } catch UpworkMCPError.sessionExpired where !retryingExpiredSession {
            resetSession()
            return try await callTool(
                name,
                arguments: arguments,
                accessToken: accessToken,
                retryingExpiredSession: true
            )
        }
    }

    private func ensureInitialized(accessToken: String) async throws {
        guard !initialized else { return }
        let initializeResponse = try await post(
            [
                "jsonrpc": "2.0",
                "id": takeRequestID(),
                "method": "initialize",
                "params": [
                    "protocolVersion": Self.protocolVersion,
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "upwork-monitor", "version": "0.1.0"]
                ]
            ],
            accessToken: accessToken
        )
        if let error = dictionary(initializeResponse["error"]) {
            throw UpworkMCPError.server(string(error["message"]) ?? "Initialization failed")
        }

        let toolsResponse = try await post(
            ["jsonrpc": "2.0", "id": takeRequestID(), "method": "tools/list", "params": [:]],
            accessToken: accessToken
        )
        guard let result = dictionary(toolsResponse["result"]),
              let tools = result["tools"] as? [[String: Any]] else {
            throw UpworkMCPError.invalidResponse
        }
        availableTools = [:]
        for tool in tools {
            guard let serverName = string(tool["name"]) else { continue }
            let name = Self.unprefixedToolName(serverName)
            if availableTools[name] == nil || name == serverName {
                availableTools[name] = serverName
            }
        }
        guard availableTools["list_accounts"] != nil, availableTools["find_jobs"] != nil else {
            let names = availableTools.values.sorted()
            let reportedNames = names.isEmpty ? "none" : names.joined(separator: ", ")
            throw UpworkMCPError.missingTool(
                "Expected list_accounts and find_jobs; tools/list returned: \(reportedNames)."
            )
        }

        _ = try await postNotification("notifications/initialized", accessToken: accessToken)
        initialized = true
    }

    private func postNotification(_ method: String, accessToken: String) async throws -> [String: Any] {
        try await send(["jsonrpc": "2.0", "method": method], accessToken: accessToken, expectsResponse: false)
    }

    private func post(_ object: [String: Any], accessToken: String) async throws -> [String: Any] {
        try await send(object, accessToken: accessToken, expectsResponse: true)
    }

    private func send(
        _ object: [String: Any],
        accessToken: String,
        expectsResponse: Bool
    ) async throws -> [String: Any] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if object["method"] as? String != "initialize" {
            request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: object)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpworkMCPError.invalidResponse }
        if let newSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = newSessionID
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                resetSession()
                throw UpworkMCPError.unauthorized
            }
            if http.statusCode == 404, sessionID != nil {
                resetSession()
                throw UpworkMCPError.sessionExpired
            }
            let message = String(data: data.prefix(600), encoding: .utf8) ?? "Request failed"
            throw UpworkMCPError.httpStatus(http.statusCode, message)
        }
        if data.isEmpty && !expectsResponse { return [:] }
        guard let responseObject = parseJSONOrSSE(data) else {
            if !expectsResponse { return [:] }
            throw UpworkMCPError.invalidResponse
        }
        return responseObject
    }

    private func takeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private static func unprefixedToolName(_ serverName: String) -> String {
        var name = serverName
        if name.hasPrefix("mcp__") { name.removeFirst("mcp__".count) }
        if name.hasPrefix("upwork__") { name.removeFirst("upwork__".count) }
        if name.hasPrefix("upwork__") { name.removeFirst("upwork__".count) }
        return name
    }

    private func parseJSONOrSSE(_ data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        let eventPayloads = body.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { return nil }
            return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        for payload in eventPayloads.reversed() {
            guard let bytes = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { continue }
            return object
        }
        return nil
    }

    private func parseToolContent(_ content: Any?) -> Any? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        for block in blocks {
            guard let value = string(block["text"]) else { continue }
            guard let data = value.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
            return parsed
        }
        return nil
    }

    private func text(in result: [String: Any]) -> String? {
        guard let blocks = result["content"] as? [[String: Any]] else { return nil }
        return blocks.compactMap { string($0["text"]) }.joined(separator: "\n")
    }

    private func removeMCPContentMarkers(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<untrusted_participant_content>", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "</untrusted_participant_content>", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mapJob(_ raw: [String: Any], fallback: UpworkJob? = nil, detail: Bool = false) -> UpworkJob? {
        let data = dictionary(raw["data"]) ?? raw
        let posting = dictionary(data["marketplaceJobPosting"]) ?? dictionary(data["job"]) ?? raw
        let content = dictionary(posting["content"]) ?? [:]
        let classification = dictionary(posting["classification"]) ?? [:]
        let contractTerms = dictionary(posting["contractTerms"]) ?? [:]
        let activity = dictionary(posting["activityStat"]) ?? [:]
        let proposalCountFields = [
            "totalApplicants", "total_applicants", "proposalCount", "proposal_count",
            "proposalsCount", "proposals_count", "totalProposals", "total_proposals"
        ]
        let proposalCountValue = first(activity, proposalCountFields)
            ?? first(posting, proposalCountFields)
            ?? first(content, proposalCountFields)
            ?? first(data, proposalCountFields)
            ?? first(raw, proposalCountFields)
        let proposalLabelFields = [
            "proposalsLabel", "proposals_label", "proposalCountLabel", "proposal_count_label",
            "proposalsTier", "proposals_tier", "proposalTier", "proposal_tier"
        ]
        let proposalLabelValue = first(activity, proposalLabelFields)
            ?? first(posting, proposalLabelFields)
            ?? first(data, proposalLabelFields)
            ?? first(raw, proposalLabelFields)

        guard let id = fallback?.id ?? string(first(posting, ["id", "ciphertext", "job_id"])) else { return nil }
        let title = string(first(content, ["title", "name"]))
            ?? string(first(posting, ["title", "name"]))
            ?? fallback?.title ?? "Untitled job"
        let description = removeMCPContentMarkers(string(first(content, ["description", "descriptionText"]))
            ?? string(first(posting, ["description", "description_snippet", "snippet"]))
            ?? fallback?.description ?? "")
        let clientRaw = dictionary(raw["client"])
            ?? dictionary(posting["clientCompanyPublic"])
            ?? dictionary(data["client"])
            ?? [:]
        let record = dictionary(data["client_record"])
            ?? dictionary(raw["client_record"])
            ?? dictionary(clientRaw["client_record"])
            ?? [:]
        let reviewSource = first(data, ["client_feedback", "client_work_history", "client_reviews", "reviews"])
            ?? first(raw, ["client_feedback", "client_work_history", "client_reviews", "reviews"])
            ?? first(record, ["reviews", "feedback", "work_history", "contracts"])
        let client = mapClient(clientRaw, record: record, reviewSource: reviewSource, fallback: fallback?.client)

        let budget = first(posting, ["budget", "budgetInfo", "budget_info"])
            ?? first(content, ["budget", "budgetInfo"])
        let budgetObject = dictionary(budget) ?? dictionary(contractTerms["fixedPrice"]) ?? [:]
        let budgetMoney = money(budget)
        let displayBudget = string(first(budgetObject, ["display", "displayValue", "display_value", "formatted"]))
            ?? budgetMoney?.formatted
            ?? (budget is String ? string(budget) : nil)
            ?? string(first(posting, ["display_budget", "budget_display"]))
        let hourly = dictionary(contractTerms["hourly"]) ?? dictionary(contractTerms["hourlyRate"]) ?? [:]
        let hourlyMinimum = money(first(hourly, ["min", "minimum", "rateMin", "rate_min"]), currency: string(hourly["currency"]))
            ?? fallback?.hourlyBudgetMin
        let hourlyMaximum = money(first(hourly, ["max", "maximum", "rateMax", "rate_max"]), currency: string(hourly["currency"]))
            ?? fallback?.hourlyBudgetMax
        let skillValues = first(content, ["skills", "ontologySkills"])
            ?? first(posting, ["skills", "ontologySkills"])
        let skills = skillList(skillValues).isEmpty ? (fallback?.skills ?? []) : skillList(skillValues)
        let url = string(first(posting, ["url", "job_url", "jobUrl"]))
            ?? string(first(raw, ["url", "job_url"]))
            ?? fallback?.urlString

        return UpworkJob(
            id: id,
            title: title,
            description: description,
            urlString: url,
            publishedDateTime: string(first(raw, ["published_date", "publishedDate", "publishedDateTime"]))
                ?? string(first(posting, ["publishedDate", "published_date"]))
                ?? fallback?.publishedDateTime,
            createdDateTime: string(first(raw, ["created_date", "createdDate", "createdDateTime"]))
                ?? string(first(posting, ["createdDate", "created_date"]))
                ?? fallback?.createdDateTime,
            displayBudget: displayBudget ?? fallback?.displayBudget,
            hourlyBudgetMin: hourlyMinimum,
            hourlyBudgetMax: hourlyMaximum,
            experienceLevel: string(first(content, ["experienceLevel", "experience_level"]))
                ?? string(first(posting, ["experienceLevel", "experience_level"]))
                ?? fallback?.experienceLevel,
            category: string(first(classification, ["category", "categoryName"]))
                ?? string(first(content, ["category", "categoryName"]))
                ?? fallback?.category,
            subcategory: string(first(classification, ["subCategory", "subcategory", "subCategoryName"]))
                ?? fallback?.subcategory,
            totalApplicants: integer(proposalCountValue) ?? fallback?.totalApplicants,
            proposalsLabel: string(proposalLabelValue)
                ?? (integer(proposalCountValue) == nil ? string(proposalCountValue) : nil)
                ?? fallback?.proposalsLabel,
            skills: skills,
            client: client,
            applied: fallback?.applied,
            detailLoaded: detail || fallback?.detailLoaded == true
        )
    }

    private func mapClient(
        _ raw: [String: Any],
        record: [String: Any],
        reviewSource: Any?,
        fallback: UpworkClient?
    ) -> UpworkClient? {
        guard !raw.isEmpty || !record.isEmpty || fallback != nil else { return nil }
        let locationRaw = dictionary(raw["location"]) ?? dictionary(record["location"]) ?? [:]
        let country = string(first(locationRaw, ["country", "countryName", "country_name"]))
            ?? string(first(raw, ["country", "country_name", "countryName"]))
            ?? fallback?.location?.country
        let location = UpworkLocation(
            city: string(first(locationRaw, ["city", "cityName", "city_name"])) ?? fallback?.location?.city,
            state: string(first(locationRaw, ["state", "stateName", "state_name"])) ?? fallback?.location?.state,
            country: country,
            timezone: string(first(locationRaw, ["timezone", "time_zone"])) ?? fallback?.location?.timezone
        )
        let rating = double(first(record, ["feedback_score", "feedbackScore", "rating", "score"]))
            ?? double(first(raw, ["feedback_score", "feedbackScore", "rating", "score"]))
            ?? fallback?.totalFeedback
        let reviewCount = integer(first(record, ["feedback_count", "feedbackCount", "total_reviews", "review_count"]))
            ?? integer(first(raw, ["feedback_count", "feedbackCount", "total_reviews", "review_count"]))
            ?? fallback?.totalReviews
        let spentValue = first(record, ["total_spent", "totalSpent", "amount_spent", "amountSpent"])
            ?? first(raw, ["total_spent", "totalSpent", "amount_spent", "amountSpent"])
        let totalSpent = money(spentValue, currency: string(first(record, ["currency", "currency_code"])))
            ?? fallback?.totalSpent
        let paymentVerified = first(raw, ["payment_verified", "paymentVerified"]) as? Bool
        let verification = string(first(raw, ["verification_status", "verificationStatus"]))
            ?? string(first(record, ["verification_status", "verificationStatus"]))
            ?? paymentVerified.map { $0 ? "Verified" : "Not verified" }
            ?? fallback?.verificationStatus
        let reviews = mapReviews(reviewSource, fallback: fallback?.reviews ?? [])
        let latestTitle = reviews.first?.contractTitle
            ?? string(first(record, ["last_contract_title", "latest_contract_title"]))
            ?? fallback?.latestContractTitle

        return UpworkClient(
            location: location,
            totalHires: integer(first(record, ["hires", "total_hires", "totalHires", "hire_count"]))
                ?? integer(first(raw, ["hires", "total_hires", "hire_count"]))
                ?? fallback?.totalHires,
            jobsWithHires: integer(first(record, ["jobs_with_hires", "jobsWithHires"]))
                ?? fallback?.jobsWithHires,
            totalPostedJobs: integer(first(record, ["jobs_posted", "jobsPosted", "total_posted_jobs"]))
                ?? integer(first(raw, ["jobs_posted", "total_posted_jobs"]))
                ?? fallback?.totalPostedJobs,
            totalSpent: totalSpent,
            verificationStatus: verification,
            totalReviews: reviewCount,
            totalFeedback: rating,
            activeContracts: integer(first(record, ["contracts_active", "contractsActive", "active_contracts"]))
                ?? fallback?.activeContracts,
            totalContracts: integer(first(record, ["contracts_total", "contractsTotal", "total_contracts"]))
                ?? fallback?.totalContracts,
            totalHours: double(first(record, ["hours_total", "hoursTotal", "total_hours"]))
                ?? fallback?.totalHours,
            openJobs: integer(first(record, ["open_jobs", "openJobs"])) ?? fallback?.openJobs,
            latestContractTitle: latestTitle,
            hasFinancialPrivacy: (first(record, ["financial_privacy", "has_financial_privacy"]) as? Bool)
                ?? (first(raw, ["financial_privacy", "has_financial_privacy"]) as? Bool)
                ?? fallback?.hasFinancialPrivacy,
            reviews: reviews
        )
    }

    private func mapReviews(_ source: Any?, fallback: [UpworkClientReview]) -> [UpworkClientReview] {
        let values: [[String: Any]]
        if let array = source as? [[String: Any]] {
            values = array
        } else if let object = source as? [String: Any] {
            values = first(object, ["reviews", "feedback", "feedbacks", "items", "work_history", "contracts"]) as? [[String: Any]]
                ?? (object.isEmpty ? [] : [object])
        } else {
            values = []
        }
        let mapped = values.compactMap { item -> UpworkClientReview? in
            let comment = string(first(item, ["comment", "feedback", "public_feedback", "review_text"]))
            let title = string(first(item, ["contract_title", "contractTitle", "title", "job_title"]))
            let score = double(first(item, ["score", "feedback_score", "rating"]))
            let date = string(first(item, ["date", "ended_date", "end_date", "created_at"]))
            guard comment != nil || title != nil || score != nil || date != nil else { return nil }
            return UpworkClientReview(date: date, score: score, contractTitle: title, comment: comment)
        }
        return mapped.isEmpty ? fallback : mapped
    }

    private func skillList(_ value: Any?) -> [UpworkSkill] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { item in
            if let name = item as? String { return UpworkSkill(name: name, prettyName: nil) }
            guard let skill = item as? [String: Any] else { return nil }
            let name = string(first(skill, ["name", "skill_name", "skillName"]))
            let pretty = string(first(skill, ["pretty_name", "prettyName", "label"]))
            guard name != nil || pretty != nil else { return nil }
            return UpworkSkill(name: name, prettyName: pretty)
        }
    }

    private func money(_ value: Any?, currency: String? = nil) -> UpworkMoney? {
        guard let value else { return nil }
        if let object = value as? [String: Any] {
            let amount = string(first(object, ["amount", "value", "displayValue", "display_value", "formatted"]))
            let code = string(first(object, ["currency", "currency_code", "currencyCode"])) ?? currency
            guard amount != nil || code != nil else { return nil }
            return UpworkMoney(displayValue: amount, currency: code)
        }
        guard let amount = string(value) else { return nil }
        return UpworkMoney(displayValue: amount, currency: currency)
    }

    private func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    private func first(_ object: [String: Any], _ keys: [String]) -> Any? {
        for key in keys where object[key] != nil && !(object[key] is NSNull) { return object[key] }
        return nil
    }

    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value.isEmpty ? nil : value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
