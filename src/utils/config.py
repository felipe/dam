"""Configuration management for DAM."""

import os
from pathlib import Path
from dataclasses import dataclass
from dotenv import load_dotenv


@dataclass
class Config:
    """Application configuration loaded from environment."""

    # Immich
    immich_url: str
    immich_api_key: str

    # Paths
    staging_dir: Path
    proxy_dir: Path
    data_dir: Path

    # Batch settings
    batch_size_gb: float

    # Backblaze
    b2_bucket: str

    # Options
    dry_run: bool

    @classmethod
    def load(cls) -> "Config":
        """Load configuration from environment variables."""
        # Load .env file if it exists
        env_path = Path(__file__).parent.parent.parent / ".env"
        load_dotenv(env_path)

        # Required settings
        immich_url = os.getenv("IMMICH_URL")
        immich_api_key = os.getenv("IMMICH_API_KEY")

        if not immich_url:
            raise ValueError("IMMICH_URL environment variable is required")
        if not immich_api_key:
            raise ValueError("IMMICH_API_KEY environment variable is required")

        # Paths with defaults
        staging_dir = Path(os.getenv("STAGING_DIR", "/tmp/dam-staging"))
        proxy_dir = Path(os.getenv("PROXY_DIR", "/tmp/dam-proxies"))
        data_dir_str = os.getenv("DATA_DIR", "./data")

        # Handle relative data_dir path
        if data_dir_str.startswith("./"):
            data_dir = Path(__file__).parent.parent.parent / data_dir_str[2:]
        else:
            data_dir = Path(data_dir_str)

        # Batch settings
        batch_size_gb = float(os.getenv("BATCH_SIZE_GB", "10"))

        # Backblaze
        b2_bucket = os.getenv("B2_BUCKET", "")

        # Options
        dry_run = os.getenv("DRY_RUN", "false").lower() in ("true", "1", "yes")

        return cls(
            immich_url=immich_url.rstrip("/"),
            immich_api_key=immich_api_key,
            staging_dir=staging_dir,
            proxy_dir=proxy_dir,
            data_dir=data_dir,
            batch_size_gb=batch_size_gb,
            b2_bucket=b2_bucket,
            dry_run=dry_run,
        )

    @property
    def batch_size_bytes(self) -> int:
        """Return batch size in bytes."""
        return int(self.batch_size_gb * 1024 * 1024 * 1024)

    @property
    def tracker_db_path(self) -> Path:
        """Return path to the SQLite tracker database."""
        return self.data_dir / "tracker.db"

    def ensure_dirs(self) -> None:
        """Create required directories if they don't exist."""
        self.staging_dir.mkdir(parents=True, exist_ok=True)
        self.proxy_dir.mkdir(parents=True, exist_ok=True)
        self.data_dir.mkdir(parents=True, exist_ok=True)


# Global config instance - lazy loaded
_config: Config | None = None


def get_config() -> Config:
    """Get the global configuration instance."""
    global _config
    if _config is None:
        _config = Config.load()
    return _config


# Convenience alias
config = get_config
