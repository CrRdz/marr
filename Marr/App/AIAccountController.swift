import AppKit
import Carbon
import Combine
import MarrCore
import MarrNetworking
import MarrSettings
import SwiftUI

extension MarrController {
    /// Saved non-secret connection metadata; displaying the menu never reads credentials.
    var configuredGatewayProfiles: [(preset: GatewayPreset, profile: ProviderConnectionProfile)] {
        GatewayPreset.allCases.compactMap { preset in
            if provider == .gateway, preset == gatewayPreset {
                return (preset, .init(baseURL: gatewayBaseURL, authScheme: gatewayAuthScheme,
                    apiFormat: gatewayAPIFormat, model: model))
            }
            guard let profile = settingsRepository.providerProfile(preset) else { return nil }
            return (preset, profile)
        }
    }

    var activeChatGPTProfile: ChatGPTProfile? {
        chatGPTProfiles.first { $0.id == chatGPTActiveProfileID }
    }

    var selectedChatGPTModel: ChatGPTModel? {
        chatGPTModels.first { $0.slug == model }
    }

    func selectChatGPTModel(_ slug: String) {
        guard chatGPTModels.contains(where: { $0.slug == slug }) else { return }
        guard model != slug else { return }
        model = slug
        if !chatGPTReasoningEffort.isEmpty, let selectedChatGPTModel,
           !selectedChatGPTModel.reasoningEfforts.contains(chatGPTReasoningEffort) {
            chatGPTReasoningEffort = ""
        }
        if chatGPTFastMode, selectedChatGPTModel?.supportsFastMode != true { chatGPTFastMode = false }
        scheduleInferenceSettingsSave(immediately: true)
    }

    func refreshChatGPTAccount(forceRefresh: Bool = false) {
        guard !chatGPTBusy, chatGPTRefreshTask == nil else { return }
        let requestID = UUID()
        chatGPTRefreshID = requestID
        chatGPTModelsLoading = true
        chatGPTModelError = nil
        chatGPTRefreshTask = Task {
            defer {
                if chatGPTRefreshID == requestID {
                    chatGPTModelsLoading = false
                    chatGPTRefreshTask = nil
                    chatGPTRefreshID = nil
                }
            }
            do { try await loadChatGPTAccount(forceRefresh: forceRefresh) }
            catch is CancellationError { }
            catch {
                guard !Task.isCancelled, chatGPTRefreshID == requestID else { return }
                chatGPTModelError = error.localizedDescription
                let profiles = try? await self.chatGPTSession.profiles()
                guard !Task.isCancelled, chatGPTRefreshID == requestID else { return }
                if let profiles { chatGPTProfiles = profiles }
                if activeChatGPTProfile?.canUsePlan != true { chatGPTModels = [] }
            }
        }
    }

    func signInWithChatGPT(newAccount: Bool = false, requestConsent: Bool = false) {
        guard canChangeChatGPTAccount() else { return }
        runChatGPTAction {
            _ = try await self.chatGPTSession.signIn(
                profileID: newAccount ? nil : self.chatGPTActiveProfileID,
                requestConsent: requestConsent,
                openBrowser: { NSWorkspace.shared.open($0) })
            try await self.loadChatGPTAccount()
            if self.activeChatGPTProfile?.canUsePlan == true {
                if !UserDefaults.standard.bool(forKey: "chatgpt.plan.welcomeShown") {
                    self.showsChatGPTWelcome = true
                    UserDefaults.standard.set(true, forKey: "chatgpt.plan.welcomeShown")
                }
            }
        }
    }

    func selectChatGPTProfile(_ id: String) {
        guard canChangeChatGPTAccount() else { return }
        runChatGPTAction {
            try await self.chatGPTSession.selectProfile(id)
            try await self.loadChatGPTAccount()
        }
    }

    func reconnectChatGPTProfile(_ id: String, requestConsent: Bool = false) {
        guard canChangeChatGPTAccount() else { return }
        runChatGPTAction {
            _ = try await self.chatGPTSession.signIn(profileID: id, requestConsent: requestConsent, openBrowser: { NSWorkspace.shared.open($0) })
            try await self.loadChatGPTAccount()
        }
    }

    func signOutOfChatGPT(profileID: String? = nil) {
        guard canChangeChatGPTAccount() else { return }
        guard let id = profileID ?? chatGPTActiveProfileID else { return }
        runChatGPTAction {
            let revoked = try await self.chatGPTSession.signOut(profileID: id)
            try await self.loadChatGPTAccount()
            self.chatGPTStatus = revoked ? "Signed out of ChatGPT."
                : "Signed out locally. Remote revocation was not confirmed; disconnect Marr in ChatGPT settings."
        }
    }

    func cancelChatGPTSignIn() {
        chatGPTTask?.cancel()
        cancelChatGPTRefresh()
    }

    private func cancelChatGPTRefresh() {
        chatGPTRefreshTask?.cancel()
        chatGPTRefreshTask = nil
        chatGPTRefreshID = nil
        chatGPTModelsLoading = false
    }

    private func canChangeChatGPTAccount() -> Bool {
        guard activeInferenceRequests == 0 else {
            chatGPTStatus = "Wait for the active Conversation or translation request to finish before changing accounts."
            return false
        }
        return true
    }

    private func runChatGPTAction(_ action: @escaping @MainActor () async throws -> Void) {
        guard !chatGPTBusy else { return }
        cancelChatGPTRefresh()
        chatGPTBusy = true
        chatGPTStatus = ""
        chatGPTModelError = nil
        chatGPTTask = Task {
            defer { chatGPTBusy = false; chatGPTTask = nil }
            do { try await action() }
            catch is CancellationError { chatGPTStatus = "ChatGPT sign-in cancelled." }
            catch {
                chatGPTStatus = error.localizedDescription
                // Include registrations retained after a failed code exchange so users can retry them.
                chatGPTProfiles = (try? await self.chatGPTSession.profiles()) ?? chatGPTProfiles
                synchronizeChatGPTConnections(chatGPTProfiles, activeID: chatGPTActiveProfileID)
            }
        }
    }

    private func loadChatGPTAccount(forceRefresh: Bool = false) async throws {
        let profiles = try await self.chatGPTSession.profiles()
        let profileID = try await self.chatGPTSession.activeProfileID()
        try Task.checkCancellation()
        if profileID != chatGPTActiveProfileID { chatGPTModels = [] }
        chatGPTProfiles = profiles
        chatGPTActiveProfileID = profileID
        synchronizeChatGPTConnections(profiles, activeID: profileID)
        let catalogProfile = provider == .chatGPT
            ? profiles.first { $0.id == defaultAIConnection?.chatGPTProfileID } ?? activeChatGPTProfile
            : activeChatGPTProfile
        if let profile = catalogProfile, profile.canUsePlan {
            if let cached = try await self.chatGPTSession.cachedModels(profileID: profile.id) {
                try Task.checkCancellation()
                chatGPTModels = cached
            }
            let models = try await self.chatGPTSession.models(profileID: profile.id, forceRefresh: forceRefresh)
            try Task.checkCancellation()
            guard !Task.isCancelled else { return }
            chatGPTModels = models
            if let index = aiConnections.connections.firstIndex(where: { $0.chatGPTProfileID == profile.id }) {
                aiConnections.connections[index].models = models.map(\.slug)
                settingsRepository.saveAIConnections(aiConnections)
            }
            if provider == .chatGPT, defaultAIConnection?.chatGPTProfileID == profile.id, !chatGPTModels.contains(where: { $0.slug == model }) { model = chatGPTModels.first?.slug ?? "" }
            if provider == .chatGPT, defaultAIConnection?.chatGPTProfileID == profile.id, !chatGPTReasoningEffort.isEmpty,
               selectedChatGPTModel?.reasoningEfforts.contains(chatGPTReasoningEffort) != true {
                chatGPTReasoningEffort = ""
            }
            if provider == .chatGPT, defaultAIConnection?.chatGPTProfileID == profile.id, chatGPTFastMode, selectedChatGPTModel?.supportsFastMode != true {
                chatGPTFastMode = false
            }
            if translationProvider == .chatGPT, !chatGPTModels.contains(where: { $0.slug == translationModel }) {
                translationModel = chatGPTModels.first?.slug ?? ""
            }
        } else {
            chatGPTModels = []
        }
    }
}
