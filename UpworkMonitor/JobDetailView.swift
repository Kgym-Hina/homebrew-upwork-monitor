import SwiftUI

struct JobDetailView: View {
    @EnvironmentObject private var model: AppModel
    let job: UpworkJob
    @State private var generatedReply = ""
    @State private var isGeneratingReply = false
    @State private var aiErrorMessage: String?

    private var currentJob: UpworkJob { model.enrichedJob(job) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(currentJob.title)
                            .font(.title2.weight(.semibold))
                        if let date = currentJob.publishedDate {
                            Text("Posted \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        model.copy(job: currentJob)
                    } label: {
                        if model.copyingJobID == currentJob.id {
                            ProgressView()
                        } else {
                            Label(
                                model.copiedJobID == currentJob.id ? "Copied" : "Copy details",
                                systemImage: model.copiedJobID == currentJob.id ? "checkmark" : "doc.on.doc"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.copyingJobID != nil)
                }

                if model.detailLoadingIDs.contains(job.id) {
                    ProgressView("Loading job and client history")
                        .font(.caption)
                }

                DetailSection(title: "Project") {
                    MarkdownText(markdown: currentJob.description)
                    DetailFactsView(job: currentJob)
                }

                DetailSection(title: "Client") {
                    ClientFactsView(client: currentJob.client ?? .empty)
                }

                DetailSection(title: "AI reply") {
                    if !generatedReply.isEmpty {
                        TextEditor(text: $generatedReply)
                            .frame(minHeight: 160)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.quaternary, lineWidth: 1)
                            }
                    }

                    if let aiErrorMessage {
                        Text(aiErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                isGeneratingReply = true
                                aiErrorMessage = nil
                                defer { isGeneratingReply = false }
                                do {
                                    generatedReply = try await model.generateAIReply(for: currentJob)
                                } catch {
                                    aiErrorMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            if isGeneratingReply {
                                ProgressView()
                            } else {
                                Label("Reply with AI", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isGeneratingReply || model.detailLoadingIDs.contains(job.id))

                        if !generatedReply.isEmpty {
                            Button {
                                ClipboardService.copy(generatedReply)
                            } label: {
                                Label("Copy reply", systemImage: "doc.on.doc")
                            }
                        }

                        if let url = currentJob.webURL {
                            Link(destination: url) {
                                Label("Open project on Upwork", systemImage: "arrow.up.right.square")
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Job details")
        .task { await model.loadDetails(for: job) }
    }
}

private struct MarkdownText: View {
    private let elements: [MarkdownElement]

    init(markdown: String) {
        let parsed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(markdown)
        elements = Self.elements(from: Self.blocks(from: parsed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(elements) { element in
                switch element {
                case .block(let block):
                    MarkdownBlockView(block: block)
                case .table(let table):
                    tableView(table)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func tableView(_ table: MarkdownTable) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(table.rows) { row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(row.isHeader ? .subheadline.weight(.semibold) : .body)
                                .textSelection(.enabled)
                                .frame(width: 180, alignment: .leading)
                                .padding(8)
                                .overlay(alignment: .trailing) {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.15))
                                        .frame(width: 1)
                                }
                        }
                    }
                    .background(row.isHeader ? Color.secondary.opacity(0.12) : .clear)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(height: 1)
                    }
                }
            }
            .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private static func blocks(from text: AttributedString) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for run in text.runs {
            let fragment = AttributedString(text[run.range])
            if let lastIndex = blocks.indices.last,
               blocks[lastIndex].intent == run.presentationIntent {
                blocks[lastIndex].text.append(fragment)
            } else {
                blocks.append(MarkdownBlock(
                    id: blocks.count,
                    text: fragment,
                    intent: run.presentationIntent
                ))
            }
        }
        return blocks
    }

    private static func elements(from blocks: [MarkdownBlock]) -> [MarkdownElement] {
        var elements: [MarkdownElement] = []
        for block in blocks {
            guard let tableCell = block.tableCell else {
                elements.append(.block(block))
                continue
            }

            if let lastIndex = elements.indices.last,
               case .table(var table) = elements[lastIndex],
               table.id == tableCell.tableID {
                table.setCell(
                    block.text,
                    rowID: tableCell.rowID,
                    column: tableCell.column,
                    columnCount: tableCell.columnCount,
                    isHeader: tableCell.isHeader
                )
                elements[lastIndex] = .table(table)
            } else {
                var table = MarkdownTable(id: tableCell.tableID)
                table.setCell(
                    block.text,
                    rowID: tableCell.rowID,
                    column: tableCell.column,
                    columnCount: tableCell.columnCount,
                    isHeader: tableCell.isHeader
                )
                elements.append(.table(table))
            }
        }
        return elements
    }
}

private enum MarkdownElement: Identifiable {
    case block(MarkdownBlock)
    case table(MarkdownTable)

    var id: String {
        switch self {
        case .block(let block): "block-\(block.id)"
        case .table(let table): "table-\(table.id)"
        }
    }
}

private struct MarkdownBlock {
    let id: Int
    var text: AttributedString
    let intent: PresentationIntent?

    private var kinds: [PresentationIntent.Kind] {
        intent?.components.map(\.kind) ?? []
    }

    var headerLevel: Int? {
        for kind in kinds {
            if case .header(let level) = kind { return level }
        }
        return nil
    }

    var listOrdinal: Int? {
        for kind in kinds {
            if case .listItem(let ordinal) = kind { return ordinal }
        }
        return nil
    }

    var isOrderedListItem: Bool { kinds.contains(.orderedList) }
    var isUnorderedListItem: Bool { kinds.contains(.unorderedList) }
    var isBlockQuote: Bool { kinds.contains(.blockQuote) }

    var isCodeBlock: Bool {
        for kind in kinds {
            if case .codeBlock = kind { return true }
        }
        return false
    }

    var isThematicBreak: Bool { kinds.contains(.thematicBreak) }
    var indentationLevel: Int { intent?.indentationLevel ?? 0 }

    var tableCell: TableCell? {
        guard let intent else { return nil }
        var tableID: Int?
        var rowID: Int?
        var column: Int?
        var columnCount = 0
        var isHeader = false

        for component in intent.components {
            switch component.kind {
            case .table(let columns):
                tableID = component.identity
                columnCount = columns.count
            case .tableHeaderRow:
                rowID = component.identity
                isHeader = true
            case .tableRow:
                rowID = component.identity
            case .tableCell(let columnIndex):
                column = columnIndex
            default:
                break
            }
        }

        guard let tableID, let rowID, let column else { return nil }
        return TableCell(
            tableID: tableID,
            rowID: rowID,
            column: column,
            columnCount: columnCount,
            isHeader: isHeader
        )
    }
}

private struct TableCell {
    let tableID: Int
    let rowID: Int
    let column: Int
    let columnCount: Int
    let isHeader: Bool
}

private struct MarkdownTable: Identifiable {
    let id: Int
    var rows: [MarkdownTableRow] = []

    mutating func setCell(
        _ content: AttributedString,
        rowID: Int,
        column: Int,
        columnCount: Int,
        isHeader: Bool
    ) {
        if rows.last?.id != rowID {
            rows.append(MarkdownTableRow(
                id: rowID,
                columnCount: columnCount,
                isHeader: isHeader
            ))
        }
        guard let rowIndex = rows.indices.last,
              rows[rowIndex].cells.indices.contains(column) else { return }
        rows[rowIndex].cells[column] = content
    }
}

private struct MarkdownTableRow: Identifiable {
    let id: Int
    let isHeader: Bool
    var cells: [AttributedString]

    init(id: Int, columnCount: Int, isHeader: Bool) {
        self.id = id
        self.isHeader = isHeader
        cells = Array(repeating: AttributedString(), count: max(0, columnCount))
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    private var indentation: CGFloat {
        CGFloat(max(0, block.indentationLevel - 1)) * 16
    }

    private var headerFont: Font {
        switch block.headerLevel ?? 0 {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    var body: some View {
        if block.isThematicBreak {
            Divider().padding(.vertical, 4)
        } else if let headerLevel = block.headerLevel {
            Text(block.text)
                .font(headerFont)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, headerLevel == 1 ? 6 : 2)
        } else if let ordinal = block.listOrdinal {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(block.isOrderedListItem ? "\(ordinal)." : "•")
                    .frame(minWidth: 18, alignment: .trailing)
                Text(block.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, indentation)
        } else if block.isCodeBlock {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(.leading, indentation)
        } else if block.isBlockQuote {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(block.text)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, indentation)
        } else {
            Text(block.text)
                .font(.body)
                .textSelection(.enabled)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

struct DetailFactsView: View {
    let job: UpworkJob

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 12) {
            if let budget = job.budgetLabel {
                FactView(label: "Budget", value: budget)
            }
            if let category = job.category {
                FactView(label: "Category", value: category)
            }
            if let experience = job.experienceLevel {
                FactView(label: "Experience", value: experience)
            }
            if let applicants = job.proposalCountDisplay {
                FactView(label: "Proposals", value: applicants)
            }
            if !job.skillNames.isEmpty {
                FactView(label: "Skills", value: job.skillNames.joined(separator: ", "))
            }
        }
    }
}

struct ClientFactsView: View {
    let client: UpworkClient

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 12) {
            FactView(label: "Location", value: client.location?.displayName ?? "Not provided")
            FactView(
                label: "Rating",
                value: client.totalFeedback.map { String(format: "%.2f/5", $0) } ?? "Not provided"
            )
            FactView(label: "Reviews", value: client.totalReviews.map(String.init) ?? "Not provided")
            FactView(label: "Total contracts", value: client.totalContracts.map(String.init) ?? "Not provided")
            if let hires = client.totalHires {
                FactView(label: "Hires", value: String(hires))
            }
            FactView(label: "Posted jobs", value: client.totalPostedJobs.map(String.init) ?? "Not provided")
            FactView(
                label: "Total spent",
                value: client.hasFinancialPrivacy == true ? "Hidden" : (client.totalSpent?.formatted ?? "Not provided")
            )
            if let lastContract = client.latestContractTitle, !lastContract.isEmpty {
                FactView(label: "Latest contract", value: lastContract)
            }
        }
        if !client.reviews.isEmpty {
            let reviews = Array(client.reviews.prefix(8))
            VStack(alignment: .leading, spacing: 10) {
                Text("Client history")
                    .font(.subheadline.weight(.medium))
                ForEach(reviews.indices, id: \.self) { index in
                    let review = reviews[index]
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if let title = review.contractTitle { Text(title).fontWeight(.medium) }
                            Spacer()
                            if let score = review.score {
                                Label(String(format: "%.2f", score), systemImage: "star.fill")
                                    .foregroundStyle(.secondary)
                            }
                            if let date = review.date {
                                Text(date).foregroundStyle(.secondary)
                            }
                        }
                        if let comment = review.comment {
                            Text(comment).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                    .padding(.vertical, 6)
                    if index < reviews.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}

struct FactView: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
