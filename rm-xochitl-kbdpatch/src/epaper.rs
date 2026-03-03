use anyhow::{anyhow, bail, Context, Result};
use goblin::elf::Elf;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs;
use std::fs::OpenOptions;
use std::io::{Seek, SeekFrom, Write};
use std::path::Path;

// Physical keycodes for letter rows (Linux input keycodes)
const ROW0: [u16; 11] = [16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26]; // Q..[
const ROW1: [u16; 11] = [30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40]; // A..'
const ROW2: [u16; 7] = [44, 45, 46, 47, 48, 49, 50]; // Z..M

const EPAPER_STATE_SCHEMA: &str = "epaper-state-v1";

#[derive(Serialize, Deserialize, Debug, Clone)]
struct EpaperState {
    #[serde(default)]
    schema: String,
    orig_sha: String,
    patched_sha: String,
    override_sha: String,
    locale: String,
}

#[derive(Clone, Debug)]
struct SymPick {
    name: String,
    shndx: usize,
    value: u64,
    size: u64,
}

#[derive(Copy, Clone, Debug)]
enum UniFmt {
    U16,
    U32,
}

#[derive(Copy, Clone, Debug)]
struct Layout {
    name: &'static str,
    entry_size: usize,
    key_off: usize,
    uni_off: usize,
    uni_fmt: UniFmt,
    mods_off: usize,
}

const LAYOUTS: [Layout; 3] = [
    Layout { name: "16_u16", entry_size: 16, key_off: 0, uni_off: 2, uni_fmt: UniFmt::U16, mods_off: 8 },
    Layout { name: "16_u32", entry_size: 16, key_off: 0, uni_off: 4, uni_fmt: UniFmt::U32, mods_off: 12 },
    Layout { name: "12_u16", entry_size: 12, key_off: 0, uni_off: 2, uni_fmt: UniFmt::U16, mods_off: 8 },
];

pub fn override_sha(over_min: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(over_min);
    h.update(EPAPER_STATE_SCHEMA.as_bytes());
    hex::encode(h.finalize())
}

fn read_state(path: &Path) -> Option<EpaperState> {
    let txt = fs::read_to_string(path).ok()?;
    serde_json::from_str::<EpaperState>(&txt).ok()
}

fn write_state(path: &Path, st: &EpaperState) -> Result<()> {
    if let Some(p) = path.parent() {
        fs::create_dir_all(p).ok();
    }
    let b = serde_json::to_vec_pretty(st)?;
    fs::write(path, b)?;
    Ok(())
}

fn ensure_backup_named(src: &Path, backup_dir: &Path, sha: &str) -> Result<()> {
    fs::create_dir_all(backup_dir).ok();
    let dst = backup_dir.join(format!("libepaper.{}.orig", sha));
    if dst.exists() {
        return Ok(());
    }
    fs::copy(src, &dst).with_context(|| format!("backup to {}", dst.display()))?;
    Ok(())
}

fn first_char(v: &Value) -> Option<char> {
    let v = match v {
        Value::Array(a) => a.get(0)?,
        other => other,
    };
    let s = v.as_str()?;
    let mut it = s.chars();
    let c = it.next()?;
    if it.next().is_none() { Some(c) } else { None }
}

fn entry_to_pair(v: &Value) -> Option<(u32, u32)> {
    let obj = v.as_object()?;
    if obj.contains_key("special") {
        return None;
    }
    let d0 = obj.get("default").and_then(first_char);
    let s0 = obj.get("shifted").and_then(first_char);

    if d0.is_none() && s0.is_none() {
        return None;
    }
    let d = d0.or(s0).unwrap();
    let s = s0.unwrap_or(d);
    Some((d as u32, s as u32))
}

pub fn build_keycode_map_from_matrix(over: &Value) -> Result<HashMap<u16, (u32, u32)>> {
    let alpha = over
        .get("alphabetic")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("keyboard_layout.json must contain an 'alphabetic' array"))?;

    if alpha.len() < 2 {
        bail!("'alphabetic' must have at least 2 rows");
    }

    let mut kc_map: HashMap<u16, (u32, u32)> = HashMap::new();

    // Row 0 (Q..[)
    let row0 = alpha[0].as_array().ok_or_else(|| anyhow!("alphabetic[0] must be array"))?;
    for (i, kc) in ROW0.iter().enumerate() {
        if i >= row0.len() { break; }
        if let Some(pair) = entry_to_pair(&row0[i]) {
            kc_map.insert(*kc, pair);
        }
    }

    // Row 1 (A..')
    let row1 = alpha[1].as_array().ok_or_else(|| anyhow!("alphabetic[1] must be array"))?;
    for (i, kc) in ROW1.iter().enumerate() {
        if i >= row1.len() { break; }
        if let Some(pair) = entry_to_pair(&row1[i]) {
            kc_map.insert(*kc, pair);
        }
    }

    // Row 2 (Z..M) â€” skip specials by filtering first
    if alpha.len() >= 3 {
        let row2 = alpha[2].as_array().ok_or_else(|| anyhow!("alphabetic[2] must be array"))?;
        let pairs: Vec<(u32, u32)> = row2.iter().filter_map(entry_to_pair).collect();
        for (i, kc) in ROW2.iter().enumerate() {
            if i >= pairs.len() { break; }
            kc_map.insert(*kc, pairs[i]);
        }
    }

    if kc_map.is_empty() {
        bail!("No patchable entries found in alphabetic matrix");
    }
    Ok(kc_map)
}

fn contains_all(name: &str, parts: &[&str]) -> bool {
    parts.iter().all(|p| name.contains(p))
}

fn find_symbol(elf: &Elf<'_>) -> Result<SymPick> {
    let want1 = ["EpaperEvdevKeyboardMap", "Locale", "Germany", "keymap"];
    let want2 = ["Germany", "keymap"];

    let mut cands: Vec<SymPick> = Vec::new();

    for sym in elf.syms.iter() {
        if sym.st_size == 0 { continue; }
        let name = elf.strtab.get_at(sym.st_name).unwrap_or("");
        if name.is_empty() { continue; }
        if contains_all(name, &want1) || contains_all(name, &want2) {
            cands.push(SymPick {
                name: name.to_string(),
                shndx: sym.st_shndx as usize,
                value: sym.st_value,
                size: sym.st_size,
            });
        }
    }

    for sym in elf.dynsyms.iter() {
        if sym.st_size == 0 { continue; }
        let name = elf.dynstrtab.get_at(sym.st_name).unwrap_or("");
        if name.is_empty() { continue; }
        if contains_all(name, &want1) || contains_all(name, &want2) {
            cands.push(SymPick {
                name: name.to_string(),
                shndx: sym.st_shndx as usize,
                value: sym.st_value,
                size: sym.st_size,
            });
        }
    }

    if cands.is_empty() {
        bail!("Couldn't find Germany keymap symbol in libepaper.so (symbols may be stripped).");
    }

    cands.sort_by_key(|c| std::cmp::Reverse(c.size));
    Ok(cands[0].clone())
}

fn sym_file_range(elf: &Elf<'_>, sym: &SymPick) -> Result<(u64, usize)> {
    let shndx = sym.shndx;
    if shndx == 0 || shndx >= elf.section_headers.len() {
        bail!("Symbol section not found (st_shndx={})", shndx);
    }
    let sh = &elf.section_headers[shndx];
    let base_addr = sh.sh_addr;
    let base_off  = sh.sh_offset;
    if sym.value < base_addr {
        bail!("Symbol address < section base");
    }
    let off = base_off + (sym.value - base_addr);
    Ok((off, sym.size as usize))
}

fn read_u16_le(buf: &[u8], off: usize) -> u16 {
    u16::from_le_bytes([buf[off], buf[off + 1]])
}

fn read_u32_le(buf: &[u8], off: usize) -> u32 {
    u32::from_le_bytes([buf[off], buf[off + 1], buf[off + 2], buf[off + 3]])
}

fn read_uni(buf: &[u8], off: usize, fmt: UniFmt) -> u32 {
    match fmt {
        UniFmt::U16 => read_u16_le(buf, off) as u32,
        UniFmt::U32 => read_u32_le(buf, off),
    }
}

fn write_uni(buf: &mut [u8], off: usize, fmt: UniFmt, val: u32) -> Result<()> {
    match fmt {
        UniFmt::U16 => {
            if val > 0xFFFF {
                bail!("codepoint 0x{:x} too large for u16 layout", val);
            }
            let b = (val as u16).to_le_bytes();
            buf[off..off + 2].copy_from_slice(&b);
        }
        UniFmt::U32 => {
            let b = val.to_le_bytes();
            buf[off..off + 4].copy_from_slice(&b);
        }
    }
    Ok(())
}

fn pick_layout(data: &[u8]) -> Result<Layout> {
    let mut best: Option<(i64, Layout)> = None;

    for lay in LAYOUTS {
        if data.len() % lay.entry_size != 0 {
            continue;
        }
        let n = data.len() / lay.entry_size;

        let mut good = 0i64;
        let mut saw_a = false;
        let mut saw_A = false;

        for i in 0..n {
            let base = i * lay.entry_size;
            let keycode = read_u16_le(data, base + lay.key_off);
            if keycode > 2048 {
                continue;
            }
            let uni = read_uni(data, base + lay.uni_off, lay.uni_fmt);
            if (0x20..=0x7E).contains(&uni) {
                good += 1;
            }
            if keycode == 30 && uni == 0x61 { saw_a = true; }
            if keycode == 30 && uni == 0x41 { saw_A = true; }
        }

        let score = good + if saw_a && saw_A { 2000 } else { 0 };
        if best.as_ref().map(|(s, _)| score > *s).unwrap_or(true) {
            best = Some((score, lay));
        }
    }

    best.map(|(_, l)| l).ok_or_else(|| anyhow!("Could not infer keymap entry layout."))
}

fn detect_mods(data: &[u8], lay: Layout) -> (u8, u8) {
    let n = data.len() / lay.entry_size;

    // Method 1: KEY_A as 'a' and 'A' (pristine table)
    let mut mods_plain: Option<u8> = None;
    let mut mods_shift: Option<u8> = None;

    for i in 0..n {
        let base = i * lay.entry_size;
        let keycode = read_u16_le(data, base + lay.key_off);
        if keycode != 30 { continue; }

        let uni = read_uni(data, base + lay.uni_off, lay.uni_fmt);
        let mods = data[base + lay.mods_off];

        if uni == 0x61 && mods_plain.is_none() { mods_plain = Some(mods); }
        if uni == 0x41 && mods_shift.is_none() { mods_shift = Some(mods); }

        if mods_plain.is_some() && mods_shift.is_some() {
            return (mods_plain.unwrap(), mods_shift.unwrap());
        }
    }

    // Method 2: scan KEY_A entries for distinct mods (patched table fallback)
    let mut set: Vec<u8> = Vec::new();
    for i in 0..n {
        let base = i * lay.entry_size;
        let keycode = read_u16_le(data, base + lay.key_off);
        if keycode != 30 { continue; }
        let mods = data[base + lay.mods_off];
        if !set.contains(&mods) { set.push(mods); }
    }
    set.sort_unstable();

    if set.len() >= 2 {
        return (set[0], set[1]);
    }
    if set.len() == 1 {
        if set[0] == 0 { return (0, 1); }
    }

    (0, 1)
}

pub fn needs_patch(lib_path: &Path, locale: &str, state_path: &Path, over_sha: &str) -> Result<bool> {
    if locale != "de_DE" {
        bail!("Type Folio patch assumes you're repurposing de_DE (Germany keymap table).");
    }
    if !lib_path.exists() {
        bail!("libepaper.so not found: {}", lib_path.display());
    }

    let sha_cur = super::sha256_file(lib_path)?;
    if let Some(st) = read_state(state_path) {
        if st.schema == EPAPER_STATE_SCHEMA
            && st.locale == locale
            && st.patched_sha == sha_cur
            && st.override_sha == over_sha
        {
            return Ok(false);
        }
    }
    Ok(true)
}

pub fn apply_patch(
    lib_path: &Path,
    locale: &str,
    kc_map: &HashMap<u16, (u32, u32)>,
    backup_dir: &Path,
    state_path: &Path,
    over_sha: &str,
    verbose: bool,
    force: bool,
) -> Result<bool> {
    if locale != "de_DE" {
        bail!("Type Folio patch assumes you're repurposing de_DE (Germany keymap table).");
    }
    if !lib_path.exists() {
        bail!("libepaper.so not found: {}", lib_path.display());
    }
    if kc_map.is_empty() {
        bail!("No matrix-derived mappings; refusing to patch libepaper");
    }

    let sha_before = super::sha256_file(lib_path)?;

    if !force {
        if let Some(st) = read_state(state_path) {
            if st.schema == EPAPER_STATE_SCHEMA
                && st.locale == locale
                && st.patched_sha == sha_before
                && st.override_sha == over_sha
            {
                if verbose {
                    println!("[epaper] UNCHANGED (state matches)");
                }
                return Ok(false);
            }
        }
    }

    ensure_backup_named(lib_path, backup_dir, &sha_before)?;

    let bytes = fs::read(lib_path).with_context(|| format!("read {}", lib_path.display()))?;
    let elf = Elf::parse(&bytes).context("parse ELF libepaper")?;

    let sym = find_symbol(&elf)?;
    let (file_off, size) = sym_file_range(&elf, &sym)?;

    let end = (file_off as usize)
        .checked_add(size)
        .ok_or_else(|| anyhow!("overflow computing symbol end"))?;

    if end > bytes.len() {
        bail!("symbol range out of bounds (off=0x{:x} size=0x{:x})", file_off, size);
    }

    let mut data = bytes[file_off as usize..end].to_vec();
    let lay = pick_layout(&data)?;
    let (mods_plain, mods_shift) = detect_mods(&data, lay);

    if verbose {
        println!(
            "[epaper] symbol={} size={} off=0x{:x} layout={} mods_plain=0x{:02x} mods_shift=0x{:02x} mappings={}",
            sym.name, sym.size, file_off, lay.name, mods_plain, mods_shift, kc_map.len()
        );
    }

    let n = data.len() / lay.entry_size;
    let mut patched_plain = 0u32;
    let mut patched_shift = 0u32;

    for i in 0..n {
        let base = i * lay.entry_size;
        let keycode = read_u16_le(&data, base + lay.key_off);
        let mods = data[base + lay.mods_off];

        if mods != mods_plain && mods != mods_shift {
            continue;
        }

        let pair = match kc_map.get(&keycode) {
            Some(p) => *p,
            None => continue,
        };

        let want = if mods == mods_plain { pair.0 } else { pair.1 };
        write_uni(&mut data, base + lay.uni_off, lay.uni_fmt, want)?;

        if mods == mods_plain { patched_plain += 1; } else { patched_shift += 1; }
    }

    let total = patched_plain + patched_shift;
    if total == 0 {
        bail!("Patched 0 entries (unexpected).");
    }

    // Write back just the symbol range
    let mut f = OpenOptions::new()
        .read(true)
        .write(true)
        .open(lib_path)
        .with_context(|| format!("open {}", lib_path.display()))?;
    f.seek(SeekFrom::Start(file_off))?;
    f.write_all(&data)?;
    f.sync_all().ok();

    let sha_after = super::sha256_file(lib_path)?;
    let changed = sha_after != sha_before;

    let st = EpaperState {
        schema: EPAPER_STATE_SCHEMA.to_string(),
        orig_sha: sha_before,
        patched_sha: sha_after,
        override_sha: over_sha.to_string(),
        locale: locale.to_string(),
    };
    write_state(state_path, &st)?;

    if verbose {
        println!(
            "[epaper] patched entries: plain={} shift={} total={} changed={}",
            patched_plain, patched_shift, total, changed
        );
        println!("[epaper] NOTE: Type Folio must be set to German (de_DE) for the repurposed table to be used.");
    }

    Ok(changed)
}