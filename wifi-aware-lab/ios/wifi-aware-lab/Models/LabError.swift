import Foundation

nonisolated enum LabError: Error, Equatable {
  case unsupported
  case serviceNotDeclared
  case publisherAlreadyRunning
  case subscriberAlreadyRunning
  case linkNotActive(String)
  case unsupportedEndpoint
  case failure(LabFailure)
}
