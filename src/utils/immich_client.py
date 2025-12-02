"""Immich API client for DAM."""

import requests
from pathlib import Path
from typing import Optional
from dataclasses import dataclass


@dataclass
class UploadResult:
    """Result of an upload operation."""

    success: bool
    asset_id: Optional[str] = None
    duplicate: bool = False
    error: Optional[str] = None


class ImmichClient:
    """Client for interacting with Immich API."""

    def __init__(self, base_url: str, api_key: str):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.session = requests.Session()
        self.session.headers.update({"x-api-key": api_key})

    def ping(self) -> bool:
        """Check if Immich server is reachable."""
        try:
            response = self.session.get(f"{self.base_url}/api/server/ping")
            return response.status_code == 200
        except requests.RequestException:
            return False

    def get_server_info(self) -> dict:
        """Get server information."""
        response = self.session.get(f"{self.base_url}/api/server/about")
        response.raise_for_status()
        return response.json()

    def get_statistics(self) -> dict:
        """Get library statistics."""
        response = self.session.get(f"{self.base_url}/api/server/statistics")
        response.raise_for_status()
        return response.json()

    def upload_asset(
        self,
        file_path: Path,
        device_asset_id: str,
        device_id: str = "dam-importer",
        file_created_at: Optional[str] = None,
        file_modified_at: Optional[str] = None,
    ) -> UploadResult:
        """
        Upload an asset to Immich.

        Args:
            file_path: Path to the file to upload
            device_asset_id: Unique identifier for this asset (iCloud UUID)
            device_id: Device identifier
            file_created_at: ISO timestamp of file creation
            file_modified_at: ISO timestamp of file modification

        Returns:
            UploadResult with success status and asset ID
        """
        if not file_path.exists():
            return UploadResult(success=False, error=f"File not found: {file_path}")

        # Prepare multipart form data
        # Immich expects specific field names
        try:
            with open(file_path, "rb") as f:
                files = {"assetData": (file_path.name, f, self._get_mime_type(file_path))}

                data = {
                    "deviceAssetId": device_asset_id,
                    "deviceId": device_id,
                }

                if file_created_at:
                    data["fileCreatedAt"] = file_created_at
                if file_modified_at:
                    data["fileModifiedAt"] = file_modified_at

                response = self.session.post(
                    f"{self.base_url}/api/assets",
                    files=files,
                    data=data,
                )

            # Handle response
            if response.status_code == 201:
                result = response.json()
                return UploadResult(
                    success=True,
                    asset_id=result.get("id"),
                    duplicate=result.get("duplicate", False),
                )
            elif response.status_code == 200:
                # Duplicate detected
                result = response.json()
                return UploadResult(
                    success=True,
                    asset_id=result.get("id"),
                    duplicate=True,
                )
            else:
                return UploadResult(
                    success=False,
                    error=f"Upload failed: {response.status_code} - {response.text}",
                )

        except requests.RequestException as e:
            return UploadResult(success=False, error=f"Request error: {e}")
        except Exception as e:
            return UploadResult(success=False, error=f"Unexpected error: {e}")

    def get_asset(self, asset_id: str) -> Optional[dict]:
        """Get asset details by ID."""
        try:
            response = self.session.get(f"{self.base_url}/api/assets/{asset_id}")
            if response.status_code == 200:
                return response.json()
            return None
        except requests.RequestException:
            return None

    def get_all_assets(self, limit: int = 1000) -> list[dict]:
        """Get all assets (paginated)."""
        assets = []
        page = 1

        while True:
            response = self.session.get(
                f"{self.base_url}/api/assets",
                params={"size": min(limit, 1000), "page": page},
            )
            response.raise_for_status()
            batch = response.json()

            if not batch:
                break

            assets.extend(batch)
            if len(batch) < 1000 or len(assets) >= limit:
                break

            page += 1

        return assets[:limit] if limit else assets

    def search_by_checksum(self, checksum: str) -> Optional[dict]:
        """Search for an asset by its checksum."""
        # Immich uses SHA1 checksums
        try:
            response = self.session.post(
                f"{self.base_url}/api/assets/bulk-upload-check",
                json={"assets": [{"id": "check", "checksum": checksum}]},
            )
            if response.status_code == 200:
                result = response.json()
                if result.get("results"):
                    return result["results"][0]
            return None
        except requests.RequestException:
            return None

    @staticmethod
    def _get_mime_type(file_path: Path) -> str:
        """Get MIME type based on file extension."""
        extension = file_path.suffix.lower()
        mime_types = {
            # Images
            ".jpg": "image/jpeg",
            ".jpeg": "image/jpeg",
            ".png": "image/png",
            ".gif": "image/gif",
            ".webp": "image/webp",
            ".heic": "image/heic",
            ".heif": "image/heif",
            ".tiff": "image/tiff",
            ".tif": "image/tiff",
            ".bmp": "image/bmp",
            ".raw": "image/raw",
            ".dng": "image/dng",
            ".cr2": "image/x-canon-cr2",
            ".nef": "image/x-nikon-nef",
            ".arw": "image/x-sony-arw",
            # Videos
            ".mp4": "video/mp4",
            ".mov": "video/quicktime",
            ".avi": "video/x-msvideo",
            ".mkv": "video/x-matroska",
            ".webm": "video/webm",
            ".m4v": "video/x-m4v",
            ".3gp": "video/3gpp",
        }
        return mime_types.get(extension, "application/octet-stream")

    def close(self) -> None:
        """Close the HTTP session."""
        self.session.close()

    def __enter__(self) -> "ImmichClient":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()
