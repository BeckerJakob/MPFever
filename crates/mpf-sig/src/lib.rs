//! Byte signatures for code addresses that move between game builds.
//!
//! A signature is a byte pattern with wildcards (`??`) plus an offset: the address it stands for is
//! `start of the (unique) match + offset`. Wildcards cover what changes when code moves: rel32 displacements of
//! calls and jumps and RIP-relative memory displacements. Text form (one per line in signatures/*.txt):
//! `name<TAB>offset<TAB>48 89 5C 24 ?? ...`.
//!
//! `make` builds a signature for a known RVA of a known build (decoding the instructions around it with iced-x86)
//! and grows it until it is unique in the code section; `Signature::resolve` finds it again in any build.

use iced_x86::{Decoder, DecoderOptions, FlowControl, Instruction};
use mpf_pe::Pe;
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signature {
    pub name: String,
    pub offset: i32,
    pub bytes: Vec<Option<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SigError {
    Syntax(String),
    NoCode,
    NotFound(String),
    NotUnique(String, usize),
    CannotMake(String),
}

impl fmt::Display for SigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SigError::Syntax(s) => write!(f, "bad signature: {s}"),
            SigError::NoCode => write!(f, "no .text section"),
            SigError::NotFound(n) => write!(f, "{n}: not found"),
            SigError::NotUnique(n, k) => write!(f, "{n}: found {k} times"),
            SigError::CannotMake(n) => write!(f, "{n}: no unique signature within the size limit"),
        }
    }
}

impl std::error::Error for SigError {}

pub fn parse_pattern(text: &str) -> Result<Vec<Option<u8>>, SigError> {
    text.split_whitespace()
        .map(|t| {
            if t == "??" || t == "?" {
                Ok(None)
            } else {
                u8::from_str_radix(t, 16).map(Some).map_err(|_| SigError::Syntax(t.to_string()))
            }
        })
        .collect()
}

pub fn pattern_text(bytes: &[Option<u8>]) -> String {
    bytes
        .iter()
        .map(|b| match b {
            Some(v) => format!("{v:02X}"),
            None => "??".to_string(),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

impl Signature {
    /// `name<TAB>offset<TAB>pattern`
    pub fn parse_line(line: &str) -> Result<Signature, SigError> {
        let mut parts = line.splitn(3, '\t');
        let name = parts.next().unwrap_or("").trim().to_string();
        let offset = parts
            .next()
            .ok_or_else(|| SigError::Syntax(line.to_string()))?
            .trim()
            .parse::<i32>()
            .map_err(|_| SigError::Syntax(line.to_string()))?;
        let bytes = parse_pattern(parts.next().ok_or_else(|| SigError::Syntax(line.to_string()))?)?;
        if name.is_empty() || bytes.iter().all(|b| b.is_none()) {
            return Err(SigError::Syntax(line.to_string()));
        }
        Ok(Signature { name, offset, bytes })
    }

    pub fn to_line(&self) -> String {
        format!("{}\t{}\t{}", self.name, self.offset, pattern_text(&self.bytes))
    }

    /// Every position in `code` where the pattern matches. Scans for its rarest fixed byte (by `freq`, the byte
    /// counts of `code`) and checks the whole pattern there.
    pub fn find_all(&self, code: &[u8], freq: &[usize; 256]) -> Vec<usize> {
        find_all(&self.bytes, code, freq)
    }

    /// The RVA this signature stands for in `pe`: its match must be unique.
    pub fn resolve(&self, pe: &Pe, freq: &[usize; 256]) -> Result<u32, SigError> {
        let (base, code) = pe.text().ok_or(SigError::NoCode)?;
        let hits = self.find_all(code, freq);
        match hits.len() {
            0 => Err(SigError::NotFound(self.name.clone())),
            1 => Ok((base as i64 + hits[0] as i64 + self.offset as i64) as u32),
            k => Err(SigError::NotUnique(self.name.clone(), k)),
        }
    }
}

pub fn byte_freq(code: &[u8]) -> [usize; 256] {
    let mut f = [0usize; 256];
    for &b in code {
        f[b as usize] += 1;
    }
    f
}

pub fn find_all(pat: &[Option<u8>], code: &[u8], freq: &[usize; 256]) -> Vec<usize> {
    let mut out = Vec::new();
    // the fixed byte that occurs least often in the code: fewest candidate positions
    let Some((key, kb)) = pat
        .iter()
        .enumerate()
        .filter_map(|(i, b)| b.map(|v| (i, v)))
        .min_by_key(|&(_, v)| freq[v as usize])
    else {
        return out;
    };
    if code.len() < pat.len() {
        return out;
    }
    let last = code.len() - pat.len();
    let mut i = key;
    while i <= last + key {
        match code[i..=last + key].iter().position(|&c| c == kb) {
            None => break,
            Some(p) => {
                let at = i + p - key;
                if pat.iter().enumerate().all(|(j, b)| b.is_none_or(|v| code[at + j] == v)) {
                    out.push(at);
                }
                i += p + 1;
            }
        }
    }
    out
}

/// The bytes of the instruction, with the parts that move with the code as wildcards: the rel32 of a near call or
/// jump, the displacement of a RIP-relative memory operand.
fn masked(code: &[u8], at: usize, ins: &Instruction, consts: &iced_x86::ConstantOffsets) -> Vec<Option<u8>> {
    let len = ins.len();
    let mut out: Vec<Option<u8>> = code[at..at + len].iter().map(|&b| Some(b)).collect();
    let near_branch = matches!(
        ins.flow_control(),
        FlowControl::Call | FlowControl::UnconditionalBranch | FlowControl::ConditionalBranch
    ) && ins.is_ip_rel_memory_operand() == false
        && (ins.is_call_near() || ins.is_jmp_near() || ins.is_jcc_near());
    if near_branch && len >= 5 {
        // a rel8 branch (2 bytes) stays fixed; a rel32 one ends with its displacement
        for b in out.iter_mut().skip(len - 4) {
            *b = None;
        }
    }
    if ins.is_ip_rel_memory_operand() && consts.has_displacement() {
        let o = consts.displacement_offset();
        let n = consts.displacement_size();
        for b in out.iter_mut().skip(o).take(n) {
            *b = None;
        }
    }
    out
}

/// A unique signature for `rva` of `pe`. It starts at `rva` when that is a function entry (`entry`), else at one of
/// the instruction starts found by decoding from a little before it (return addresses, addresses inside functions).
pub fn make(pe: &Pe, name: &str, rva: u32, entry: bool, freq: &[usize; 256]) -> Result<Signature, SigError> {
    let (base, code) = pe.text().ok_or(SigError::NoCode)?;
    if rva < base || (rva - base) as usize >= code.len() {
        return Err(SigError::CannotMake(format!("{name}: rva {rva:#x} outside .text")));
    }
    let target = (rva - base) as usize;
    // inside a function, anchors before the target first: the instruction before a return address (the call) is
    // what identifies the site; the target itself is the last resort
    let backs: Vec<usize> = if entry { vec![0] } else { vec![16, 12, 10, 8, 20, 24, 32, 40, 48, 5, 0] };
    for back in backs {
        if back > target {
            continue;
        }
        let anchor = target - back;
        let mut decoder = Decoder::with_ip(64, &code[anchor..], (base as u64) + anchor as u64, DecoderOptions::NONE);
        let mut pat: Vec<Option<u8>> = Vec::new();
        let mut pos = anchor;
        let mut reached = back == 0;
        let mut ins = Instruction::default();
        while decoder.can_decode() && pat.len() < 96 {
            decoder.decode_out(&mut ins);
            if ins.is_invalid() {
                break;
            }
            let consts = decoder.get_constant_offsets(&ins);
            pat.extend(masked(code, pos, &ins, &consts));
            pos += ins.len();
            if pos == target {
                reached = true;
            }
            if pos > target && !reached {
                break; // this anchor's decoding does not line up with the target
            }
            // long enough to cover the target and unique: done
            if reached && pos > target && pat.len() >= 12 && find_all(&pat, code, freq).len() == 1 {
                return Ok(Signature { name: name.to_string(), offset: back as i32, bytes: pat });
            }
        }
    }
    Err(SigError::CannotMake(name.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use mpf_pe::testimage;

    fn image(code: &[u8]) -> (Pe, [usize; 256]) {
        let pe = Pe::parse(testimage::build(code, 1)).unwrap();
        let f = byte_freq(pe.text().unwrap().1);
        (pe, f)
    }

    #[test]
    fn pattern_roundtrip() {
        let p = parse_pattern("48 89 ?? 24 0a").unwrap();
        assert_eq!(p, vec![Some(0x48), Some(0x89), None, Some(0x24), Some(0x0A)]);
        assert_eq!(pattern_text(&p), "48 89 ?? 24 0A");
        assert!(parse_pattern("48 zz").is_err());
        let s = Signature::parse_line("add\t3\t48 ?? 5C").unwrap();
        assert_eq!(Signature::parse_line(&s.to_line()).unwrap(), s);
        assert!(Signature::parse_line("x\t0\t?? ??").is_err());
    }

    #[test]
    fn find_with_wildcards() {
        let code = [0x90, 0x48, 0x89, 0x5C, 0x24, 0x48, 0x89, 0x11, 0x24, 0xC3];
        let f = byte_freq(&code);
        assert_eq!(find_all(&parse_pattern("48 89 ?? 24").unwrap(), &code, &f), vec![1, 5]);
        assert_eq!(find_all(&parse_pattern("48 89 5C 24").unwrap(), &code, &f), vec![1]);
        assert_eq!(find_all(&parse_pattern("24 C3").unwrap(), &code, &f), vec![8]);
        assert!(find_all(&parse_pattern("C3 90").unwrap(), &code, &f).is_empty());
    }

    // two functions that differ only after their first instructions; calls with different rel32 targets
    const CODE: [u8; 48] = [
        // f1 @0x1000: push rbx; sub rsp,20h; call rel32; mov eax,[rip+disp32]; pop rbx; ret
        0x53, 0x48, 0x83, 0xEC, 0x20, 0xE8, 0x11, 0x22, 0x33, 0x44, 0x8B, 0x05, 0x01, 0x02, 0x03, 0x04, 0x5B, 0xC3,
        0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC,
        // f2 @0x1018: push rbx; sub rsp,20h; call rel32; mov eax,ecx; pop rbx; ret
        0x53, 0x48, 0x83, 0xEC, 0x20, 0xE8, 0x55, 0x66, 0x77, 0x00, 0x8B, 0xC1, 0x5B, 0xC3, 0xCC, 0xCC, 0xCC, 0xCC,
        0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC,
    ];

    #[test]
    fn make_entry_signature_masks_moving_bytes() {
        let (pe, f) = image(&CODE);
        let s = make(&pe, "f1", 0x1000, true, &f).unwrap();
        assert_eq!(s.offset, 0);
        // the call's rel32 and the RIP-relative displacement are wildcards
        assert_eq!(&s.bytes[5..10], &[Some(0xE8), None, None, None, None]);
        assert_eq!(&s.bytes[10..16], &[Some(0x8B), Some(0x05), None, None, None, None]);
        assert_eq!(s.resolve(&pe, &f).unwrap(), 0x1000);
        let s2 = make(&pe, "f2", 0x1018, true, &f).unwrap();
        assert_eq!(s2.resolve(&pe, &f).unwrap(), 0x1018);
    }

    #[test]
    fn make_signature_for_a_return_address() {
        let (pe, f) = image(&CODE);
        // the return address of f2's call (0x1018 + 10)
        let s = make(&pe, "ret", 0x1022, false, &f).unwrap();
        assert!(s.offset > 0);
        assert_eq!(s.resolve(&pe, &f).unwrap(), 0x1022);
    }

    #[test]
    fn signature_survives_moved_call_targets() {
        let (pe, f) = image(&CODE);
        let s = make(&pe, "f1", 0x1000, true, &f).unwrap();
        // the "next build": the call and the global moved
        let mut moved = CODE;
        moved[6..10].copy_from_slice(&[0x99, 0x88, 0x77, 0x66]);
        moved[12..16].copy_from_slice(&[0x10, 0x20, 0x30, 0x40]);
        let (pe2, f2) = image(&moved);
        assert_eq!(s.resolve(&pe2, &f2).unwrap(), 0x1000);
    }

    #[test]
    fn non_unique_and_missing_are_errors() {
        let (pe, f) = image(&CODE);
        let s = Signature { name: "both".into(), offset: 0, bytes: parse_pattern("53 48 83 EC 20 E8").unwrap() };
        assert_eq!(s.resolve(&pe, &f), Err(SigError::NotUnique("both".into(), 2)));
        let m = Signature { name: "none".into(), offset: 0, bytes: parse_pattern("0F 0B 0F 0B").unwrap() };
        assert_eq!(m.resolve(&pe, &f), Err(SigError::NotFound("none".into())));
    }
}
