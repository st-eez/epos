"""Read duration and content digest directly from saved Epos recordings."""

from __future__ import annotations

import hashlib
from pathlib import Path
import struct


FMT_HEADER = struct.Struct("<HHIIHH")


class HoldoutAudioError(ValueError):
    """A saved recording is not a readable RIFF/WAVE file."""


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def wav_duration_seconds(path: Path) -> float:
    """Duration in seconds from the RIFF header.

    Epos writes 48 kHz mono 32-bit float, which the standard `wave` module
    refuses to open, so the fmt and data chunks are parsed directly.
    """
    file_size = path.stat().st_size
    with path.open("rb") as stream:
        header = stream.read(12)
        if len(header) != 12 or header[:4] != b"RIFF" or header[8:12] != b"WAVE":
            raise HoldoutAudioError(f"{path.name}: not a RIFF/WAVE file")
        sample_rate = 0
        block_align = 0
        data_bytes: int | None = None
        while chunk_header := stream.read(8):
            if len(chunk_header) < 8:
                raise HoldoutAudioError(f"{path.name}: truncated chunk header")
            chunk_id, size = struct.unpack("<4sI", chunk_header)
            if chunk_id == b"fmt ":
                body = stream.read(size)
                if size < FMT_HEADER.size or len(body) != size:
                    raise HoldoutAudioError(f"{path.name}: truncated fmt chunk")
                _, _, sample_rate, _, block_align, _ = FMT_HEADER.unpack(
                    body[:FMT_HEADER.size]
                )
                stream.seek(size % 2, 1)
                continue
            if chunk_id == b"data":
                if data_bytes is not None:
                    raise HoldoutAudioError(f"{path.name}: repeated data chunk")
                data_bytes = size
            stream.seek(size + size % 2, 1)
    if data_bytes is None:
        raise HoldoutAudioError(f"{path.name}: no data chunk")
    if sample_rate <= 0 or block_align <= 0:
        raise HoldoutAudioError(f"{path.name}: no usable fmt chunk")
    if data_bytes > file_size:
        raise HoldoutAudioError(f"{path.name}: data chunk exceeds file size")
    return data_bytes / block_align / sample_rate
