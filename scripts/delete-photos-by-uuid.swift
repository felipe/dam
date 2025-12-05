#!/usr/bin/env swift
// Usage: swift delete-photos-by-uuid.swift UUID1 UUID2 ...
// Deletes assets from Photos.app by their local identifier (moves to Recently Deleted)

import Photos
import Foundation

let uuids = Array(CommandLine.arguments.dropFirst())

guard !uuids.isEmpty else {
    print("Usage: swift delete-photos-by-uuid.swift UUID1 [UUID2 ...]")
    print("Example: swift delete-photos-by-uuid.swift 'ABC123/L0/001' 'DEF456/L0/001'")
    exit(1)
}

print("Deleting \(uuids.count) asset(s)...")

let semaphore = DispatchSemaphore(value: 0)

PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
    guard status == .authorized else {
        print("ERROR: Photos access not authorized (status: \(status.rawValue))")
        semaphore.signal()
        return
    }
    
    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: uuids, options: nil)
    print("Found \(fetchResult.count) of \(uuids.count) assets")
    
    if fetchResult.count == 0 {
        print("No assets found with those UUIDs")
        semaphore.signal()
        return
    }
    
    var assets: [PHAsset] = []
    fetchResult.enumerateObjects { asset, _, _ in
        assets.append(asset)
        print("  - \(asset.localIdentifier)")
    }
    
    PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.deleteAssets(assets as NSFastEnumeration)
    }) { success, error in
        if success {
            print("SUCCESS: Deleted \(assets.count) asset(s) (moved to Recently Deleted)")
        } else {
            print("ERROR: Delete failed - \(error?.localizedDescription ?? "unknown")")
        }
        semaphore.signal()
    }
}

semaphore.wait()
