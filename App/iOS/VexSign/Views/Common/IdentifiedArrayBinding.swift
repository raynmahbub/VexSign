import SwiftUI

/// SwiftUI can read a row binding while its removal animation is still running.
/// Resolve each access by identity instead of retaining an array index that may
/// now refer to a different row (or be out of bounds).
enum IdentifiedArrayBinding {
    static func element<Element: Identifiable>(_ snapshot: Element, in elements: Binding<[Element]>) -> Binding<Element> {
        Binding(
            get: { elements.wrappedValue.first { $0.id == snapshot.id } ?? snapshot },
            set: { updated in
                var values = elements.wrappedValue
                guard let index = values.firstIndex(where: { $0.id == snapshot.id }) else { return }
                values[index] = updated
                elements.wrappedValue = values
            }
        )
    }
}
