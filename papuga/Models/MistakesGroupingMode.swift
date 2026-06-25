import Foundation

/// How the "Усі помилки" browser organises the full open-mistake set (design node 634:2,
/// prototypes/all-errors/index.html). Switched via the `ГРУПУВАТИ` control in the header.
enum MistakesGroupingMode: String, CaseIterable, Identifiable {
    case byApp      // за застосунком — де ти найбільше помиляєшся
    case inbox      // плаский список за частотою
    case families   // родини схожих описок (edit-distance + спільна ціль)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .byApp: return "за застосунком"
        case .inbox: return "інбокс"
        case .families: return "родини"
        }
    }

    var systemImage: String {
        switch self {
        case .byApp: return "macwindow.on.rectangle"
        case .inbox: return "list.bullet"
        case .families: return "square.stack.3d.up"
        }
    }
}
