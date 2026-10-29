import AppKit
import Combine

/// The countdown is a timebox on the active task. Switching tasks while the
/// clock is live (running or just expired) starts a fresh countdown on the new
/// task; time is only attributed while running.
@MainActor
final class TimerModel: ObservableObject {
    enum Phase { case idle, running, paused, expired }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remaining: TimeInterval
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var activeTaskID: Int64? {
        didSet { UserDefaults.standard.set(activeTaskID.map { Int($0) }, forKey: "activeTaskID") }
    }
    @Published var durationMinutes: Int {
        didSet {
            durationMinutes = min(max(durationMinutes, 1), 240)
            UserDefaults.standard.set(durationMinutes, forKey: "durationMinutes")
            if phase == .idle { remaining = duration }
        }
    }

    var duration: TimeInterval { TimeInterval(durationMinutes * 60) }
    var openTasks: [TaskItem] { tasks.filter { !$0.done } }
    var activeTask: TaskItem? { tasks.first { $0.id == activeTaskID } }
    var todayTotal: Double { tasks.reduce(0) { $0 + $1.todaySeconds } }

    private let db: Database
    private var endDate: Date?
    private var segmentID: Int64?
    private var ticker: Timer?
    private var alarmTimer: Timer?

    init(db: Database) {
        self.db = db
        let stored = UserDefaults.standard.integer(forKey: "durationMinutes")
        durationMinutes = stored > 0 ? stored : 20
        remaining = TimeInterval((stored > 0 ? stored : 20) * 60)
        if let id = UserDefaults.standard.object(forKey: "activeTaskID") as? Int {
            activeTaskID = Int64(id)
        }
        reload()
        if activeTask?.done ?? true { activeTaskID = openTasks.first?.id }

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker!, forMode: .common)

        // Don't credit time spent asleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if self?.phase == .running { self?.pause() } }
        }
    }

    // MARK: Timer controls

    func toggle() {
        phase == .running ? pause() : start()
    }

    func start() {
        guard let taskID = activeTaskID else { return }
        stopAlarm()
        if phase == .idle || phase == .expired { remaining = duration }
        let now = Date()
        endDate = now.addingTimeInterval(remaining)
        segmentID = db.startSegment(taskID: taskID, at: now)
        phase = .running
    }

    func pause() {
        guard phase == .running, let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        closeSegment(at: Date())
        phase = .paused
    }

    func reset() {
        stopAlarm()
        closeSegment(at: Date())
        remaining = duration
        phase = .idle
    }

    /// Advance to the next open task (wrapping), keeping the clock live if it was.
    func next() {
        let open = openTasks
        guard !open.isEmpty else { return }
        let idx = open.firstIndex { $0.id == activeTaskID } ?? -1
        select(open[(idx + 1) % open.count].id)
    }

    func select(_ id: Int64) {
        let live = phase == .running || phase == .expired
        if id == activeTaskID && phase == .running { return }
        stopAlarm()
        closeSegment(at: Date())
        activeTaskID = id
        remaining = duration
        phase = .idle
        if live { start() }
        reload()
    }

    // MARK: Tasks

    func addTask(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let id = db.addTask(name: name)
        if activeTaskID == nil { activeTaskID = id }
        reload()
    }

    func rename(_ id: Int64, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        db.rename(id, to: name)
        reload()
    }

    func reorder(_ ids: [Int64]) {
        db.reorder(ids)
        reload()
    }

    /// Set today's logged time on a task by recording the difference as a correction.
    func setTodayTime(_ id: Int64, seconds: Double) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        let delta = max(0, seconds) - task.todaySeconds
        guard abs(delta) >= 1 else { return }
        db.addAdjustment(taskID: id, seconds: delta)
        reload()
    }

    func markDone(_ id: Int64) {
        if id == activeTaskID {
            let others = openTasks.filter { $0.id != id }
            if others.isEmpty {
                reset()
                activeTaskID = nil
            } else {
                next()
            }
        }
        db.setDone(id, true)
        reload()
    }

    func delete(_ id: Int64) {
        if id == activeTaskID {
            reset()
            activeTaskID = nil
        }
        db.deleteTask(id)
        reload()
        if activeTaskID == nil { activeTaskID = openTasks.first?.id }
    }

    // MARK: Internals

    private func tick() {
        guard phase == .running, let endDate else { return }
        let now = Date()
        remaining = max(0, endDate.timeIntervalSince(now))
        if remaining <= 0 {
            closeSegment(at: endDate)
            phase = .expired
            soundAlarm()
        } else if let segmentID {
            db.updateSegment(segmentID, end: now)
        }
        reload()
    }

    private func closeSegment(at date: Date) {
        if let segmentID { db.updateSegment(segmentID, end: date) }
        segmentID = nil
        endDate = nil
    }

    private func reload() {
        tasks = db.tasks(dayStart: Calendar.current.startOfDay(for: Date()))
    }

    private func soundAlarm() {
        var count = 0
        let play = { _ = NSSound(named: "Glass")?.play() }
        play()
        alarmTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
            count += 1
            play()
            if count >= 4 {
                t.invalidate()
                MainActor.assumeIsolated { self?.alarmTimer = nil }
            }
        }
    }

    private func stopAlarm() {
        alarmTimer?.invalidate()
        alarmTimer = nil
    }
}
