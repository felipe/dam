import ArgumentParser
import Foundation

@main
struct PhotosSync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photos-sync",
        abstract: "Sync photos between iCloud Photos and Immich",
        version: "1.0.0",
        subcommands: [
            ImportCommand.self,
            StatusCommand.self,
            CleanupCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )
}
