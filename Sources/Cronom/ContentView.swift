import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: TimerModel
    @AppStorage("showList") private var showList = true
    @State private var newTask = ""
    @State private var editing: Editing?
    @State private var editText = ""
    @FocusState private var addFocused: Bool
    @FocusState private var editFocused: Bool

    /// Inline edit of a task's name or today's logged time.
    struct Editing: Equatable {
        enum Field { case name, time }
        let id: Int64
        let field: Field
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            timerRow
            if showList {
                Divider().padding(.vertical, 2)
                taskList
                addField
                Divider().padding(.vertical, 2)
                footer
            }
        }
        .padding(12)
        .frame(width: 260)
        .background(
            VisualEffect()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(model.activeTask?.name ?? "No task — add one")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(model.activeTask == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showList.toggle() }
            } label: {
                Image(systemName: showList ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(IconButtonStyle(size: 11))
            .help(showList ? "Collapse" : "Show tasks")
        }
    }

    private var timerRow: some View {
        HStack(spacing: 4) {
            Text(clock(model.remaining))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(timerColor)
                .phaseAnimator([false, true], trigger: model.phase == .expired) { view, dim in
                    view.opacity(model.phase == .expired && dim ? 0.35 : 1)
                }
                .onTapGesture { if model.phase == .idle { showList = true } }
            Spacer()
            Button(action: model.toggle) {
                Image(systemName: model.phase == .running ? "pause.fill" : "play.fill")
            }
            .buttonStyle(IconButtonStyle(size: 15))
            .disabled(model.activeTaskID == nil)
            .help(model.phase == .running ? "Pause" : "Start")

            Button(action: model.next) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(IconButtonStyle(size: 15, prominent: model.phase == .expired))
            .disabled(model.openTasks.count < 2 && model.phase != .expired)
            .help("Next task")

            Button(action: model.reset) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(IconButtonStyle(size: 13))
            .help("Reset timer")
        }
    }

    private var taskList: some View {
        let open = model.openTasks
        return List {
            ForEach(open) { task in
                row(task)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .onMove { from, to in
                var ids = open.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                model.reorder(ids)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .environment(\.defaultMinListRowHeight, 26)
        .frame(height: min(CGFloat(open.count) * 26, 26 * 8))
        .padding(.horizontal, -8) // cancel the List's built-in row inset
    }

    private func row(_ task: TaskItem) -> some View {
        let active = task.id == model.activeTaskID
        return HStack(spacing: 6) {
            Button { model.markDone(task.id) } label: {
                Image(systemName: "circle")
            }
            .buttonStyle(IconButtonStyle(size: 11))
            .help("Mark done")

            if editing == Editing(id: task.id, field: .name) {
                inlineField {
                    model.rename(task.id, to: editText)
                }
            } else {
                Text(task.name)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if editing == Editing(id: task.id, field: .time) {
                inlineField {
                    if let seconds = parseDuration(editText) {
                        model.setTodayTime(task.id, seconds: seconds)
                    }
                }
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            } else {
                Text(duration(task.todaySeconds))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Today · \(duration(task.totalSeconds)) all time")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.22) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(task.id) }
        .contextMenu {
            Button("Rename") { beginEdit(task.id, .name, text: task.name) }
            Button("Edit time today…") { beginEdit(task.id, .time, text: duration(task.todaySeconds)) }
            Button("Mark done") { model.markDone(task.id) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(task.id) }
        }
    }

    private func inlineField(commit: @escaping () -> Void) -> some View {
        TextField("", text: $editText)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($editFocused)
            .onSubmit {
                commit()
                editing = nil
            }
            .onExitCommand { editing = nil }
    }

    private func beginEdit(_ id: Int64, _ field: Editing.Field, text: String) {
        editText = text
        editing = Editing(id: id, field: field)
        DispatchQueue.main.async { editFocused = true }
    }

    private var addField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField("New task", text: $newTask)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($addFocused)
                .onSubmit {
                    model.addTask(newTask)
                    newTask = ""
                    addFocused = true
                }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("Today \(duration(model.todayTotal))")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(model.durationMinutes) min")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Stepper("", value: $model.durationMinutes, in: 1...240, step: 5)
                .labelsHidden()
                .controlSize(.mini)
                .help("Timer length")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle(size: 11))
            .help("Quit Cronom")
        }
    }

    // MARK: Helpers

    private var statusColor: Color {
        switch model.phase {
        case .running: .green
        case .paused: .orange
        case .expired: .red
        case .idle: .secondary.opacity(0.5)
        }
    }

    private var timerColor: Color {
        switch model.phase {
        case .running: .primary
        case .expired: .red
        case .idle, .paused: .secondary
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Accepts "45", "45m", "1h", "1h 30m", "1:30". Bare numbers are minutes.
    private func parseDuration(_ text: String) -> Double? {
        let s = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let colon = s.firstIndex(of: ":") {
            guard let h = Double(s[..<colon]), let m = Double(s[s.index(after: colon)...]) else { return nil }
            return (h * 60 + m) * 60
        }
        if let m = Double(s) { return m * 60 }
        func number(before unit: String) -> Double? {
            let re = try! Regex("(\\d+(?:\\.\\d+)?)\\s*\(unit)")
            return s.firstMatch(of: re).flatMap { $0.output[1].substring }.flatMap { Double($0) }
        }
        let hours = number(before: "h")
        let mins = number(before: "m")
        guard hours != nil || mins != nil else { return nil }
        return ((hours ?? 0) * 60 + (mins ?? 0)) * 60
    }

    private func duration(_ t: Double) -> String {
        let m = Int(t) / 60
        return m >= 60 ? String(format: "%dh %02dm", m / 60, m % 60) : "\(m)m"
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .frame(width: size + 14, height: size + 14)
            .background(
                Circle().fill(
                    prominent ? Color.accentColor
                    : Color.primary.opacity(configuration.isPressed ? 0.15 : 0.0001)
                )
            )
            .opacity(isEnabled ? 1 : 0.3)
            .contentShape(Circle())
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
