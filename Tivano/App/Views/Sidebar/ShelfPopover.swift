import SwiftUI

struct ShelfPopover<ProjectContent: View, ThreadContent: View>: View {
    @Environment(AppModel.self) private var model
    let maxHeight: CGFloat
    @Binding var revealThreadID: UUID?
    @ViewBuilder let projectRow: (Project, Int) -> ProjectContent
    @ViewBuilder let threadRow: (ChatThread) -> ThreadContent

    @State private var contentHeight: CGFloat = Chrome.rowHeight

    private func orderedThreads(_ threads: [ChatThread]) -> [ChatThread] {
        threads.filter(\.isPinned) + threads.filter { !$0.isPinned }
    }

    var body: some View {
        let projects = model.projects.filter(\.isShelved)
        let lastProjectID = projects.last?.id
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
                        let projectThreads = model.threads(in: project)
                        VStack(alignment: .leading, spacing: 1) {
                            projectRow(project, projectThreads.count)
                            if project.isExpanded {
                                ForEach(orderedThreads(projectThreads)) { thread in
                                    threadRow(thread)
                                        .id(thread.id)
                                }
                            }
                        }
                        .padding(.bottom, project.id == lastProjectID ? 0 : Chrome.groupGap)
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
