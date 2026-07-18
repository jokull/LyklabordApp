//
//  Autocomplete+ToolbarItem.swift
//  KeyboardKit
//
//  Created by Daniel Saidi on 2021-03-18.
//  Copyright © 2021-2025 Daniel Saidi. All rights reserved.
//

import SwiftUI

public extension Autocomplete {
    
    /// This view mimics a native autocomplete toolbar item.
    ///
    /// You can style this component with the style modifier
    /// ``autocompleteToolbarItemStyle(_:)``.
    struct ToolbarItem: View {
        
        /// Create an autocomplete toolbar item.
        ///
        /// - Parameters:
        ///   - suggestion: The suggestion to display.
        public init(
            suggestion: Autocomplete.Suggestion
        ) {
            self.suggestion = suggestion
        }

        private typealias Style = Autocomplete.ToolbarItemStyle

        private let suggestion: Suggestion

        @Environment(\.autocompleteToolbarItemStyle)
        private var style

        @Environment(\.truncationMode)
        private var truncationMode

        public var body: some View {
            contentPlaceholder
                .opacity(0)
                .overlay(contentStack) // Limit multiline height
                .padding(.horizontal, style.horizontalPadding)
                .padding(.vertical, style.verticalPadding)
                .background(style.backgroundColor)
                .background(Color.clearInteractable)
                .cornerRadius(style.backgroundCornerRadius)

        }
    }

    /// This style can be used to modify the visual style of
    /// the ``Autocomplete/ToolbarItem`` component.
    ///
    /// You can apply this view style with the view modifier
    /// ``SwiftUICore/View/autocompleteToolbarItemStyle(_:)``.
    ///
    /// You can use the ``standard`` style or your own style.
    struct ToolbarItemStyle: KeyboardModel {

        /// Create a custom autocomplete toolbar item style.
        ///
        /// - Parameters:
        ///   - titleColor: The title color to use, by default `.primary`.
        ///   - titleFont: The title font to use, by default `.body`.
        ///   - subtitleColor: The subtitle color to use, by default `.primary`.
        ///   - subtitleFont: The subtitle font to use, by default `.footnote`.
        ///   - horizontalPadding: The horizontal padding to apply, by default `4`.
        ///   - verticalPadding: The vertical padding to apply, by default `10`.
        ///   - backgroundColor: The background color to use, by default `.clear`.
        ///   - backgroundCornerRadius: The background color to use, by default `6`.
        public init(
            titleColor: Color = .primary,
            titleFont: KeyboardFont = .body,
            subtitleColor: Color = .primary,
            subtitleFont: KeyboardFont = .footnote,
            horizontalPadding: Double = 2,
            verticalPadding: Double = 10,
            backgroundColor: Color = .clear,
            backgroundCornerRadius: CGFloat = 4
        ) {
            self.titleFont = titleFont
            self.titleColor = titleColor
            self.subtitleFont = subtitleFont
            self.subtitleColor = subtitleColor
            self.horizontalPadding = horizontalPadding
            self.verticalPadding = verticalPadding
            self.backgroundColor = backgroundColor
            self.backgroundCornerRadius = backgroundCornerRadius
        }

        /// The title font to use.
        public var titleFont: KeyboardFont

        /// The title color to use.
        public var titleColor: Color

        /// The subtitle font to use.
        public var subtitleFont: KeyboardFont

        /// The subtitle color to use.
        public var subtitleColor: Color

        /// The horizontal padding to apply.
        public var horizontalPadding: Double

        /// The vertical padding to apply.
        public var verticalPadding: Double

        // The background color to use.
        public var backgroundColor: Color

        // The background color to use.
        public var backgroundCornerRadius: CGFloat
    }
}

private extension Autocomplete.ToolbarItem {

    var contentPlaceholder: some View {
        Text("X")
            .font(style.titleFont.font)
            .frame(maxWidth: .infinity)
    }

    var contentStack: some View {
        VStack(alignment: .center, spacing: 0) {
            titleText
            subtitle
        }
    }

    var title: some View {
        Text(suggestion.title)
            .lineLimit(1)
            .font(style.titleFont.font)
            .foregroundColor(style.titleColor)
    }

    @ViewBuilder
    var titleText: some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            ViewThatFits {
                title
                ScrollView(.horizontal) {
                    title.padding(.horizontal, 5)
                }
                .scrollIndicators(.hidden)
                .mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.05),
                            .init(color: .black, location: 0.95),
                            .init(color: .clear, location: 1.0)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
        } else {
            title
        }
    }
    
    @ViewBuilder
    var subtitle: some View {
        if let subtitle = suggestion.subtitle {
            Text(subtitle)
                .lineLimit(1)
                .font(style.subtitleFont.font)
                .foregroundColor(style.subtitleColor)
        }
    }
}

public extension Autocomplete.ToolbarItemStyle {

    /// The standard autocomplete toolbar item style.
    static var standard: Self { .init() }

    /// The autocomplete toolbar style for the space-committable
    /// (autocorrect-armed) candidate.
    ///
    /// FORK PATCH (Lyklaborð — issue #1, "mark the candidate space commits"):
    /// Lyklaborð deliberately under-corrects, so a #1-ranked candidate that has
    /// NOT cleared the auto-apply gate looks identical to one that has — users
    /// tap space expecting a commit and just get a space. iOS/SwiftKey/Gboard
    /// all mark the space-committable candidate (filled/tinted bubble + bold);
    /// upstream's subtle `.white.opacity(0.5)` wash is invisible in light mode
    /// and too weak in dark. Draw it as a filled accent pill with bold white
    /// text instead. Semantic colors only (`.accentColor` / `.white`) so it
    /// reads in light AND dark and scales with Dynamic Type. Visual only — the
    /// autocorrect FLAG (which suggestion space applies) is unchanged.
    static var standardAutocorrect: Self {
        .init(
            titleColor: .white,
            titleFont: .init(.body, .bold),
            backgroundColor: .accentColor,
            backgroundCornerRadius: 8
        )
    }
}

public extension View {

    /// Apply a ``Autocomplete/ToolbarItemStyle``.
    func autocompleteToolbarItemStyle(
        _ style: Autocomplete.ToolbarItemStyle
    ) -> some View {
        self.environment(\.autocompleteToolbarItemStyle, style)
    }
}

public extension EnvironmentValues {

    /// Apply a ``Autocomplete/ToolbarItemStyle``.
    @Entry var autocompleteToolbarItemStyle = Autocomplete
        .ToolbarItemStyle.standard

    /// FORK PATCH (Lyklaborð wave 37 — long-press to eject learned
    /// vocabulary): the affordance the toolbar uses to let a user forget a
    /// word their own personal vocabulary learned. `nil` (the default) keeps
    /// upstream behavior — suggestions are tap-only. See `docs/WAVES.md`.
    @Entry var autocompleteEjectAffordance: Autocomplete.EjectAffordance? = nil
}

public extension Autocomplete {

    /// FORK PATCH (Lyklaborð wave 37 — long-press to eject learned
    /// vocabulary): what the toolbar should do when the user long-presses a
    /// suggestion flagged ``Autocomplete/Suggestion/isPersonalLearned``, plus
    /// the localized copy for the inline confirm. Injected by the host via
    /// ``SwiftUICore/View/autocompleteEjectAffordance(_:)`` so all copy stays
    /// in the host (KeyboardKit ships no localization for it). Not upstream.
    struct EjectAffordance {

        /// Run when the user CONFIRMS removal of `suggestion`.
        public var action: (Autocomplete.Suggestion) -> Void

        /// Localized confirm-pill title for a suggestion, e.g.
        /// `Fjarlægja „orð"?` — the host owns the wording.
        public var confirmTitle: (Autocomplete.Suggestion) -> String

        /// Localized accessibility label for the cancel control.
        public var cancelLabel: String

        public init(
            action: @escaping (Autocomplete.Suggestion) -> Void,
            confirmTitle: @escaping (Autocomplete.Suggestion) -> String,
            cancelLabel: String
        ) {
            self.action = action
            self.confirmTitle = confirmTitle
            self.cancelLabel = cancelLabel
        }
    }
}

public extension View {

    /// FORK PATCH (Lyklaborð wave 37): inject the toolbar long-press eject
    /// affordance (see ``Autocomplete/EjectAffordance``). Pass `nil` to
    /// disable (upstream tap-only behavior).
    func autocompleteEjectAffordance(
        _ affordance: Autocomplete.EjectAffordance?
    ) -> some View {
        self.environment(\.autocompleteEjectAffordance, affordance)
    }
}


#Preview {

    struct Preview: View {

        let style: Autocomplete.ToolbarItemStyle

        let suggestions: [Autocomplete.Suggestion] = [
            .init(text: "Foo"),
            .init(text: "VeryLongTextNumberTwo", type: .autocorrect),
            .init(text: "VeryLongTextNumberThree", subtitle: "Subtitle")]

        var body: some View {
            HStack {
                ForEach(suggestions, id: \.text) {
                    Autocomplete.ToolbarItem(suggestion: $0)
                        .autocompleteToolbarItemStyle($0.isAutocorrect ? .standardAutocorrect : style)
                }
            }
        }
    }

    return VStack {
        Preview(style: .standard)
            .autocompleteToolbarItemStyle(.standard)
        Preview(style: .init(
            titleColor: .yellow,
            titleFont: .init(.body, .bold),
            subtitleColor: .yellow.opacity(0.9),
            backgroundColor: .blue,
            backgroundCornerRadius: 10
        ))
    }
    .padding(5)
    .background(Color.keyboardBackground)
    .truncationMode(.middle)
}
