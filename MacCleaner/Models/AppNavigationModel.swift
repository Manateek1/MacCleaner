import Combine

@MainActor
final class AppNavigationModel: ObservableObject {
    @Published var selectedSection: AppSection? = .overview
}
