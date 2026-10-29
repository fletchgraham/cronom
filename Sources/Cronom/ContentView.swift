import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: TimerModel
    @AppStorage("showList") private var showList = true
    @State private var newTask = ""
    @State private var renaming: Int64?
    @State private var renameText = ""
    @FocusState private var addFocused: Bool

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
        return ScrollView {
            VStack(spacing: 2) {
                ForEach(open) { task in row(task) }
            }
        }
        .frame(height: min(CGFloat(open.count) * 26, 26 * 8))
        .scrollIndicators(.never)
    }

    private func row(_ task: TaskItem) -> some View {
        let active = task.id == model.activeTaskID
        return HStack(spacing: 6) {
            Button { model.markDone(task.id) } label: {
                Image(systemName: "circle")
            }
            .buttonStyle(IconButtonStyle(size: 11))
            .help("Mark done")

            if renaming == task.id {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        model.rename(task.id, to: renameText)
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                Text(task.name)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(duration(task.todaySeconds))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Today · \(duration(task.totalSeconds)) all time")
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
            Button("Rename") {
                renameText = task.name
                renaming = task.id
            }
            Button("Mark done") { model.markDone(task.id) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(task.id) }
        }
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
