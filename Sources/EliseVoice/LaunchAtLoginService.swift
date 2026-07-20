import ServiceManagement

enum LaunchAtLoginService {
    static func enable() throws {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled, .requiresApproval:
            return
        case .notRegistered, .notFound:
            try service.register()
        @unknown default:
            try service.register()
        }
    }
}
