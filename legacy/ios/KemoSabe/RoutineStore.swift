import SwiftUI
import Observation
#if os(iOS)
import AlarmKit
#endif

@MainActor @Observable final class RoutineStore {
    private(set) var state = RoutineDocument()
    private(set) var error: String?
    private(set) var busy = false
    private let ledger: RoutineLedger
    init(ledger: RoutineLedger = .shared) { self.ledger = ledger }
    func refresh() async {
        do { state = try await ledger.snapshot(); error = nil }
        catch { self.error = "Routine storage couldn’t be read. Nothing was replaced." }
    }
    func setEnabled(_ enabled: Bool) async {
        await run { try await self.ledger.setEnabled(enabled) }
        #if os(iOS)
        if error == nil { enabled ? RoutineBackground.schedule() : RoutineBackground.cancel() }
        #endif
    }
    func goodnight() async {
        await run { try await self.ledger.recordBedtime(Date()) }
    }
    func setLearning(_ value: Bool, store: AppStore) async {
        store.cancel(); store.cancelStandup()
        await run { try await self.ledger.setLearning(value) }
        #if os(iOS)
        if error == nil { value ? RoutineBackground.schedule() : RoutineBackground.cancel() }
        #endif
    }
    func checkpoint() async {
        do {
            try await ledger.refreshContext(now: Date())
            let latest = try await ledger.snapshot()
            #if os(iOS)
            if latest.context?.learning == true && latest.context?.observations.isEmpty == false { RoutineBackground.schedule() }
            #endif
        } catch { /* A later foreground refresh surfaces storage errors. */ }
    }
    func forgetContext(store: AppStore) async {
        store.cancel(); store.cancelStandup()
        await run { try await self.ledger.clearContext() }
    }
    func morning() async {
        await run {
            try await self.ledger.recordWake(Date())
            try await self.ledger.prepareMorning(now: Date())
        }
    }
    func proposeAlarm(_ date: Date) async {
        await run {
            guard date > Date(), date.timeIntervalSinceNow < 7*86400 else { throw RoutineError.unavailable }
            try await self.ledger.propose(.init(key: "alarm:\(date.timeIntervalSince1970)", kind: .alarm,
                title: "Wake-up alarm", body: "Set a KemoSabe alarm for \(date.formatted(date: .abbreviated, time: .shortened)). Existing alarms stay unchanged.",
                scheduledAt: date, createdAt: Date(), expiresAt: date))
        }
    }
    func reject(_ proposal: RoutineProposal) async { await run { try await self.ledger.reject(id: proposal.id) } }
    func dismissUncertain(_ proposal: RoutineProposal) async { await run { try await self.ledger.dismissUncertain(id: proposal.id, now: Date()) } }
    func clearHistory() async { await run { try await self.ledger.clearHistory(now: Date()) } }
    func remove(_ proposal: RoutineProposal) async { await run { try await self.ledger.removePrepared(id: proposal.id) } }
    func review(_ proposal: RoutineProposal, store: AppStore) async {
        guard [.draft, .memory].contains(proposal.kind) else { return }
        await run {
            guard let prepared = try await self.ledger.snapshot().proposals.first(where: {
                $0.id == proposal.id && $0.status == .needsReview && $0.digest == proposal.digest
            }) else { throw RoutineError.stale }
            try ActionGate.requireCurrent(deadline: prepared.expiresAt, valid: prepared.origin?.isCurrent(in: store.state.memories) != false)
            if let sources = prepared.origin?.connectorSources, !sources.isEmpty {
                try await store.validateConnectorProvenance(sources, now: Date())
            }
            try await self.ledger.approve(id: prepared.id, digest: prepared.digest, now: Date())
            let claimed = try await self.ledger.claim(id: prepared.id, now: Date())
            do {
                guard claimed.origin?.isCurrent(in: store.state.memories) != false else { throw PlanningError.changedContext }
                if claimed.kind == .memory { try store.keepApprovedMemory(claimed) }
                try await self.ledger.finish(id: claimed.id, receipt: claimed.kind == .memory ? "Saved to memory" : "Reviewed · not sent", now: Date())
            } catch {
                try? await self.ledger.finish(id: claimed.id, receipt: nil, now: Date())
                throw error
            }
        }
    }
    func executeNative(_ proposal: RoutineProposal, store: AppStore) async {
        await run {
            _ = try await store.dailyAssistant.runner.run(id: proposal.id, reviewedDigest: proposal.digest)
            if let features = proposal.preferenceFeatures {
                try? await store.dailyAssistant.preferences.record(.init(id: UUID(), sourceID: proposal.id, features: features, feedback: .accepted, createdAt: Date()))
            }
        }
    }
    func rejectNative(_ proposal: RoutineProposal, store: AppStore) async {
        await run {
            try await self.ledger.reject(id: proposal.id)
            if let features = proposal.preferenceFeatures {
                try? await store.dailyAssistant.preferences.record(.init(id: UUID(), sourceID: proposal.id, features: features, feedback: .rejected, createdAt: Date()))
            }
        }
    }
    #if os(iOS)
    func cancelAlarm(_ proposal: RoutineProposal) async {
        guard proposal.kind == .alarm else { return }
        await run {
            try AlarmManager.shared.cancel(id: proposal.id)
            guard try !AlarmManager.shared.alarms.contains(where: { $0.id == proposal.id }) else { throw RoutineError.unavailable }
            try await self.ledger.recordAlarmCancellation(id: proposal.id)
        }
    }
    func approveAlarm(_ proposal: RoutineProposal, store: AppStore) async {
        // Only this typed adapter is implemented. Email/music/peer proposals cannot
        // fall through to a generic tool executor or claim to have been sent.
        guard proposal.kind == .alarm, let date = proposal.scheduledAt else { return }
        await run {
            guard let prepared = try await self.ledger.snapshot().proposals.first(where: {
                $0.id == proposal.id && $0.status == .needsReview && $0.digest == proposal.digest && $0.kind == .alarm
            }), let preparedDate = prepared.scheduledAt, preparedDate == date else { throw RoutineError.stale }
            try ActionGate.requireCurrent(deadline: prepared.expiresAt, valid: prepared.origin?.isCurrent(in: store.state.memories) != false)
            guard try await AlarmManager.shared.requestAuthorization() == .authorized else { throw RoutineError.unavailable }
            guard prepared.origin?.isCurrent(in: store.state.memories) != false else { throw PlanningError.changedContext }
            if let sources = prepared.origin?.connectorSources, !sources.isEmpty {
                try await store.validateConnectorProvenance(sources, now: Date())
            }
            try await self.ledger.approve(id: prepared.id, digest: prepared.digest, now: Date())
            _ = try await self.ledger.claim(id: prepared.id, now: Date())
            do {
                let alert = AlarmPresentation.Alert(title: "Morning with \(CompanionIdentity.name)", stopButton: .init(text: "Stop", textColor: .white, systemImageName: "stop.fill"),
                    secondaryButton: .init(text: "Open KemoSabe", textColor: .white, systemImageName: "sun.max"), secondaryButtonBehavior: .custom)
                let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert), metadata: KemoAlarmMetadata(), tintColor: store.state.theme.accentColor)
                _ = try await AlarmManager.shared.schedule(id: prepared.id, configuration: .alarm(schedule: .fixed(preparedDate), attributes: attributes, secondaryIntent: OpenKemoMorning()))
                let verified = try AlarmManager.shared.alarms.contains { $0.id == prepared.id }
                try await self.ledger.finish(id: prepared.id, receipt: verified ? "Scheduled with Apple AlarmKit" : nil, now: Date())
            } catch {
                try? await self.ledger.finish(id: prepared.id, receipt: nil, now: Date())
                throw error
            }
        }
    }
    #endif
    private func run(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await operation(); state = try await ledger.snapshot(); error = nil }
        catch { self.error = "That step couldn’t be confirmed. Check permissions and the proposal before retrying."; state = (try? await ledger.snapshot()) ?? state }
    }
}
