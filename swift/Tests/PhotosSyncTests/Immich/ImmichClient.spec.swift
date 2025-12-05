import Testing
import Foundation
@testable import PhotosSyncLib

// MARK: - Mock URLProtocol for testing HTTP requests

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        MockURLProtocol.capturedRequests.append(request)
        
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
    
    static func reset() {
        requestHandler = nil
        capturedRequests = []
    }
}

// MARK: - Test Helpers

func createMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

func mockResponse(url: URL, statusCode: Int, json: Any? = nil) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    let data: Data
    if let json = json {
        data = try! JSONSerialization.data(withJSONObject: json)
    } else {
        data = Data()
    }
    return (response, data)
}

// MARK: - Tests

@Suite("ImmichClient API Tests", .serialized)
struct ImmichClientSpec {
    
    let baseURL = "http://localhost:2283"
    let apiKey = "test-api-key"
    
    init() {
        MockURLProtocol.reset()
    }
    
    // MARK: - ping() tests
    
    @Test("ping returns true on 200 response")
    func pingSuccess() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/server/ping")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-api-key")
            return mockResponse(url: request.url!, statusCode: 200, json: ["res": "pong"])
        }
        
        let result = await client.ping()
        #expect(result == true)
    }
    
    @Test("ping returns false on non-200 response")
    func pingFailure() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { request in
            return mockResponse(url: request.url!, statusCode: 500)
        }
        
        let result = await client.ping()
        #expect(result == false)
    }
    
    @Test("ping returns false on network error")
    func pingNetworkError() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        
        let result = await client.ping()
        #expect(result == false)
    }
    
    // MARK: - getAllAssetIDs() tests
    
    @Test("getAllAssetIDs returns asset IDs from paginated response")
    func getAllAssetIDsSuccess() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        var pageRequests = 0
        MockURLProtocol.requestHandler = { request in
            pageRequests += 1
            #expect(request.url?.path == "/api/assets")
            
            if pageRequests == 1 {
                // First page with 2 assets
                return mockResponse(url: request.url!, statusCode: 200, json: [
                    ["id": "asset-1", "type": "IMAGE"],
                    ["id": "asset-2", "type": "VIDEO"]
                ])
            } else {
                // Second page empty - signals end
                return mockResponse(url: request.url!, statusCode: 200, json: [])
            }
        }
        
        let assetIDs = await client.getAllAssetIDs()
        #expect(assetIDs.count == 2)
        #expect(assetIDs.contains("asset-1"))
        #expect(assetIDs.contains("asset-2"))
    }
    
    @Test("getAllAssetIDs returns empty set on error")
    func getAllAssetIDsError() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }
        
        let assetIDs = await client.getAllAssetIDs()
        #expect(assetIDs.isEmpty)
    }
    
    // MARK: - archiveAssets() tests
    
    @Test("archiveAssets returns true on 204 response")
    func archiveAssetsSuccess() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path == "/api/assets")
            
            // Verify request body
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                #expect(json["isArchived"] as? Bool == true)
                #expect((json["ids"] as? [String])?.contains("asset-1") == true)
            }
            
            return mockResponse(url: request.url!, statusCode: 204)
        }
        
        let result = await client.archiveAssets(ids: ["asset-1", "asset-2"])
        #expect(result == true)
    }
    
    @Test("archiveAssets returns false on non-204 response")
    func archiveAssetsFailure() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { request in
            return mockResponse(url: request.url!, statusCode: 400, json: ["error": "Bad request"])
        }
        
        let result = await client.archiveAssets(ids: ["asset-1"])
        #expect(result == false)
    }
    
    // MARK: - getAsset() tests
    
    @Test("getAsset returns asset data on success")
    func getAssetSuccess() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { request in
            #expect(request.url?.path == "/api/assets/test-id")
            return mockResponse(url: request.url!, statusCode: 200, json: [
                "id": "test-id",
                "originalFileName": "photo.jpg",
                "type": "IMAGE"
            ])
        }
        
        let asset = await client.getAsset(id: "test-id")
        #expect(asset?["id"] as? String == "test-id")
        #expect(asset?["originalFileName"] as? String == "photo.jpg")
    }
    
    @Test("getAsset returns nil on 404")
    func getAssetNotFound() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { request in
            return mockResponse(url: request.url!, statusCode: 404)
        }
        
        let asset = await client.getAsset(id: "nonexistent")
        #expect(asset == nil)
    }
    
    // MARK: - assetExists() tests
    
    @Test("assetExists returns true when asset found")
    func assetExistsTrue() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/search/metadata")
            return mockResponse(url: request.url!, statusCode: 200, json: [
                "assets": [
                    "items": [["id": "found-asset", "deviceAssetId": "device-123"]]
                ]
            ])
        }
        
        let exists = await client.assetExists(deviceAssetID: "device-123")
        #expect(exists == true)
    }
    
    @Test("assetExists returns false when not found")
    func assetExistsFalse() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { request in
            return mockResponse(url: request.url!, statusCode: 200, json: [
                "assets": ["items": []]
            ])
        }
        
        let exists = await client.assetExists(deviceAssetID: "nonexistent")
        #expect(exists == false)
    }
    
    // MARK: - uploadAsset() tests
    
    @Test("uploadAsset returns success with asset ID on 201")
    func uploadAssetSuccess() async throws {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        // Create a temp file to upload
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test-upload.jpg")
        try "fake image data".data(using: .utf8)!.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        MockURLProtocol.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/assets")
            #expect(request.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true)
            
            return mockResponse(url: request.url!, statusCode: 201, json: [
                "id": "new-asset-id",
                "duplicate": false
            ])
        }
        
        let result = await client.uploadAsset(
            fileURL: tempFile,
            deviceAssetID: "device-asset-123",
            fileCreatedAt: Date(),
            fileModifiedAt: Date()
        )
        
        #expect(result.success == true)
        #expect(result.assetID == "new-asset-id")
        #expect(result.duplicate == false)
        #expect(result.error == nil)
    }
    
    @Test("uploadAsset detects duplicate on 200")
    func uploadAssetDuplicate() async throws {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test-upload-dup.jpg")
        try "fake image data".data(using: .utf8)!.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        MockURLProtocol.requestHandler = { request in
            return mockResponse(url: request.url!, statusCode: 200, json: [
                "id": "existing-asset-id",
                "duplicate": true
            ])
        }
        
        let result = await client.uploadAsset(
            fileURL: tempFile,
            deviceAssetID: "device-asset-123",
            fileCreatedAt: nil,
            fileModifiedAt: nil
        )
        
        #expect(result.success == true)
        #expect(result.assetID == "existing-asset-id")
        #expect(result.duplicate == true)
    }
    
    @Test("uploadAsset returns error on failure")
    func uploadAssetFailure() async throws {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test-upload-fail.jpg")
        try "fake image data".data(using: .utf8)!.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        MockURLProtocol.requestHandler = { request in
            return mockResponse(url: request.url!, statusCode: 500, json: ["message": "Server error"])
        }
        
        let result = await client.uploadAsset(
            fileURL: tempFile,
            deviceAssetID: "device-asset-123",
            fileCreatedAt: nil,
            fileModifiedAt: nil
        )
        
        #expect(result.success == false)
        #expect(result.error?.contains("500") == true)
    }
    
    @Test("uploadAsset returns error for nonexistent file")
    func uploadAssetFileNotFound() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        let result = await client.uploadAsset(
            fileURL: URL(fileURLWithPath: "/nonexistent/file.jpg"),
            deviceAssetID: "device-asset-123",
            fileCreatedAt: nil,
            fileModifiedAt: nil
        )
        
        #expect(result.success == false)
        #expect(result.error == "Could not read file")
    }
    
    // MARK: - getAllAssets() tests
    
    @Test("getAllAssets returns paginated assets with metadata")
    func getAllAssetsSuccess() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        var pageRequests = 0
        MockURLProtocol.requestHandler = { request in
            pageRequests += 1
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/search/metadata")
            
            if pageRequests == 1 {
                return mockResponse(url: request.url!, statusCode: 200, json: [
                    "assets": [
                        "items": [
                            ["id": "asset-1", "deviceAssetId": "device-1", "originalFileName": "photo1.jpg", "type": "IMAGE"],
                            ["id": "asset-2", "deviceAssetId": "device-2", "originalFileName": "video1.mov", "type": "VIDEO"]
                        ],
                        "nextPage": 2
                    ]
                ])
            } else {
                return mockResponse(url: request.url!, statusCode: 200, json: [
                    "assets": [
                        "items": [],
                        "nextPage": NSNull()
                    ]
                ])
            }
        }
        
        let assets = await client.getAllAssets(deviceId: "photos-sync")
        #expect(assets.count == 2)
        #expect(assets[0].id == "asset-1")
        #expect(assets[0].deviceAssetId == "device-1")
        #expect(assets[0].originalFileName == "photo1.jpg")
        #expect(assets[0].type == "IMAGE")
        #expect(assets[1].type == "VIDEO")
    }
    
    // MARK: - URL handling tests
    
    @Test("trims trailing slash from baseURL")
    func trimTrailingSlash() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: "http://localhost:2283/", apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { request in
            // Should not have double slashes
            #expect(request.url?.absoluteString == "http://localhost:2283/api/server/ping")
            return mockResponse(url: request.url!, statusCode: 200)
        }
        
        _ = await client.ping()
    }
    
    // MARK: - deleteAssets() tests
    
    @Test("deleteAssets returns success on 204 response")
    func deleteAssetsSuccess() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.path == "/api/assets")
            
            // Verify request body
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                #expect((json["ids"] as? [String])?.contains("asset-1") == true)
                #expect(json["force"] as? Bool == true)
            }
            
            return mockResponse(url: request.url!, statusCode: 204)
        }
        
        let result = await client.deleteAssets(ids: ["asset-1", "asset-2"], force: true)
        #expect(result.success == true)
        #expect(result.deletedCount == 2)
        #expect(result.error == nil)
    }
    
    @Test("deleteAssets returns failure on non-204 response")
    func deleteAssetsFailure() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        MockURLProtocol.requestHandler = { request in
            return mockResponse(url: request.url!, statusCode: 400, json: ["error": "Bad request"])
        }
        
        let result = await client.deleteAssets(ids: ["asset-1"])
        #expect(result.success == false)
        #expect(result.deletedCount == 0)
        #expect(result.error?.contains("400") == true)
    }
    
    @Test("deleteAssets returns success for empty list")
    func deleteAssetsEmpty() async {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        // Should not make any HTTP request
        MockURLProtocol.requestHandler = { _ in
            Issue.record("Should not make HTTP request for empty list")
            return mockResponse(url: URL(string: "http://test")!, statusCode: 500)
        }
        
        let result = await client.deleteAssets(ids: [])
        #expect(result.success == true)
        #expect(result.deletedCount == 0)
    }
    
    // MARK: - uploadAsset with livePhotoVideoId tests
    
    @Test("uploadAsset includes livePhotoVideoId in request")
    func uploadAssetWithLivePhotoVideoId() async throws {
        let session = createMockSession()
        let client = ImmichClient(baseURL: baseURL, apiKey: apiKey, session: session)
        
        // Create a temp file to upload
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("test-live-photo.heic")
        try "fake image data".data(using: .utf8)!.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        MockURLProtocol.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/assets")
            
            // Check that livePhotoVideoId is in the multipart body
            if let body = request.httpBody,
               let bodyString = String(data: body, encoding: .utf8) {
                #expect(bodyString.contains("livePhotoVideoId"))
                #expect(bodyString.contains("video-immich-id-123"))
            }
            
            return mockResponse(url: request.url!, statusCode: 201, json: [
                "id": "new-asset-id",
                "duplicate": false
            ])
        }
        
        let result = await client.uploadAsset(
            fileURL: tempFile,
            deviceAssetID: "device-asset-123",
            fileCreatedAt: Date(),
            fileModifiedAt: Date(),
            livePhotoVideoId: "video-immich-id-123"
        )
        
        #expect(result.success == true)
        #expect(result.assetID == "new-asset-id")
    }
}
