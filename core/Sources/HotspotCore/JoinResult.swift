import Foundation

// MARK: - Join result

public enum JoinResult: String {
    case success
    case alreadyJoined = "already_joined"
    case notFound = "not_found"
    case authFailed = "auth_failed"
    case interfaceError = "interface_error"
    case verificationFailed = "verification_failed"
    case wifiOff = "wifi_off"
}
