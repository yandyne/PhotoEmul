"""Adobe Camera Raw / Lightroom RGB table codec.

Implements the binary layout of ``dng_rgb_table`` (Adobe DNG SDK,
``dng_big_table.cpp``) as stored in XMP "Look" profiles:

    crs:RGBTable="<MD5 fingerprint>"
    crs:Table_<MD5 fingerprint>="<base85 text>"

Stream layout (little endian):
    uint32 type (1 = RGBTable)
    uint32 version (1)
    uint32 dimensions (3)
    uint32 divisions (2..32)
    divisions^3 x (uint16 r, g, b) deltas from the identity grid,
        loop order r (outer), g, b (inner)
    uint32 primaries, uint32 gamma, uint32 gamut
    float64 min_amount, float64 max_amount
    [uint32 flags]   (only written when non-zero)

The fingerprint is the MD5 of the uncompressed stream. The stored text is
``uint32 uncompressed size`` + zlib payload, encoded with Adobe's Z85-like
alphabet (little-endian 32-bit groups, least significant digit first).
"""
from __future__ import annotations

import hashlib
import struct
import zlib
from dataclasses import dataclass

import numpy as np

BTT_RGB_TABLE = 1
RGB_TABLE_VERSION = 1
MAX_DIVISIONS_3D = 32

PRIMARIES = {"sRGB": 0, "AdobeRGB": 1, "ProPhoto": 2, "P3": 3, "Rec2020": 4}
GAMMAS = {"linear": 0, "sRGB": 1, "1.8": 2, "2.2": 3, "Rec2020": 4}
GAMUTS = {"clip": 0, "extend": 1}

_ALPHABET = (
    "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    ".-:+=^!/*?`'|()[]{}@%$#"
)
_DECODE = {c: i for i, c in enumerate(_ALPHABET)}


@dataclass
class RGBTable:
    """A 3D RGB table. ``samples[r, g, b] -> (R, G, B)`` in [0, 1]."""

    samples: np.ndarray
    primaries: str = "sRGB"
    gamma: str = "sRGB"
    gamut: str = "clip"
    min_amount: float = 0.0
    max_amount: float = 2.0
    flags: int = 0

    @property
    def divisions(self) -> int:
        return self.samples.shape[0]


def _nop_values(divisions: int) -> np.ndarray:
    index = np.arange(divisions, dtype=np.int64)
    return ((index * 0xFFFF + (divisions >> 1)) // (divisions - 1)).astype(np.int64)


def to_stream(table: RGBTable) -> bytes:
    n = table.divisions
    if not 2 <= n <= MAX_DIVISIONS_3D:
        raise ValueError(f"divisions must be in [2, {MAX_DIVISIONS_3D}], got {n}")
    if table.samples.shape != (n, n, n, 3):
        raise ValueError(f"samples must have shape (n, n, n, 3), got {table.samples.shape}")

    values = np.rint(np.clip(table.samples, 0.0, 1.0) * 0xFFFF).astype(np.int64)
    nop = _nop_values(n)
    deltas = values.copy()
    deltas[..., 0] -= nop[:, None, None]
    deltas[..., 1] -= nop[None, :, None]
    deltas[..., 2] -= nop[None, None, :]
    payload = (deltas & 0xFFFF).astype("<u2").tobytes()

    head = struct.pack("<4I", BTT_RGB_TABLE, RGB_TABLE_VERSION, 3, n)
    tail = struct.pack(
        "<3I2d",
        PRIMARIES[table.primaries],
        GAMMAS[table.gamma],
        GAMUTS[table.gamut],
        table.min_amount,
        table.max_amount,
    )
    if table.flags:
        tail += struct.pack("<I", table.flags)
    return head + payload + tail


def from_stream(data: bytes) -> RGBTable:
    btt, version, dims, n = struct.unpack_from("<4I", data, 0)
    if btt != BTT_RGB_TABLE or version != RGB_TABLE_VERSION:
        raise ValueError(f"not an RGB table (type={btt}, version={version})")
    if dims != 3:
        raise ValueError(f"only 3D tables are supported (dimensions={dims})")
    offset = 16
    count = n * n * n * 3
    deltas = np.frombuffer(data, dtype="<u2", count=count, offset=offset).astype(np.int64)
    offset += count * 2
    values = deltas.reshape(n, n, n, 3)
    nop = _nop_values(n)
    values = values.copy()
    values[..., 0] += nop[:, None, None]
    values[..., 1] += nop[None, :, None]
    values[..., 2] += nop[None, None, :]
    values &= 0xFFFF
    primaries, gamma, gamut, min_amount, max_amount = struct.unpack_from("<3I2d", data, offset)
    offset += struct.calcsize("<3I2d")
    flags = struct.unpack_from("<I", data, offset)[0] if offset + 4 <= len(data) else 0
    inverse = lambda d, v: next(k for k, x in d.items() if x == v)  # noqa: E731
    return RGBTable(
        samples=values.astype(np.float64) / 0xFFFF,
        primaries=inverse(PRIMARIES, primaries),
        gamma=inverse(GAMMAS, gamma),
        gamut=inverse(GAMUTS, gamut),
        min_amount=min_amount,
        max_amount=max_amount,
        flags=flags,
    )


def fingerprint(stream: bytes) -> str:
    return hashlib.md5(stream).hexdigest().upper()


def encode_text(stream: bytes) -> str:
    """zlib-compress and base85-encode an uncompressed table stream."""
    block = struct.pack("<I", len(stream)) + zlib.compress(stream, 6)
    size = len(block)
    padded = block + b"\x00\x00\x00"
    out = []
    for pos in range(0, size, 4):
        x = int.from_bytes(padded[pos:pos + 4], "little")
        remaining = size - pos
        digits = 5 if remaining >= 4 else remaining + 1
        for _ in range(digits):
            out.append(_ALPHABET[x % 85])
            x //= 85
    return "".join(out)


def decode_text(text: str) -> bytes:
    """Inverse of :func:`encode_text`; returns the uncompressed stream."""
    raw = bytearray()
    for pos in range(0, len(text), 5):
        group = text[pos:pos + 5]
        x = 0
        for ch in reversed(group):
            x = x * 85 + _DECODE[ch]
        nbytes = len(group) - 1 if len(group) < 5 else 4
        raw += (x & 0xFFFFFFFF).to_bytes(4, "little")[:nbytes]
    size = int.from_bytes(raw[:4], "little")
    stream = zlib.decompress(bytes(raw[4:]))
    if len(stream) != size:
        raise ValueError(f"size mismatch: header {size}, decompressed {len(stream)}")
    return stream


def identity_samples(divisions: int) -> np.ndarray:
    axis = _nop_values(divisions) / 0xFFFF
    r, g, b = np.meshgrid(axis, axis, axis, indexing="ij")
    return np.stack([r, g, b], axis=-1)
