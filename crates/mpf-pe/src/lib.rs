//! Minimal reader for PE images (Windows .exe / .dll): link timestamp, machine, sections, bytes at an RVA.
//! Read only; works on the file on disk (raw offsets) - the same layout the loaded image has per section.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Section {
    pub name: String,
    pub virtual_address: u32,
    pub virtual_size: u32,
    pub raw_offset: u32,
    pub raw_size: u32,
}

#[derive(Debug)]
pub enum PeError {
    NotPe(&'static str),
    Truncated,
}

impl fmt::Display for PeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PeError::NotPe(why) => write!(f, "not a PE image: {why}"),
            PeError::Truncated => write!(f, "PE image truncated"),
        }
    }
}

impl std::error::Error for PeError {}

pub struct Pe {
    pub data: Vec<u8>,
    pub machine: u16,
    pub timestamp: u32,
    pub sections: Vec<Section>,
}

fn u16_at(d: &[u8], o: usize) -> Result<u16, PeError> {
    d.get(o..o + 2).map(|b| u16::from_le_bytes([b[0], b[1]])).ok_or(PeError::Truncated)
}

fn u32_at(d: &[u8], o: usize) -> Result<u32, PeError> {
    d.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])).ok_or(PeError::Truncated)
}

impl Pe {
    pub fn parse(data: Vec<u8>) -> Result<Pe, PeError> {
        if data.get(0..2) != Some(b"MZ") {
            return Err(PeError::NotPe("no MZ header"));
        }
        let off = u32_at(&data, 0x3C)? as usize;
        if data.get(off..off + 4) != Some(b"PE\0\0") {
            return Err(PeError::NotPe("no PE signature"));
        }
        let machine = u16_at(&data, off + 4)?;
        let nsec = u16_at(&data, off + 6)? as usize;
        let timestamp = u32_at(&data, off + 8)?;
        let opt_size = u16_at(&data, off + 20)? as usize;
        let mut sections = Vec::with_capacity(nsec);
        let table = off + 24 + opt_size;
        for i in 0..nsec {
            let s = table + 40 * i;
            let raw_name = data.get(s..s + 8).ok_or(PeError::Truncated)?;
            let name = String::from_utf8_lossy(raw_name).trim_end_matches('\0').to_string();
            sections.push(Section {
                name,
                virtual_size: u32_at(&data, s + 8)?,
                virtual_address: u32_at(&data, s + 12)?,
                raw_size: u32_at(&data, s + 16)?,
                raw_offset: u32_at(&data, s + 20)?,
            });
        }
        Ok(Pe { data, machine, timestamp, sections })
    }

    pub fn open(path: &std::path::Path) -> Result<Pe, Box<dyn std::error::Error>> {
        Ok(Pe::parse(std::fs::read(path)?)?)
    }

    pub fn section(&self, name: &str) -> Option<&Section> {
        self.sections.iter().find(|s| s.name == name)
    }

    /// The code section (.text) as bytes, with its RVA.
    pub fn text(&self) -> Option<(u32, &[u8])> {
        let s = self.section(".text")?;
        let len = s.virtual_size.min(s.raw_size) as usize;
        let start = s.raw_offset as usize;
        self.data.get(start..start + len).map(|b| (s.virtual_address, b))
    }

    pub fn section_of(&self, rva: u32) -> Option<&Section> {
        self.sections
            .iter()
            .find(|s| rva >= s.virtual_address && rva < s.virtual_address + s.virtual_size.max(s.raw_size))
    }

    pub fn read(&self, rva: u32, n: usize) -> Option<&[u8]> {
        let s = self.section_of(rva)?;
        let start = (s.raw_offset + (rva - s.virtual_address)) as usize;
        self.data.get(start..start + n)
    }

    pub fn in_text(&self, rva: u32) -> bool {
        self.section(".text").is_some_and(|s| rva >= s.virtual_address && rva < s.virtual_address + s.virtual_size)
    }
}

/// Synthetic images for the tests of this crate and the crates that use it.
pub mod testimage {
    /// A tiny synthetic PE image: one .text section at RVA 0x1000 holding `code`.
    pub fn build(code: &[u8], timestamp: u32) -> Vec<u8> {
        let mut d = vec![0u8; 0x400];
        d[0..2].copy_from_slice(b"MZ");
        d[0x3C..0x40].copy_from_slice(&0x80u32.to_le_bytes());
        d[0x80..0x84].copy_from_slice(b"PE\0\0");
        d[0x84..0x86].copy_from_slice(&0x8664u16.to_le_bytes());
        d[0x86..0x88].copy_from_slice(&1u16.to_le_bytes());
        d[0x88..0x8C].copy_from_slice(&timestamp.to_le_bytes());
        d[0x94..0x96].copy_from_slice(&0xF0u16.to_le_bytes()); // optional header size
        let s = 0x80 + 24 + 0xF0;
        d[s..s + 8].copy_from_slice(b".text\0\0\0");
        d[s + 8..s + 12].copy_from_slice(&(code.len() as u32).to_le_bytes());
        d[s + 12..s + 16].copy_from_slice(&0x1000u32.to_le_bytes());
        d[s + 16..s + 20].copy_from_slice(&(code.len() as u32).to_le_bytes());
        d[s + 20..s + 24].copy_from_slice(&0x400u32.to_le_bytes());
        d.extend_from_slice(code);
        d
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_synthetic_image() {
        let pe = Pe::parse(testimage::build(&[0x90, 0xC3, 0xCC, 0xCC], 0x6ac50427)).unwrap();
        assert_eq!(pe.machine, 0x8664);
        assert_eq!(pe.timestamp, 0x6ac50427);
        assert_eq!(pe.sections.len(), 1);
        assert_eq!(pe.read(0x1001, 1), Some(&[0xC3u8][..]));
        assert!(pe.in_text(0x1003) && !pe.in_text(0x1004));
        assert_eq!(pe.text().unwrap(), (0x1000, &[0x90u8, 0xC3, 0xCC, 0xCC][..]));
    }

    #[test]
    fn rejects_garbage() {
        assert!(Pe::parse(vec![0; 100]).is_err());
        assert!(Pe::parse(b"MZ".to_vec()).is_err());
    }
}
