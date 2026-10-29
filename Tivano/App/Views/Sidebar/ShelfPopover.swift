import SwiftUI

struct ShelfPopover<ProjectContent: View, ThreadContent: View>: View {
    @Environment(AppModel.self) private var model
    let maxHeight: CGFloat
    @Binding var revealThreadID: UUID?
    @ViewBuilder let projectRow: (Project, Int) -> ProjectContent
    @ViewBuilder let threadRow: (ChatThread) -> ThreadContent

    @State private var contentHeight: CGFloat = Chrome.rowHeight

    private var projects: [Project] { model.projects.filter(\.isShelved) }
    private func threads(in project: Project) -> [ChatThread] {
        let all = model.threads(in: project)
        return all.filter(\.isPinned) + all.filter { !$0.isPinned }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    if projects.isEmpty {
                        Text("No shelved projects")
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, Chrome.rowHorizontalPadding)
                            .frame(height: Chrome.rowHeight)
                    }
                    ForEach(projects) { project in
                        VStack(alignment: .leading, spacing: 1) {
                            projectRow(project, model.threads(in: project).count)
                            if project.isExpanded {
                                ForEach(threads(in: project)) { thread in
                                    threadRow(thread)
                                        .id(thread.id)
                                }
                            }
                        }
                        .padding(.bottom, project.id == projects.last?.id ? 0 : Chrome.groupGap)
                    }
                }
                .padding(Chrome.listInset)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            }
            .scrollIndicators(.never)
            .frame(height: min(contentHeight, maxHeight))
            .onChange(of: revealThreadID, initial: true) { _, id in
                guard let id else { return }
                // Wait for the expanded project's rows to enter the scroll view.
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(id, anchor: .center)
                    if revealThreadID == id { revealThreadID = nil }
                }
            }
        }
        .frame(width: 280)
    }
}
