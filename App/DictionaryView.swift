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

struct DictionaryView: View {
    @Environment(AppModel.self) private var appModel

    @State private var searchText = ""
    @State private var showingAddSheet = false
    @State private var newWordText = ""
    @State private var addWordError: String?
    @State private var pendingUndo: PendingUndo?

    private struct PendingUndo: Identifiable {
        let id = UUID()
        let word: String
    }

    private var filteredLearned: [String] {
        filter(appModel.learnedWords)
    }

    private var filteredUserAdded: [String] {
        filter(appModel.userAddedWords)
    }

    private func filter(_ words: [String]) -> [String] {
        guard !searchText.isEmpty else { return words }
        return words.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch appModel.containerState {
                case .unavailable:
                    containerUnavailableState
                case .ready:
                    if !appModel.hasAnyWords {
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
                    .disabled(appModel.containerState == .unavailable)
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                addWordSheet
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
        List {
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
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
}
