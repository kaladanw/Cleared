import SwiftUI

/// Email + password sign-in / account creation against the Railway backend
/// (Supabase Auth). The same account works on the web hub and the Chrome
/// extension. Error text is the honest reason from `AuthError`.
struct SignInView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case signIn = "Sign in"
        case signUp = "Create account"
        var id: String { rawValue }
    }

    @EnvironmentObject private var model: AppModel
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// Signup succeeded but the account needs email confirmation first.
    @State private var confirmationEmail: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Check a listing before you buy.")
                        .font(.headline)
                    Text("Sign in once here. Then share any Depop listing to Cleared and your checks are saved to the same history as the web hub.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let setupError = model.setupError {
                Section {
                    Label(setupError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if let confirmationEmail {
                confirmationSection(confirmationEmail)
            } else {
                formSections
            }
        }
        .navigationTitle(mode == .signIn ? "Sign in" : "Create account")
        .disabled(isWorking)
    }

    @ViewBuilder
    private var formSections: some View {
        Section {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { errorMessage = nil }
        }

        Section {
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(mode == .signIn ? .password : .newPassword)
        } footer: {
            if mode == .signUp {
                Text("Cleared is invite-only for now. Use the email address you were invited with.")
            }
        }

        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
        }

        Section {
            Button {
                Task { await submit() }
            } label: {
                HStack {
                    Spacer()
                    if isWorking {
                        ProgressView()
                    } else {
                        Text(mode.rawValue).font(.headline)
                    }
                    Spacer()
                }
            }
            .disabled(!canSubmit)
        }
    }

    private func confirmationSection(_ address: String) -> some View {
        Section {
            Label("Check your email", systemImage: "envelope.badge")
                .font(.headline)
            Text("Your account was created, but it needs confirming first. Open the link we sent to \(address), then come back and sign in.")
                .foregroundStyle(.secondary)
            Button("I've confirmed it, sign in") {
                confirmationEmail = nil
                mode = .signIn
                password = ""
            }
        }
    }

    private var canSubmit: Bool {
        !isWorking
            && email.trimmingCharacters(in: .whitespaces).contains("@")
            && !password.isEmpty
    }

    private func submit() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            switch mode {
            case .signIn:
                try await model.signIn(email: email, password: password)
            case .signUp:
                let outcome = try await model.signUp(email: email, password: password)
                if case .confirmationRequired(let address) = outcome {
                    confirmationEmail = address
                }
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
