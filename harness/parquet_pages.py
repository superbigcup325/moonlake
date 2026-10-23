"""Read Parquet page headers, so evidence can name the page, not just the footer.

`parquet_metadata()` / PyArrow's `ColumnChunkMetaData.encodings` report what the
*footer* lists; the corpus audit already learned that lesson when a footer-only
`count(*)` counted 18 undecodable files as reads. Page headers are Thrift
compact structs at `dictionary_page_offset` / `data_page_offset`, each followed
by its compressed payload, so a few dozen lines walk a column chunk and report
(page type, encoding, num_values, page version) for every page.

This is a dev-only, dependency-free parser (stdlib only); PyArrow supplies the
chunk offsets because re-implementing the footer parser would be a second bug
surface, not more evidence.
"""

from __future__ import annotations

import pathlib
import struct

# parquet.thrift enums
PAGE_TYPES = {0: "DATA_PAGE", 1: "INDEX_PAGE", 2: "DICTIONARY_PAGE", 3: "DATA_PAGE_V2"}
ENCODINGS = {
    0: "PLAIN",
    2: "PLAIN_DICTIONARY",
    3: "RLE",
    4: "BIT_PACKED",
    5: "DELTA_BINARY_PACKED",
    6: "DELTA_LENGTH_BYTE_ARRAY",
    7: "DELTA_BYTE_ARRAY",
    8: "RLE_DICTIONARY",
    9: "BYTE_STREAM_SPLIT",
}

# Thrift compact protocol field types
BOOL_TRUE, BOOL_FALSE, BYTE, I16, I32, I64, DOUBLE, BINARY, LIST, SET, MAP, STRUCT = range(1, 13)


class CompactReader:
    """Just enough Thrift compact protocol to walk a PageHeader struct."""

    def __init__(self, data: bytes, pos: int = 0):
        self.data = data
        self.pos = pos

    def byte(self) -> int:
        if self.pos >= len(self.data):
            raise ValueError("truncated page header")
        value = self.data[self.pos]
        self.pos += 1
        return value

    def varint(self) -> int:
        shift = 0
        result = 0
        while True:
            b = self.byte()
            result |= (b & 0x7F) << shift
            if not b & 0x80:
                return result
            shift += 7
            if shift > 63:
                raise ValueError("varint too long")

    def zigzag(self) -> int:
        value = self.varint()
        return (value >> 1) ^ -(value & 1)

    def value(self, ttype: int):
        if ttype == BOOL_TRUE:
            return True
        if ttype == BOOL_FALSE:
            return False
        if ttype == BYTE:
            b = self.byte()
            return b - 256 if b > 127 else b
        if ttype in (I16, I32, I64):
            return self.zigzag()
        if ttype == DOUBLE:
            raw = self.data[self.pos : self.pos + 8]
            if len(raw) != 8:
                raise ValueError("truncated double")
            self.pos += 8
            return struct.unpack("<d", raw)[0]
        if ttype == BINARY:
            length = self.varint()
            raw = self.data[self.pos : self.pos + length]
            if len(raw) != length:
                raise ValueError("truncated binary field")
            self.pos += length
            return raw
        if ttype in (LIST, SET):
            header = self.byte()
            size = header >> 4
            etype = header & 0x0F
            if size == 15:
                size = self.varint()
            return [self.value(etype) for _ in range(size)]
        if ttype == MAP:
            size = self.varint()
            if size == 0:
                return {}
            kv = self.byte()
            ktype, vtype = kv >> 4, kv & 0x0F
            return {self.value(ktype): self.value(vtype) for _ in range(size)}
        if ttype == STRUCT:
            return self.struct()
        raise ValueError(f"unsupported thrift compact type {ttype}")

    def struct(self) -> dict[int, object]:
        fields: dict[int, object] = {}
        last_fid = 0
        while True:
            header = self.byte()
            if header == 0:
                return fields
            delta = header >> 4
            ttype = header & 0x0F
            fid = last_fid + (delta if delta else self.zigzag())
            last_fid = fid
            fields[fid] = self.value(ttype)


def parse_pages(data: bytes, start: int, length: int) -> list[dict]:
    """Walk one column chunk's pages from `start` for `length` bytes."""
    pages: list[dict] = []
    pos = start
    end = start + length
    while pos < end:
        reader = CompactReader(data, pos)
        header = reader.struct()
        payload_start = reader.pos
        compressed = header.get(3)
        if not isinstance(compressed, int) or compressed < 0:
            raise ValueError(f"page header at {pos} has no compressed_page_size")
        page_type = PAGE_TYPES.get(header.get(1), f"type {header.get(1)}")
        page = {
            "type": page_type,
            "compressed_size": compressed,
            "uncompressed_size": header.get(2),
        }
        if page_type == "DATA_PAGE":
            info = header.get(5) or {}
            page.update(
                version=1,
                num_values=info.get(1),
                encoding=ENCODINGS.get(info.get(2), f"encoding {info.get(2)}"),
                definition_level_encoding=ENCODINGS.get(info.get(3)),
                repetition_level_encoding=ENCODINGS.get(info.get(4)),
            )
        elif page_type == "DATA_PAGE_V2":
            info = header.get(8) or {}
            page.update(version=2, num_values=info.get(1), encoding=ENCODINGS.get(info.get(4), f"encoding {info.get(4)}"))
        elif page_type == "DICTIONARY_PAGE":
            info = header.get(7) or {}
            page.update(num_values=info.get(1), encoding=ENCODINGS.get(info.get(2), f"encoding {info.get(2)}"))
        pages.append(page)
        pos = payload_start + compressed
    return pages


def column_pages(path: pathlib.Path) -> dict[str, list[dict]]:
    """Every page of every column chunk in `path`, keyed by column path."""
    import pyarrow.parquet as pq

    data = pathlib.Path(path).read_bytes()
    meta = pq.ParquetFile(path).metadata
    out: dict[str, list[dict]] = {}
    for group_index in range(meta.num_row_groups):
        group = meta.row_group(group_index)
        for col_index in range(group.num_columns):
            chunk = group.column(col_index)
            # total_compressed_size covers every page in the chunk including
            # the dictionary page, so it starts at dictionary_page_offset when
            # there is one.
            start = chunk.dictionary_page_offset or chunk.data_page_offset
            length = chunk.total_compressed_size
            pages = parse_pages(data, start, length)
            out.setdefault(chunk.path_in_schema, []).extend(pages)
    return out


def encoding_names(path: pathlib.Path) -> dict[str, set[str]]:
    """The encodings that data pages actually carry, per column (not the footer)."""
    out: dict[str, set[str]] = {}
    for column, pages in column_pages(path).items():
        out[column] = {p["encoding"] for p in pages if p["type"] in ("DATA_PAGE", "DATA_PAGE_V2")}
    return out


def page_versions(path: pathlib.Path) -> dict[str, set[int]]:
    out: dict[str, set[int]] = {}
    for column, pages in column_pages(path).items():
        out[column] = {p["version"] for p in pages if p["type"] in ("DATA_PAGE", "DATA_PAGE_V2")}
    return out
