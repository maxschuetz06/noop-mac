import Foundation

/// A store-backed Repository operation could not run because the local store is not open.
enum RepositoryError: Error {
    case storeUnavailable
}
