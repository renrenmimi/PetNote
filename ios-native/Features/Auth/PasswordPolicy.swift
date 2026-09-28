import Foundation

/// What counts as an acceptable new password, and how strong it is.
///
/// A direct port of src/utils/passwordValidator.ts, rule for rule. The point of
/// the port being literal is that the two clients must not disagree: a password
/// the web client accepts and this one refuses looks like a broken app to
/// somebody who has an account already.
///
/// **This is the client's rule, not the server's.** Firebase only enforces six
/// characters, so everything above that is this product's own policy and is
/// checked here so the person finds out while typing rather than after a round
/// trip.
enum PasswordPolicy {
    static let minLength = 8
    static let maxLength = 64

    enum Strength: Sendable, Equatable {
        case weak
        case medium
        case strong

        var label: String {
            switch self {
            case .weak: "Weak"
            case .medium: "Medium"
            case .strong: "Strong"
            }
        }
    }

    /// One requirement, and whether this password meets it.
    ///
    /// Shown as a list rather than collapsed into a single "invalid password":
    /// a rule the person cannot see is a rule they cannot satisfy, which is how
    /// somebody ends up typing eight variations of the same password.
    struct Requirement: Sendable, Equatable, Identifiable {
        let id: String
        let text: String
        let isMet: Bool
    }

    static let specialCharacters = CharacterSet(charactersIn: "!@#$%^&*()_+-=[]{};':\"\\|,.<>/?")

    static func requirements(for password: String) -> [Requirement] {
        [
            Requirement(
                id: "length",
                text: "At least 8 characters",
                isMet: password.count >= minLength
            ),
            Requirement(
                id: "maxLength",
                text: "Maximum 64 characters",
                isMet: password.count <= maxLength
            ),
            Requirement(
                id: "uppercase",
                text: "At least one uppercase letter (A-Z)",
                isMet: password.contains(where: { $0.isUppercase && $0.isASCII })
            ),
            Requirement(
                id: "lowercase",
                text: "At least one lowercase letter (a-z)",
                isMet: password.contains(where: { $0.isLowercase && $0.isASCII })
            ),
            Requirement(
                id: "digit",
                text: "At least one number (0-9)",
                isMet: password.contains(where: { $0.isNumber && $0.isASCII })
            ),
            Requirement(
                id: "special",
                text: "At least one special character (!@#$%...)",
                isMet: password.unicodeScalars.contains(where: specialCharacters.contains)
            ),
        ]
    }

    static func isValid(_ password: String) -> Bool {
        requirements(for: password).allSatisfy(\.isMet)
    }

    /// The same three-way split the web client shows, including its quirk:
    /// a valid password shorter than twelve characters is "medium", not
    /// "strong". Kept because the two clients showing different strengths for
    /// the same password is worse than either scale being ideal.
    static func strength(of password: String) -> Strength {
        let unmet = requirements(for: password).count(where: { !$0.isMet })
        if unmet == 0 { return password.count >= 12 ? .strong : .medium }
        if unmet <= 2 && password.count >= 6 { return .medium }
        return .weak
    }
}
