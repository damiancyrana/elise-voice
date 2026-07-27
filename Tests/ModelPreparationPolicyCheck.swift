@main
enum ModelPreparationPolicyCheck {
    static func main() {
        precondition(ModelPreparationPolicy.retryDelay(afterFailureCount: 0) == 0)
        precondition(ModelPreparationPolicy.retryDelay(afterFailureCount: 1) == 5)
        precondition(ModelPreparationPolicy.retryDelay(afterFailureCount: 2) == 10)
        precondition(ModelPreparationPolicy.retryDelay(afterFailureCount: 4) == 40)
        precondition(ModelPreparationPolicy.retryDelay(afterFailureCount: 5) == 60)
        precondition(ModelPreparationPolicy.retryDelay(afterFailureCount: 20) == 60)
    }
}
