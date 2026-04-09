import Foundation
import SwiftData

@Model
final class Course {
    @Attribute(.unique) var id: String
    var name: String
    var type: String

    init(id: String, name: String, type: String = "course") {
        self.id = id
        self.name = name
        self.type = type
    }
}
