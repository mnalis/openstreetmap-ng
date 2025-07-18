import struct
from typing import TypeVar, overload

import cython
import numpy as np
from numpy.typing import NDArray
from shapely import transform
from shapely.geometry.base import BaseGeometry

if cython.compiled:
    from cython.cimports.libc.math import ceil, log2
else:
    from math import ceil, log2

_GeomT = TypeVar('_GeomT', bound=BaseGeometry)


@cython.cfunc
def _create_mentissa_mask():
    max_number: cython.double = 180
    fractional_precision: cython.double = 7

    bits_for_precision: cython.ulonglong = int(  # noqa: RUF046
        ceil(log2(max_number * 10**fractional_precision) + 1)
    )

    full_mask: cython.ulonglong = (1 << 64) - 1
    zeros_mask: cython.ulonglong = (1 << (52 - bits_for_precision)) - 1

    return np.uint64(full_mask - zeros_mask)


_MASK: np.uint64 = _create_mentissa_mask()


@overload
def compressible_geometry(geometry: _GeomT, /) -> _GeomT: ...
@overload
def compressible_geometry(geometry: NDArray[np.float64], /) -> NDArray[np.float64]: ...
def compressible_geometry(
    geometry: _GeomT | NDArray[np.float64], /
) -> _GeomT | NDArray[np.float64]:
    """
    Make geometry easily compressible by reducing mentissa noise.
    It is then necessary to round the coordinates back.
    Inspired by http://www.danbaston.com/posts/2018/02/15/optimizing-postgis-geometries.html
    """
    if isinstance(geometry, BaseGeometry):
        return transform(geometry, compressible_geometry)
    view = geometry.view(np.uint64)
    view &= _MASK
    return geometry


_POINT_STRUCT = struct.Struct('<dd')
_BBOX_STRUCT = struct.Struct('<dddddddddd')


def point_to_compressible_wkb(lon: float, lat: float) -> bytes:
    """Convert a coordinate pair to a compressible WKB hex format."""
    lon, lat = compressible_geometry(np.array([lon, lat], dtype=np.float64)).tolist()

    # (byte order 1 = little endian + geometry type 1 = Point)
    return b'\x01\x01\x00\x00\x00' + _POINT_STRUCT.pack(lon, lat)


def bbox_to_compressible_wkb(
    minlon: float, minlat: float, maxlon: float, maxlat: float
) -> bytes:
    """Convert a bounding box to a compressible WKB hex format."""
    minlon, minlat, maxlon, maxlat = compressible_geometry(
        np.array([minlon, minlat, maxlon, maxlat], dtype=np.float64)
    ).tolist()

    # (byte order 1 = little endian + geometry type 1 = Point + 1 ring + 5 points)
    return b'\x01\x03\x00\x00\x00\x01\x00\x00\x00\x05\x00\x00\x00' + _BBOX_STRUCT.pack(
        maxlon, minlat, maxlon, maxlat, minlon, maxlat, minlon, minlat, maxlon, minlat
    )
