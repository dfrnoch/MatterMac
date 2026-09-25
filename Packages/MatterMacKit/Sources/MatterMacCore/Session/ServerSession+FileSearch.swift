import Foundation
import MatterMacModels
import MattermostAPI

extension ServerSession {
    public func searchFiles(_ terms: String) {
        tasks[.search]?.cancel()
        releaseSearchResults()
        searchKind = .files
        searchState.generation &+= 1
        searchState.terms = String(terms.prefix(4_096)).trimmingCharacters(in: .whitespacesAndNewlines)
        searchState.page = 0
        searchState.canLoadMore = false
        searchState.isTruncated = false
        guard isActiveSessionAlive, !searchState.terms.isEmpty, let team = selectedTeam else {
            searchState.state = .idle
            markDirty(.search)
            return
        }
        runFileSearch(team: team, page: 0)
    }

    func runFileSearch(team: TeamID, page: Int) {
        let generation = searchState.generation, terms = searchState.terms
        let offset = deps.timeZone().secondsFromGMT()
        searchState.state = .searching
        markDirty(.search)
        run(.search) { session in
            let epoch = session.epoch
            do {
                let result = try await session.service.searchFiles(.init(team: team, terms: terms,
                    timeZoneOffsetSeconds: offset, page: page, perPage: Self.listPageSize))
                guard session.epoch == epoch, session.searchState.generation == generation, !Task.isCancelled else { return }
                var bytes = session.searchState.files.reduce(0) { $0 + Self.fileSearchCost($1) }
                var ids = Set(session.searchState.files.map(\.id))
                for var file in result.files where ids.insert(file.id).inserted && file.deleteAt == .zero {
                    file.miniPreview = nil
                    let cost = Self.fileSearchCost(file)
                    guard session.searchState.files.count < session.budget.searchResults.count,
                          bytes + cost <= session.budget.searchResults.bytes else {
                        session.searchState.isTruncated = true
                        break
                    }
                    session.searchState.files.append(file)
                    bytes += cost
                }
                session.searchState.isTruncated = session.searchState.isTruncated || session.searchState.files.count >= session.budget.searchResults.count
                session.searchState.canLoadMore = result.files.count >= Self.listPageSize && !session.searchState.isTruncated
                session.searchState.state = .results
                session.markDirty(.search)
            } catch {
                guard session.epoch == epoch, session.searchState.generation == generation else { return }
                session.handleAuthenticationFailureIfNeeded(error)
                session.searchState.state = .failed(Self.userFacing(error))
                session.markDirty(.search)
            }
        }
    }

    private static func fileSearchCost(_ file: FileInfo) -> Int {
        256 + file.name.utf8.count + file.fileExtension.utf8.count + file.mimeType.utf8.count
    }
}
