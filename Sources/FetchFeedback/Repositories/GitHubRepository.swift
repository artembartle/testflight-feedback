import Foundation
import Utils

final class GitHubRepository {

    private var milestones: [Milestone] = []

    init() async throws {
        milestones = try await fetchMilestones()
    }

    // MARK: - Static Methods

    static func getLastIssueTimestamp() async throws -> Date? {
        let tickets: [IssueResponse] = try await GitHubHelper.fetchLatestIssues()
        let lastTicketTimestamp = tickets
            .compactMap(\.appStoreConnectCreationDate)
            .max()

        if let date = lastTicketTimestamp {
            print([
                .init(text: "Last ticket is based on feedback from: ", color: .cyan),
                .init(text: DateFormatter.readable.string(from: date), color: .cyan, bold: true)
            ])
        }
        return lastTicketTimestamp
    }

    // MARK: - Issues

    /// - creates milestone if required, otherwise reuses existing one
    /// - adds screenshots to repository if present
    /// - creates an issue from feedback
    func setupIssue(feedback: Feedback) async throws {
        let milestone = try await dequeueMilestone(title: feedback.appVersionString)
        let screenshots = try await addScreenshotsToRepository(feedback.screenshotURLs,
                                                               timestamp: feedback.attributes.timestamp)
        let issue = try Issue(from: feedback, milestoneNumber: milestone.number, screenshots: screenshots)
        _ = try await createIssue(issue)
    }

    private func createIssue(_ issue: Issue) async throws -> IssueResponseModel {
        let request = try URLRequest(url: try GitHubHelper.issuesURL(), method: .post, body: issue)

        print([
            .init(text: "Creating ticket: ", color: .yellow),
            .init(text: issue.title, color: .yellow, bold: true)
        ])

        return try await GitHubNetworking.perform(dataRequest: request)
    }

    // MARK: - Milestones

    private func dequeueMilestone(title: String) async throws -> Milestone {
        if let milestone = milestones.first(where: { $0.title == title }) {
            return milestone
        } else {
            let milestone = try await createMilestone(title)
            print("Milestone created successfully: \(milestone)", color: .green)
            milestones.append(milestone)
            return milestone
        }
    }

    private func createMilestone(_ title: String) async throws -> Milestone {
        let milestone = Milestone(number: nil, title: title)
        let request = try URLRequest(url: try milestonesURL(), method: .post, body: milestone)

        print([
            .init(text: "Creating milestone: ", color: .yellow),
            .init(text: title, color: .yellow, bold: true)
        ])

        return try await GitHubNetworking.perform(dataRequest: request, decoder: .decoderWithoutMiliseconds)
    }

    private func fetchMilestones() async throws -> [Milestone] {
        print("Fetching milestones..", color: .yellow)
        var milestones: [Milestone] = []
        var page = 1

        while true {
            let request = URLRequest(url: try listMilestonesURL(page: page))
            let milestonesOnPage: [Milestone] = try await GitHubNetworking.perform(dataRequest: request, decoder: .decoderWithoutMiliseconds)
            if milestonesOnPage.isEmpty {
                break
            }
            milestones += milestonesOnPage
            page += 1
        }

        return milestones
    }

    // MARK: - Screenshots

    private func addScreenshotsToRepository(_ screenshots: [ImageReference], timestamp: Date) async throws -> [ImageReference] {
        var uploadedScreenshots: [ImageReference] = []
        for enumeration in screenshots.enumerated() {
            let fileName = "\(DateFormatter.iso8601.string(from: timestamp))_\(enumeration.offset)"
            let uploadedThumbnailURL = try await uploadScreenshotToRepository(enumeration.element.thumbnailURL, fileName: fileName + "-thumbnail")
            let uploadedScreenshotURL = try await uploadScreenshotToRepository(enumeration.element.url, fileName: fileName)
            uploadedScreenshots.append(.init(thumbnailURL: uploadedThumbnailURL, url: uploadedScreenshotURL))
        }
        return uploadedScreenshots
    }

    private func uploadScreenshotToRepository(_ imageURL: URL, fileName: String) async throws -> URL {
        let (imageData, _) = try await URLSession.shared.data(for: URLRequest(url: imageURL))
        let body = RepositoryContentBody(message: "Adding screenshot \(fileName)",
                                         content: imageData.base64EncodedString())
        let request = try URLRequest(url: try GitHubHelper.screenshotsFolderURL().appendingPathComponent(fileName + ".jpg"), method: .put, body: body)
        let response: RepositoryContentResponseModel = try await GitHubNetworking.perform(dataRequest: request)
        var components = URLComponents(url: response.content.html_url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "raw", value: "true")
        ]
        return components.url!
    }
}

private extension GitHubRepository {

    func projectColumnCardURL(columnId: Int) -> URL {
        GitHubHelper.apiURL.appendingPathComponent("projects/columns/\(columnId)/cards")
    }

    func milestonesURL() throws -> URL {
        let urlComponents = URLComponents(url: try GitHubHelper.repositoryURL().appendingPathComponent("milestones"), resolvingAgainstBaseURL: false)!
        guard let url = urlComponents.url else { throw GitHubError.badURL(message: urlComponents.description) }
        return url
    }

    func listMilestonesURL(page: Int) throws -> URL {
        guard page > 0 else { throw GitHubError.wrongPageNumber(page: page) }

        var urlComponents = URLComponents(url: try milestonesURL(), resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [
            .init(name: "page", value: String(page)),
            .init(name: "per_page", value: "100")
        ]
        guard let url = urlComponents.url else { throw GitHubError.badURL(message: urlComponents.description) }
        return url
    }
}
