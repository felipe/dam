"""EXIF utilities for device detection."""

from dataclasses import dataclass
from typing import Optional


@dataclass
class DeviceInfo:
    """Information about the device that captured media."""

    make: Optional[str]
    model: Optional[str]
    is_iphone: bool


# File extensions for photos vs videos
PHOTO_EXTENSIONS = {
    ".jpg",
    ".jpeg",
    ".png",
    ".gif",
    ".webp",
    ".heic",
    ".heif",
    ".tiff",
    ".tif",
    ".bmp",
    ".raw",
    ".dng",
    ".cr2",
    ".nef",
    ".arw",
}

VIDEO_EXTENSIONS = {
    ".mp4",
    ".mov",
    ".avi",
    ".mkv",
    ".webm",
    ".m4v",
    ".3gp",
}

# Extensions to skip (camera junk files)
SKIP_EXTENSIONS = {
    ".thm",  # Thumbnail previews
    ".scr",  # Screen captures / proxies
    ".lrf",  # Sony low-res preview JPEGs
}


def get_device_info(photo_info) -> DeviceInfo:
    """
    Extract device info from osxphotos PhotoInfo object.

    Args:
        photo_info: osxphotos PhotoInfo object

    Returns:
        DeviceInfo with make, model, and iPhone detection
    """
    # osxphotos provides camera_make and camera_model attributes
    make = getattr(photo_info, "camera_make", None)
    model = getattr(photo_info, "camera_model", None)

    is_iphone = _is_apple_device(make, model)

    return DeviceInfo(make=make, model=model, is_iphone=is_iphone)


def _is_apple_device(make: Optional[str], model: Optional[str]) -> bool:
    """
    Check if device is an iPhone based on EXIF make/model.

    Args:
        make: Camera make from EXIF
        model: Camera model from EXIF

    Returns:
        True if this is iPhone content
    """
    if make and "apple" in make.lower():
        return True
    if model and "iphone" in model.lower():
        return True
    return False


def is_iphone_media(photo_info) -> bool:
    """
    Quick check if media is from an iPhone.

    Args:
        photo_info: osxphotos PhotoInfo object

    Returns:
        True if from iPhone
    """
    return get_device_info(photo_info).is_iphone


def get_media_type(filename: str) -> Optional[str]:
    """
    Determine media type from filename.

    Args:
        filename: File name or path

    Returns:
        'photo', 'video', or None if unknown/skip
    """
    ext = _get_extension(filename)

    if ext in SKIP_EXTENSIONS:
        return None
    if ext in PHOTO_EXTENSIONS:
        return "photo"
    if ext in VIDEO_EXTENSIONS:
        return "video"

    return None


def should_skip_file(filename: str) -> bool:
    """
    Check if file should be skipped during import.

    Args:
        filename: File name or path

    Returns:
        True if file should be skipped
    """
    ext = _get_extension(filename)
    return ext in SKIP_EXTENSIONS


def _get_extension(filename: str) -> str:
    """Get lowercase file extension."""
    if "." in filename:
        return "." + filename.rsplit(".", 1)[-1].lower()
    return ""
