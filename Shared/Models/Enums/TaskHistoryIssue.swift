import Foundation

enum TaskHistoryIssue: String, Sendable {
        case inaccessible, corruptPreserved, preservationFailed, writeFailed, notLoaded
        /// The file is a valid history array, but at least one record could not be read. The
        /// readable records were loaded and the original file was preserved first.
        case recordsDropped
    }
