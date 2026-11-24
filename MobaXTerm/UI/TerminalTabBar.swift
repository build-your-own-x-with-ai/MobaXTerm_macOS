import SwiftUI

struct TerminalTabBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Button {
                model.beginNewSession()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("新建会话")
            .padding(.trailing, 8)
        }
        .background(.bar)
    }

    private func tabButton(_ tab: TerminalTab) -> some View {
        let selected = tab.id == model.selectedTabID
        return HStack(spacing: 6) {
            Image(systemName: tab.kind.symbolName)
            Text(tab.title)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
                .accessibilityIdentifier(selected ? "tab.selected" : "tab.other")
                .accessibilityLabel(tab.title)
            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("关闭标签")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { model.selectedTabID = tab.id }
    }
}
