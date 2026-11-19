import SwiftUI

// SDK 27 introduces a same-named State macro whose plugin is absent from the
// standalone Command Line Tools. A type-only alias selects the established
// property wrapper and keeps deployment compatibility with macOS 14.
typealias ViewState<Value> = SwiftUI.State<Value>
