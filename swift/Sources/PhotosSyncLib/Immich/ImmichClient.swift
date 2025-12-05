import Foundation

/// Client for Immich API
public final class ImmichClient: Sendable {
    private let baseURL: String
    private let apiKey: String
    private let session: URLSession
    
    public struct UploadResult: Sendable {
        public let success: Bool
        public let assetID: String?
        public let duplicate: Bool
        public let error: String?
    }
    
    public init(baseURL: String, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.session = session
    }
    
    /// Test connection to Immich
    public func ping() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/server/ping") else { return false }
        
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
    
    /// Upload an asset to Immich
    /// - Parameters:
    ///   - livePhotoVideoId: For Live Photos, the Immich ID of the already-uploaded video component
    public func uploadAsset(
        fileURL: URL,
        deviceAssetID: String,
        deviceID: String = "photos-sync",
        fileCreatedAt: Date?,
        fileModifiedAt: Date?,
        livePhotoVideoId: String? = nil
    ) async -> UploadResult {
        guard let url = URL(string: "\(baseURL)/api/assets") else {
            return UploadResult(success: false, assetID: nil, duplicate: false, error: "Invalid URL")
        }
        
        // Read file data
        guard let fileData = try? Data(contentsOf: fileURL) else {
            return UploadResult(success: false, assetID: nil, duplicate: false, error: "Could not read file")
        }
        
        let filename = fileURL.lastPathComponent
        let mimeType = mimeTypeForFile(filename)
        
        // Build multipart form data
        let boundary = UUID().uuidString
        var body = Data()
        
        // Add deviceAssetId field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"deviceAssetId\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(deviceAssetID)\r\n".data(using: .utf8)!)
        
        // Add deviceId field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"deviceId\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(deviceID)\r\n".data(using: .utf8)!)
        
        // Add fileCreatedAt if available
        if let created = fileCreatedAt {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"fileCreatedAt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(formatDate(created))\r\n".data(using: .utf8)!)
        }
        
        // Add fileModifiedAt if available
        if let modified = fileModifiedAt {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"fileModifiedAt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(formatDate(modified))\r\n".data(using: .utf8)!)
        }
        
        // Add livePhotoVideoId if this is a Live Photo image being linked to its video
        if let livePhotoVideoId = livePhotoVideoId {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"livePhotoVideoId\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(livePhotoVideoId)\r\n".data(using: .utf8)!)
        }
        
        // Add file data
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return UploadResult(success: false, assetID: nil, duplicate: false, error: "Invalid response")
            }
            
            if httpResponse.statusCode == 201 || httpResponse.statusCode == 200 {
                // Parse response to get asset ID
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let assetID = json["id"] as? String {
                    let duplicate = (json["duplicate"] as? Bool) ?? (httpResponse.statusCode == 200)
                    return UploadResult(success: true, assetID: assetID, duplicate: duplicate, error: nil)
                }
                return UploadResult(success: true, assetID: nil, duplicate: false, error: nil)
            } else {
                let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
                return UploadResult(success: false, assetID: nil, duplicate: false, error: "HTTP \(httpResponse.statusCode): \(errorMsg)")
            }
        } catch {
            return UploadResult(success: false, assetID: nil, duplicate: false, error: error.localizedDescription)
        }
    }
    
    /// Get all asset IDs from Immich (for cleanup comparison)
    public func getAllAssetIDs() async -> Set<String> {
        var assetIDs = Set<String>()
        var page = 1
        let pageSize = 1000
        
        while true {
            guard let url = URL(string: "\(baseURL)/api/assets?size=\(pageSize)&page=\(page)") else { break }
            
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            
            do {
                let (data, _) = try await session.data(for: request)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { break }
                
                if json.isEmpty { break }
                
                for asset in json {
                    if let id = asset["id"] as? String {
                        assetIDs.insert(id)
                    }
                }
                
                if json.count < pageSize { break }
                page += 1
            } catch {
                break
            }
        }
        
        return assetIDs
    }
    
    public struct AssetInfo: Sendable {
        public let id: String
        public let deviceAssetId: String
        public let originalFileName: String
        public let type: String  // IMAGE or VIDEO
        public let fileSize: Int64
    }
    
    /// Get all assets from Immich with metadata (for syncing tracker)
    public func getAllAssets(deviceId: String? = "photos-sync", progress: ((Int) -> Void)? = nil) async -> [AssetInfo] {
        var assets: [AssetInfo] = []
        var page = 1
        let pageSize = 250  // Immich caps at 250 per page
        
        while true {
            guard let url = URL(string: "\(baseURL)/api/search/metadata") else { break }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            var body: [String: Any] = [
                "take": pageSize,
                "page": page
            ]
            if let deviceId = deviceId {
                body["deviceId"] = deviceId
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            
            do {
                let (data, _) = try await session.data(for: request)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let assetsData = json["assets"] as? [String: Any],
                      let items = assetsData["items"] as? [[String: Any]] else { break }
                
                if items.isEmpty { break }
                
                for item in items {
                    if let id = item["id"] as? String,
                       let deviceAssetId = item["deviceAssetId"] as? String {
                        let filename = item["originalFileName"] as? String ?? ""
                        let type = item["type"] as? String ?? "IMAGE"
                        assets.append(AssetInfo(
                            id: id,
                            deviceAssetId: deviceAssetId,
                            originalFileName: filename,
                            type: type,
                            fileSize: 0
                        ))
                    }
                }
                
                progress?(assets.count)
                
                // Check if there's a next page (can be Int or String)
                let hasNextPage: Bool
                if let nextInt = assetsData["nextPage"] as? Int {
                    hasNextPage = true
                    _ = nextInt  // silence unused warning
                } else if let nextStr = assetsData["nextPage"] as? String, !nextStr.isEmpty {
                    hasNextPage = true
                } else {
                    hasNextPage = assetsData["nextPage"] != nil && !(assetsData["nextPage"] is NSNull)
                }
                
                if !hasNextPage {
                    break
                }
                page += 1
            } catch {
                break
            }
        }
        
        return assets
    }
    
    /// Check if an asset exists in Immich by device asset ID
    public func assetExists(deviceAssetID: String) async -> Bool {
        // Use search endpoint
        guard let url = URL(string: "\(baseURL)/api/search/metadata") else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = ["deviceAssetId": deviceAssetID]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = json["assets"] as? [String: Any],
                  let items = assets["items"] as? [[String: Any]] else {
                return false
            }
            return !items.isEmpty
        } catch {
            return false
        }
    }
    
    /// Archive assets in Immich (hide them without deleting)
    public func archiveAssets(ids: [String]) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/assets") else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "ids": ids,
            "isArchived": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 204
        } catch {
            return false
        }
    }
    
    public struct DeleteResult: Sendable {
        public let success: Bool
        public let deletedCount: Int
        public let error: String?
    }
    
    /// Delete assets from Immich (used for repair mode to replace incomplete Live Photos)
    /// - Parameters:
    ///   - ids: Array of Immich asset IDs to delete
    ///   - force: If true, permanently deletes. If false, moves to trash.
    public func deleteAssets(ids: [String], force: Bool = false) async -> DeleteResult {
        guard !ids.isEmpty else {
            return DeleteResult(success: true, deletedCount: 0, error: nil)
        }
        
        guard let url = URL(string: "\(baseURL)/api/assets") else {
            return DeleteResult(success: false, deletedCount: 0, error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "ids": ids,
            "force": force
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 204 {
                    return DeleteResult(success: true, deletedCount: ids.count, error: nil)
                } else {
                    return DeleteResult(success: false, deletedCount: 0, error: "HTTP \(httpResponse.statusCode)")
                }
            }
            return DeleteResult(success: false, deletedCount: 0, error: "Invalid response")
        } catch {
            return DeleteResult(success: false, deletedCount: 0, error: error.localizedDescription)
        }
    }
    
    /// Get asset info by ID
    public func getAsset(id: String) async -> [String: Any]? {
        guard let url = URL(string: "\(baseURL)/api/assets/\(id)") else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    
    private func mimeTypeForFile(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        let mimeTypes: [String: String] = [
            // Images
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "webp": "image/webp",
            "heic": "image/heic",
            "heif": "image/heif",
            "tiff": "image/tiff",
            "tif": "image/tiff",
            "bmp": "image/bmp",
            "dng": "image/dng",
            "cr2": "image/x-canon-cr2",
            "nef": "image/x-nikon-nef",
            "arw": "image/x-sony-arw",
            // Videos
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "avi": "video/x-msvideo",
            "mkv": "video/x-matroska",
            "webm": "video/webm",
            "m4v": "video/x-m4v",
            "3gp": "video/3gpp",
        ]
        return mimeTypes[ext] ?? "application/octet-stream"
    }
}
