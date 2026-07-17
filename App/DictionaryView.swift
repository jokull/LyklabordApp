//
//  DictionaryView.swift
//  BetterKeyboard
//
//  "Orðasafn" — the dictionary editor. Two sections (learned words / words
//  the user explicitly added), a search field filtering both, swipe-to-
//  delete with a brief undo affordance, and an add-word sheet. See
//  `AppModel` for the underlying `PersonalModel` semantics and why undo
//  re-adds a word as user-added rather than restoring its original state.
//

import SwiftUI
import UniformTypeIdentifiers

struct DictionaryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SubscriptionManager.self) private var subscriptions

    @State private var showingPaywall = false
    @State private var searchText = ""
    @State private var showingAddSheet = false
    @State private var newWordText = ""
    @State private var addWordError: String?
    @State private var pendingUndo: PendingUndo?
    @State private var showingImportSheet = false
    @State private var showingImportPicker = false
    @State private var importAlert: ImportAlert?
    @State private var exportDocument: ExportDataDocument?
    @State private var showingExporter = false
    @State private var showExportError = false

    private struct PendingUndo: Identifiable {
        let id = UUID()
        let word: String
    }

    private enum ImportAlert: Identifiable {
        case success(AppModel.ImportOutcome)
        case failure(String)

        var id: String {
            switch self {
            case .success: return "success"
            case .failure: return "failure"
            }
        }
    }

    /// Single-pass filter, called once per render from `list` (not a
    /// computed property referenced multiple times — after a SwiftKey import
    /// the learned list can hold ~15k words, and one lowercased-contains
    /// sweep per keystroke over that is fine; three per keystroke is silly).
    private func filter(_ words: [String]) -> [String] {
        guard !searchText.isEmpty else { return words }
        let needle = searchText.lowercased()
        return words.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch appModel.containerState {
                case .unavailable:
                    containerUnavailableState
                case .ready:
                    // Lyklaborð+ gate: the dictionary editor (personal
                    // vocabulary) is the subscription's core surface. The
                    // free keyboard keeps learning into the event log — the
                    // locked state says so — but browsing/editing/importing
                    // unlocks with the subscription. Export stays free
                    // (data ownership is never paywalled; see Settings).
                    if !subscriptions.isEntitled {
                        plusLockedState
                    } else if !appModel.hasAnyWords {
                        emptyState
                    } else {
                        list
                    }
                }
            }
            .navigationTitle(Strings.Dictionary.navigationTitle)
            .searchable(text: $searchText, prompt: Strings.Dictionary.searchPrompt)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newWordText = ""
                        addWordError = nil
                        showingAddSheet = true
                    } label: {
                        Label(Strings.Dictionary.addWordButton, systemImage: "plus")
                    }
                    .disabled(appModel.containerState == .unavailable || !subscriptions.isEntitled)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingImportSheet = true
                    } label: {
                        Label(Strings.SwiftKeyImport.actionTitle, systemImage: "square.and.arrow.down")
                    }
                    .disabled(appModel.containerState == .unavailable || !subscriptions.isEntitled)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        exportData()
                    } label: {
                        Label(Strings.DataExport.button, systemImage: "square.and.arrow.up")
                    }
                    .disabled(appModel.containerState == .unavailable || !appModel.hasAnyWords)
                }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: appModel.exportFilename()
            ) { _ in
                exportDocument = nil
            }
            .alert(Strings.DataExport.failed, isPresented: $showExportError) {
                Button(Strings.DeleteAll.ok, role: .cancel) {}
            }
            .sheet(isPresented: $showingAddSheet) {
                addWordSheet
            }
            .sheet(isPresented: $showingPaywall) {
                SubscriptionView()
            }
            .sheet(isPresented: $showingImportSheet) {
                importSheet
            }
            .alert(item: $importAlert) { alert in
                switch alert {
                case .success(let outcome):
                    Alert(
                        title: Text(Strings.SwiftKeyImport.resultTitle),
                        message: Text(importSummaryMessage(outcome)),
                        dismissButton: .default(Text(Strings.SwiftKeyImport.resultOK))
                    )
                case .failure(let message):
                    Alert(
                        title: Text(Strings.SwiftKeyImport.errorTitle),
                        message: Text(message),
                        dismissButton: .default(Text(Strings.SwiftKeyImport.resultOK))
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let pendingUndo {
                    undoBanner(for: pendingUndo)
                }
            }
        }
    }

    // MARK: - List

    private var list: some View {
        let filteredLearned = filter(appModel.learnedWords)
        let filteredUserAdded = filter(appModel.userAddedWords)
        return List {
            if !filteredLearned.isEmpty {
                Section {
                    ForEach(filteredLearned, id: \.self) { word in
                        Text(word)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(word)
                                } label: {
                                    Label(Strings.Dictionary.deleteButton, systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("\(Strings.Dictionary.learnedSectionTitle) (\(appModel.learnedWords.count))")
                }
            }

            if !filteredUserAdded.isEmpty {
                Section {
                    ForEach(filteredUserAdded, id: \.self) { word in
                        Text(word)
                    }
                } header: {
                    Text("\(Strings.Dictionary.userAddedSectionTitle) (\(appModel.userAddedWords.count))")
                }
            }

            if filteredLearned.isEmpty && filteredUserAdded.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func delete(_ word: String) {
        appModel.removeLearned(word)
        pendingUndo = PendingUndo(word: word)
    }

    private func undoBanner(for pending: PendingUndo) -> some View {
        HStack {
            Text(Strings.Dictionary.deletedMessage(pending.word))
                .font(.subheadline)
            Spacer()
            Button(Strings.Dictionary.undoButton) {
                appModel.undoRemove(pending.word)
                pendingUndo = nil
            }
            .font(.subheadline.bold())
        }
        .padding()
        .background(.bar)
        .task(id: pending.id) {
            try? await Task.sleep(for: .seconds(4))
            if pendingUndo?.id == pending.id {
                pendingUndo = nil
            }
        }
    }

    // MARK: - Lyklaborð+ locked state

    /// Shown instead of the editor when the subscription is not active.
    /// Honest honor-box copy: the keyboard stays fully free, learning
    /// history keeps accruing on-device and activates on subscribe.
    private var plusLockedState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(Strings.Plus.lockedDictionaryTitle, systemImage: "lock")
                        .font(.title3.bold())
                    Text(Strings.Plus.lockedDictionaryBody)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showingPaywall = true
                } label: {
                    Label(Strings.Plus.learnMoreButton, systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(Strings.Plus.restoreButton) {
                    Task { await subscriptions.restorePurchases() }
                }
                .font(.callout)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Empty / unavailable states

    private var containerUnavailableState: some View {
        ContentUnavailableView {
            Label(Strings.Dictionary.containerUnavailableTitle, systemImage: "externaldrive.trianglebadge.exclamationmark")
        } description: {
            Text(Strings.Dictionary.containerUnavailableBody)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(Strings.Dictionary.emptyStateTitle)
                        .font(.title2.bold())
                    Text(Strings.Dictionary.emptyStateHowItWorks)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(Strings.Dictionary.emptyStatePrivacy, systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }

                Button {
                    newWordText = ""
                    addWordError = nil
                    showingAddSheet = true
                } label: {
                    Label(Strings.Dictionary.addWordButton, systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showingImportSheet = true
                } label: {
                    Label(Strings.SwiftKeyImport.actionTitle, systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - SwiftKey import

    private var importSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(Strings.SwiftKeyImport.explainer)
                    Label(Strings.SwiftKeyImport.explainerNote, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        showingImportPicker = true
                    } label: {
                        Label(Strings.SwiftKeyImport.chooseFileButton, systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding()
            }
            .navigationTitle(Strings.SwiftKeyImport.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.SwiftKeyImport.cancelButton) {
                        showingImportSheet = false
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [.plainText],
                allowsMultipleSelection: false
            ) { result in
                showingImportSheet = false
                handleImportPick(result)
            }
        }
        .presentationDetents([.medium])
    }

    private func handleImportPick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            // The user cancelled the picker (the only common failure) —
            // no alert, they're back on the (now dismissed) sheet's parent.
            return
        case .success(let urls):
            guard let url = urls.first else { return }
            switch appModel.importSwiftKeyVocabulary(from: url) {
            case .success(let outcome):
                importAlert = .success(outcome)
            case .failure(.accessDenied):
                importAlert = .failure(Strings.SwiftKeyImport.errorNoAccess)
            case .failure(.unreadable):
                importAlert = .failure(Strings.SwiftKeyImport.errorUnreadable)
            }
        }
    }

    private func exportData() {
        if let data = appModel.exportedData() {
            exportDocument = ExportDataDocument(data: data)
            showingExporter = true
        } else {
            showExportError = true
        }
    }

    private func importSummaryMessage(_ outcome: AppModel.ImportOutcome) -> String {
        var lines = [Strings.SwiftKeyImport.importedMessage(formattedCount(outcome.imported))]
        if outcome.skippedInvalid > 0 {
            lines.append(Strings.SwiftKeyImport.skippedInvalidMessage(formattedCount(outcome.skippedInvalid)))
        }
        if outcome.skippedTombstoned > 0 {
            lines.append(Strings.SwiftKeyImport.skippedTombstonedMessage(formattedCount(outcome.skippedTombstoned)))
        }
        return lines.joined(separator: "\n")
    }

    /// Icelandic-style grouping ("14.194"), independent of device locale —
    /// the surrounding copy is Icelandic either way.
    private func formattedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "is_IS")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Add word

    private var addWordSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(Strings.Dictionary.addWordPlaceholder, text: $newWordText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if let addWordError {
                        Text(addWordError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(Strings.Dictionary.addWordTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.Dictionary.addWordCancel) {
                        showingAddSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.Dictionary.addWordSave) {
                        if let error = appModel.addWord(newWordText) {
                            addWordError = error
                        } else {
                            showingAddSheet = false
                        }
                    }
                    .disabled(newWordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    DictionaryView()
        .environment(AppModel())
        .environment(SubscriptionManager())
}
