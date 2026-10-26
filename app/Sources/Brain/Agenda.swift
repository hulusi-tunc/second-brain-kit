import EventKit
import Foundation

/// Your calendar, from macOS Calendar (add your Google or Microsoft account in System Settings,
/// Internet Accounts): the prep before a call, and the title and names on a recorded call's note.
/// Read only. Asks for access once, the first time it is needed.
enum Agenda {
  struct Event: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let names: [String]       // everyone but you
  }

  private static let store = EKEventStore()
  private static var asked = false

  /// Events that are not declined and overlap [from, to].
  static func events(from: Date, to: Date) -> [Event] {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: break
    case .notDetermined:
      if !asked { asked = true; store.requestFullAccessToEvents { _, _ in } }
      return []
    default: return []
    }
    let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
    return store.events(matching: pred).filter { e in
      !e.isAllDay && e.status != .canceled &&
        !(e.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }.map { e in
      Event(id: e.calendarItemExternalIdentifier ?? e.eventIdentifier, title: e.title ?? "Call", start: e.startDate, end: e.endDate,
            names: (e.attendees ?? []).filter { !$0.isCurrentUser && $0.participantType == .person }
              .compactMap { $0.name }.filter { !$0.contains("@") && $0 != Config.me })
    }.sorted { $0.start < $1.start }
  }

  /// The next call with someone, starting within `minutes`.
  static func next(within minutes: Double, now: Date = Date()) -> Event? {
    events(from: now, to: now.addingTimeInterval(minutes * 60)).first { $0.start > now && !$0.names.isEmpty }
  }

  /// The event a call that starts now most likely is: started up to 15 min ago or starting within 10.
  static func current(now: Date = Date()) -> Event? {
    events(from: now.addingTimeInterval(-15 * 60), to: now.addingTimeInterval(10 * 60))
      .filter { $0.start <= now.addingTimeInterval(10 * 60) && $0.end >= now }
      .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
  }

  /// "Sam", "Sam and Alex", "Sam and 3 others"
  static func who(_ e: Event) -> String {
    let first = e.names.map { String($0.split(separator: " ").first ?? Substring($0)) }
    switch first.count {
    case 0: return e.title
    case 1: return first[0]
    case 2: return "\(first[0]) and \(first[1])"
    default: return "\(first[0]) and \(first.count - 1) others"
    }
  }
}
