import FoundationModels

@Generable enum GeneratedActionKind { case draft, remember, alarm }
@Generable enum GeneratedMemoryScope { case personal, company, industry }
@Generable struct GeneratedAction {
    var kind: GeneratedActionKind
    @Guide(description: "Short descriptive title, at most 100 characters.") var title: String
    @Guide(description: "The actual draft or proposed memory. At most 1000 characters for a memory, 2500 for a draft. For an alarm, a short purpose.") var content: String
    @Guide(description: "Only for an alarm: ISO8601 full date and time with explicit UTC offset. Otherwise nil. Ask a question instead if time is ambiguous.") var alarmTime: String?
    @Guide(description: "Memory category; use personal for non-memory actions.") var memoryScope: GeneratedMemoryScope
}

@Generable struct GeneratedPlan {
    @Guide(description: "Zero to three proposals. Empty for ordinary conversation, questions, or when facts are missing. Never propose an unsupported executable action.", .maximumCount(3))
    var actions: [GeneratedAction]
    @Guide(description: "Answer directly in one to three natural sentences, or ask one necessary question. Never claim proposals were executed or remembered.")
    var answer: String
    var domainPlan: CompanionPlan {
        .init(answer: answer, actions: actions.map { item in
            let kind: PlanAction = switch item.kind { case .draft: .draft; case .remember: .remember; case .alarm: .alarm }
            let scope = switch item.memoryScope { case .personal: "Personal"; case .company: "Company"; case .industry: "Industry" }
            return PlannedAction(kind: kind, title: item.title, content: item.content, alarmTime: item.alarmTime, memoryScope: scope)
        })
    }
}
