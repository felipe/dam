import Foundation

/// Client for Immich API
class ImmichClient {
    private let baseURL: String
    private let apiKey: String
    private let session: URLSession
    
    struct UploadResult {
        let success: Bool
        let assetID: String?
        let duplicate: Bool
        let error: String?
    }
    
    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.session = URLSession.shared
    }
    
    /// Test connection to Immich
    func ping() async -> Bool {
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
    func uploadAsset(
        fileURL: URL,
        deviceAssetID: String,
        deviceID: String = "photos-sync",
        fileCreatedAt: Date?,
        fileModifiedAt: Date?
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
    func getAllAssetIDs() async -> Set<String> {
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
    
    /// Check if an asset exists in Immich by device asset ID
    func assetExists(deviceAssetID: String) async -> Bool {
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
