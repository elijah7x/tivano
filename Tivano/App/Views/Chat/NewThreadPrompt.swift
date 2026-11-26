import AppKit
import SwiftUI

/// The question and editable affiliation before a thread's first message.
struct NewThreadPrompt: View {
    @Environment(AppModel.self) private var model
    let threadID: UUID
    let projectName: String?

    @State private var isVisible = false
    @State private var isChoosingProject = false
    @State private var isMoving = false
    @State private var isHoveringName = false
    @FocusState private var isMenuFocused: Bool

    var body: some View {
        let affiliation = model.thread(threadID)?.affiliation
        VStack(spacing: 26) {
            HStack(spacing: 0) {
                if let affiliation, case .project = affiliation, let projectName, !projectName.isEmpty {
                    let question = Chrome.localizedAround("What should we build in %@?")
                    Text(verbatim: question.before)
                        .fixedSize(horizontal: true, vertical: false)
                    affiliationButton(projectName)
                    Text(verbatim: question.after)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text("What should we build?")
                }
            }
            .font(TypeScale.shared.serif ? Font(ThemeTypeface.nsFont(size: 28, weight: .regular) as CTFont) : .system(size: 28, weight: .regular))
            .foregroundStyle(Chrome.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            if affiliation == .standalone {
                affiliationButton(Chrome.localized("Work without a project"))
                    .font(.ui(.body))
            } else if projectName == nil {
                affiliationButton(Chrome.localized("Choose another project"))
                    .font(.ui(.body))
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.97)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { isVisible = true }
        }
    }

    private func affiliationButton(_ title: String) -> some View {
        Button {
            isChoosingProject.toggle()
        } label: {
            Text(verbatim: title)
                .foregroundStyle(Chrome.accent)
                .underline(true, pattern: .dot, color: Chrome.accent.opacity(isHoveringName ? 1 : 0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!model.canChangeThreadAffiliation(threadID))
        .onHover { isHoveringName = $0 }
        .help(Text(verbatim: title))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text("Choose thread location"))
        .popover(isPresented: $isChoosingProject, arrowEdge: .bottom) {
            projectChoices
                .focusable()
                .focused($isMenuFocused)
                .onAppear { isMenuFocused = true }
                .onExitCommand { isChoosingProject = false }
        }
    }

    private var projectChoices: some View {
        let current: ThreadAffiliation? = model.thread(threadID)?.affiliation
        let canMove: Bool = model.canChangeThreadAffiliation(threadID)
        let activeProjects: [Project] = model.projects.filter { (project: Project) -> Bool in !project.isShelved }
        let shelvedProjects: [Project] = model.projects.filter { (project: Project) -> Bool in project.isShelved }
        let orderedProjects: [Project] = activeProjects + shelvedProjects
        return PopoverMenu {
            PopoverItem("Work without a project", symbol: "bubble.left", isChecked: current == .standalone, isEnabled: canMove) {
                move(to: .standalone)
            }
            PopoverDivider()
            PopoverSectionHeader("Projects")
            ForEach(orderedProjects) { (project: Project) in
                projectChoiceRow(project, current: current, canMove: canMove)
            }
            PopoverDivider()
            PopoverItem("Add project…", symbol: "plus", isEnabled: canMove) {
                addProjectAndMove()
            }
        }
    }

    private func projectChoiceRow(_ project: Project, current: ThreadAffiliation?, canMove: Bool) -> some View {
        let iconView = AnyView(ProjectIconMark(icon: project.icon, size: 12))
        let isChecked: Bool = current == .project(project.id)
        return PopoverItem(project.name, leading: iconView, isChecked: isChecked, isEnabled: canMove) {
            move(to: .project(project.id))
        }
    }

    private func addProjectAndMove() {
        guard model.canChangeThreadAffiliation(threadID), let added: Project = model.addProjectsFromPanel() else { return }
        move(to: .project(added.id))
    }

    private func move(to affiliation: ThreadAffiliation) {
        guard !isMoving, let thread = model.thread(threadID), thread.affiliation != affiliation else { return }
        guard model.canChangeThreadAffiliation(threadID) else {
            model.alert = AppAlert(title: "Could not change thread location", message: Chrome.localized("Thread location can only be changed before the first message."))
            return
        }
        // The stored-history check reads the thread file off the main thread; a second
        // click while it runs is ignored.
        isMoving = true
        Task {
            defer { isMoving = false }
            let moved = await model.moveThreadAsync(threadID, to: affiliation, animation: Chrome.panelSlide)
            guard moved else {
                if model.alert == nil {
                    model.alert = AppAlert(title: "Could not change thread location", message: Chrome.localized("Thread location can only be changed before the first message."))
                }
                return
            }
            model.terminals.closeAll(for: threadID)
            isChoosingProject = false
        }
    }
}
