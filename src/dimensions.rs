//! Pixel sizes of pictures and clips, read from their headers, so the phone
//! can give each one its final frame before its bytes arrive. PNG (Apple's
//! optimised PNG included), JPEG, GIF, and MP4/QuickTime video (the first
//! track with a picture, turned as it plays). Anything else is unknown.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// Width and height in pixels, as shown.
pub fn read(path: &Path) -> Option<(u32, u32)> {
    let mut file = File::open(path).ok()?;
    let mut head = vec![0; 64 << 10];
    let count = read_up_to(&mut file, &mut head)?;
    head.truncate(count);
    if head.starts_with(b"\x89PNG\r\n\x1a\n") {
        return png(&head);
    }
    if head.starts_with(&[0xFF, 0xD8]) {
        return jpeg(&head);
    }
    if head.starts_with(b"GIF8") && head.len() >= 10 {
        return nonzero(
            u16::from_le_bytes([head[6], head[7]]).into(),
            u16::from_le_bytes([head[8], head[9]]).into(),
        );
    }
    if head.len() >= 8 && matches!(&head[4..8], b"ftyp" | b"moov" | b"mdat" | b"wide" | b"free") {
        return movie(&mut file);
    }
    None
}

fn read_up_to(file: &mut File, buffer: &mut [u8]) -> Option<usize> {
    let mut filled = 0;
    while filled < buffer.len() {
        match file.read(&mut buffer[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(_) => return None,
        }
    }
    Some(filled)
}

fn nonzero(width: u32, height: u32) -> Option<(u32, u32)> {
    (width > 0 && height > 0).then_some((width, height))
}

fn be32(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

fn be16(bytes: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_be_bytes(bytes.get(at..at + 2)?.try_into().ok()?))
}

/// The IHDR chunk, wherever it is (Apple's PNGs put CgBI first).
fn png(bytes: &[u8]) -> Option<(u32, u32)> {
    let mut at = 8;
    while at + 8 <= bytes.len() {
        let length = be32(bytes, at)? as usize;
        if &bytes[at + 4..at + 8] == b"IHDR" {
            return nonzero(be32(bytes, at + 8)?, be32(bytes, at + 12)?);
        }
        at = at.checked_add(12 + length)?;
    }
    None
}

/// The first start-of-frame marker.
fn jpeg(bytes: &[u8]) -> Option<(u32, u32)> {
    let mut at = 2;
    while at + 4 <= bytes.len() {
        if bytes[at] != 0xFF {
            return None;
        }
        let marker = bytes[at + 1];
        if marker == 0xFF {
            at += 1;
            continue;
        }
        if matches!(marker, 0xD0..=0xD9 | 0x01) {
            at += 2;
            continue;
        }
        let length = be16(bytes, at + 2)? as usize;
        if matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC) {
            return nonzero(be16(bytes, at + 7)?.into(), be16(bytes, at + 5)?.into());
        }
        at += 2 + length;
    }
    None
}

/// Walks the boxes to `moov` (often at the end), then its tracks' headers.
fn movie(file: &mut File) -> Option<(u32, u32)> {
    let end = file.seek(SeekFrom::End(0)).ok()?;
    let mut at = 0;
    while at + 8 <= end {
        file.seek(SeekFrom::Start(at)).ok()?;
        let mut header = [0; 16];
        let count = read_up_to(file, &mut header)?;
        if count < 8 {
            return None;
        }
        let mut size = u64::from(be32(&header, 0)?);
        if size == 1 && count == 16 {
            size = u64::from_be_bytes(header[8..16].try_into().ok()?);
        } else if size == 0 {
            size = end - at;
        }
        if size < 8 {
            return None;
        }
        if &header[4..8] == b"moov" {
            // Track headers are small; a huge moov is not worth reading whole.
            let length = usize::try_from(size.min(16 << 20)).ok()?;
            let mut moov = vec![0; length];
            file.seek(SeekFrom::Start(at)).ok()?;
            let count = read_up_to(file, &mut moov)?;
            return tracks(&moov[8.min(count)..count]);
        }
        at = at.checked_add(size)?;
    }
    None
}

fn children(bytes: &[u8]) -> impl Iterator<Item = (&[u8], &[u8])> {
    let mut at = 0;
    std::iter::from_fn(move || {
        let size = be32(bytes, at)? as usize;
        if size < 8 || at + size > bytes.len() {
            return None;
        }
        let kind = &bytes[at + 4..at + 8];
        let body = &bytes[at + 8..at + size];
        at += size;
        Some((kind, body))
    })
}

fn tracks(moov: &[u8]) -> Option<(u32, u32)> {
    for (_, trak) in children(moov).filter(|(kind, _)| *kind == b"trak") {
        let Some((_, tkhd)) = children(trak).find(|(kind, _)| *kind == b"tkhd") else {
            continue;
        };
        // Version 1 widens the times and duration to 64 bits.
        let matrix = if tkhd.first() == Some(&1) { 52 } else { 40 };
        let (Some(a), Some(b)) = (be32(tkhd, matrix), be32(tkhd, matrix + 4)) else {
            continue;
        };
        let (Some(width), Some(height)) = (be32(tkhd, matrix + 36), be32(tkhd, matrix + 40)) else {
            continue;
        };
        let (width, height) = (width >> 16, height >> 16);
        if width == 0 || height == 0 {
            continue;
        }
        // A quarter turn: a is 0 and b is ±1 in 16.16.
        let turned = a == 0 && (b == 0x0001_0000 || b == 0xFFFF_0000);
        return Some(if turned {
            (height, width)
        } else {
            (width, height)
        });
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_with_apple_chunk_first() {
        let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
        bytes.extend([0, 0, 0, 4]);
        bytes.extend(b"CgBI");
        bytes.extend([0x50, 0, 0x20, 0x06, 0, 0, 0, 0]);
        bytes.extend([0, 0, 0, 13]);
        bytes.extend(b"IHDR");
        bytes.extend(120u32.to_be_bytes());
        bytes.extend(260u32.to_be_bytes());
        assert_eq!(png(&bytes), Some((120, 260)));
    }

    #[test]
    fn jpeg_skips_segments_to_the_frame() {
        let mut bytes = vec![0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0];
        bytes.extend([0xFF, 0xC0, 0, 11, 8]);
        bytes.extend(1080u16.to_be_bytes());
        bytes.extend(1920u16.to_be_bytes());
        assert_eq!(jpeg(&bytes), Some((1920, 1080)));
    }

    #[test]
    fn turned_video_track_swaps() {
        let mut tkhd = vec![0u8; 84];
        tkhd[44..48].copy_from_slice(&0x0001_0000u32.to_be_bytes());
        tkhd[76..80].copy_from_slice(&(1920u32 << 16).to_be_bytes());
        tkhd[80..84].copy_from_slice(&(1080u32 << 16).to_be_bytes());
        let mut trak = (8 + tkhd.len() as u32).to_be_bytes().to_vec();
        trak.extend(b"tkhd");
        trak.extend(&tkhd);
        let mut moov = (8 + trak.len() as u32).to_be_bytes().to_vec();
        moov.extend(b"trak");
        moov.extend(&trak);
        assert_eq!(tracks(&moov), Some((1080, 1920)));
    }
}
