use anyhow::{anyhow, bail, Context, Result};
use clap::Parser;
use memchr::memmem;
use memmap2::Mmap;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

const MAGIC_ZSTD: &[u8; 4] = b"\x28\xb5\x2f\xfd";
const STATE_SCHEMA: &str = "kbdpatch-state-v2";

#[derive(Parser, Debug)]
#[command(name = "rm-xochitl-kbdpatch", version)]
struct Args {
    #[arg(long, default_value = "de_DE")]
    locale: String,

    /// Mapping-grid JSON (UTF-8/UTF-16; BOM tolerated)
    #[arg(long)]
    json: PathBuf,

    /// Target file (default /usr/bin/xochitl)
    #[arg(long, default_value = "/usr/bin/xochitl")]
    xochitl: PathBuf,

    /// Backup dir (persistent)
    #[arg(long, default_value = "/home/root/.cache/rm-custom")]
    backup_dir: PathBuf,

    /// State file (idempotence)
    #[arg(long, default_value = "/home/root/.cache/rm-custom/state.json")]
    state: PathBuf,

    /// Dump before/after JSON here for debugging
    #[arg(long, default_value = "/home/root/.cache/rm-custom")]
    dump_dir: PathBuf,

    /// Verbose output
    #[arg(long)]
    verbose: bool,

    /// Check-only mode: exit 0 if already patched as desired, exit 2 if patch is needed.
    /// Does NOT modify xochitl and does NOT scan the binary.
    #[arg(long)]
    check: bool,

    /// Force: ignore state.json match and proceed (useful for debugging).
    #[arg(long)]
    force: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
struct PatchHit {
    hdr_off: u64,
    cap: u32,
    sig: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
struct StateFile {
    #[serde(default)]
    schema: String,
    orig_sha: String,
    patched_sha: String,
    override_sha: String,
    locale: String,
    hits: Vec<PatchHit>,
}

enum Outcome {
    Unchanged,
    Patched,
}

#[derive(Debug, Clone)]
struct Plan {
    hdr_off: usize,
    cap: u32,
    old_payload: Vec<u8>,
    new_payload: Vec<u8>,
    after: Value,
    sig: String,
}

#[derive(Debug)]
struct Cand {
    hdr_off: usize,
    cap: u32,
    sig0: String,
    sig1: String,
    sig2: String,
    score: i32,
    exact: bool,
    v: Value,
}

fn main() {
    let args = Args::parse();
    let rc = match run(&args) {
        Ok(Outcome::Unchanged) => 0,
        Ok(Outcome::Patched) => 2,
        Err(e) => {
            eprintln!("[kbdpatch] ERROR: {:#}", e);
            1
        }
    };
    std::process::exit(rc);
}

fn run(args: &Args) -> Result<Outcome> {
    fs::create_dir_all(&args.backup_dir).ok();
    if let Some(p) = args.state.parent() {
        fs::create_dir_all(p).ok();
    }
    fs::create_dir_all(&args.dump_dir).ok();

    if !args.json.exists() {
        bail!("override JSON not found: {}", args.json.display());
    }
    if !args.xochitl.exists() {
        bail!("target not found: {}", args.xochitl.display());
    }

    let over_txt = read_text_allow_bom(&args.json)?;
    let over_v: Value = serde_json::from_str(&over_txt).context("parse override JSON")?;
    validate_override(&over_v)?;

    let mapping =
        build_letter_mapping(&args.locale, &over_v).context("build mapping from override JSON")?;

    // Schema-bumped hash so new binaries can intentionally invalidate prior state.
    let over_min = serde_json::to_vec(&over_v)?;
    let over_sha = sha256_with_schema(&over_min);

    let sha_cur = sha256_file(&args.xochitl)?;
    if args.verbose {
        println!(
            "[kbdpatch] target={} sha={}",
            args.xochitl.display(),
            sha_cur
        );
    }

    let st_opt = read_state(&args.state);

    // CHECK MODE: do not scan or modify; only answer "needs patch?"
    if args.check {
        if let Some(st) = &st_opt {
            if st.schema == STATE_SCHEMA
                && st.patched_sha == sha_cur
                && st.override_sha == over_sha
                && st.locale == args.locale
            {
                if args.verbose {
                    println!("[kbdpatch] CHECK: no patch needed (state matches)");
                }
                return Ok(Outcome::Unchanged);
            }
        }
        if args.verbose {
            println!("[kbdpatch] CHECK: patch needed");
        }
        return Ok(Outcome::Patched);
    }

    // Normal early-exit (unless forced)
    if !args.force {
        if let Some(st) = &st_opt {
            if st.schema == STATE_SCHEMA
                && st.patched_sha == sha_cur
                && st.override_sha == over_sha
                && st.locale == args.locale
            {
                if args.verbose {
                    println!("[kbdpatch] UNCHANGED (state matches)");
                }
                return Ok(Outcome::Unchanged);
            }
        }
    }

    ensure_backup(&args.xochitl, &args.backup_dir, &sha_cur)?;

    let f = File::open(&args.xochitl)?;
    let mm = unsafe { Mmap::map(&f)? };
    let bytes: &[u8] = &mm[..];

    // If we are already on a previously patched binary (state.patched_sha == current),
    // prefer re-patching the SAME blob offset/cap stored in state.hits.
    // This is what makes "edit JSON and re-run" work reliably.
    if let Some(st) = &st_opt {
        if st.schema == STATE_SCHEMA
            && st.locale == args.locale
            && st.patched_sha == sha_cur
            && !st.hits.is_empty()
        {
            if args.verbose {
                println!(
                    "[kbdpatch] attempting repatch via state hit(s): {} hit(s)",
                    st.hits.len()
                );
            }

            for (i, h) in st.hits.iter().take(4).enumerate() {
                let hdr_off = h.hdr_off as usize;
                let cap = h.cap;

                if args.verbose {
                    println!(
                        "[kbdpatch] state-hit #{}: hdr_off=0x{:x} cap={} sig={}",
                        i,
                        hdr_off,
                        cap,
                        h.sig
                    );
                }

                if let Ok(before) = load_candidate_at(bytes, hdr_off, cap) {
                    let sig = signature_string(&before);
                    let (after, touched, changed) =
                        compute_after(&before, &mapping, &args.locale, true)
                            .context("apply mapping (state-hit)")?;

                    if args.verbose {
                        println!(
                            "[kbdpatch] state-hit apply: touched={} changed={}",
                            touched, changed
                        );
                    }

                    // Even if changed==0, write updated state so we don't keep "wanting" to patch
                    // due to override hash differences.
                    if changed == 0 {
                        dump_json(&args.dump_dir, &args.locale, "before", hdr_off, &before).ok();
                        dump_json(&args.dump_dir, &args.locale, "after", hdr_off, &after).ok();

                        let orig_sha = st.orig_sha.clone();
                        let st2 = StateFile {
                            schema: STATE_SCHEMA.to_string(),
                            orig_sha,
                            patched_sha: sha_cur.clone(),
                            override_sha: over_sha.clone(),
                            locale: args.locale.clone(),
                            hits: vec![PatchHit {
                                hdr_off: hdr_off as u64,
                                cap,
                                sig,
                            }],
                        };
                        write_state(&args.state, &st2)?;
                        if args.verbose {
                            println!("[kbdpatch] UNCHANGED (already matches desired mapping)");
                        }
                        return Ok(Outcome::Unchanged);
                    }

                    validate_layout(&after)?;
                    dump_json(&args.dump_dir, &args.locale, "before", hdr_off, &before).ok();
                    dump_json(&args.dump_dir, &args.locale, "after", hdr_off, &after).ok();

                    let after_min = serde_json::to_vec(&after)?;
                    let (new_payload, lvl, pad) = compress_to_exact_cap(&after_min, cap as usize)?;
                    if args.verbose {
                        println!(
                            "[kbdpatch] plan @0x{:x}: cap={} zstd_level={} padded={}",
                            hdr_off, cap, lvl, pad
                        );
                    }

                    let p0 = hdr_off + 4;
                    let p1 = p0 + cap as usize;
                    if p1 > bytes.len() {
                        bail!("state-hit range out of file bounds");
                    }
                    let old_payload = bytes[p0..p1].to_vec();

                    drop(mm);

                    let plan = Plan {
                        hdr_off,
                        cap,
                        old_payload,
                        new_payload,
                        after,
                        sig: signature_string(&before),
                    };

                    apply_in_place(&args.xochitl, &plan)?;
                    verify_one(&args.xochitl, &plan).or_else(|e| {
                        rollback_in_place(&args.xochitl, &plan).ok();
                        Err(e).context("verification failed; rolled back")
                    })?;

                    let sha_post = sha256_file(&args.xochitl)?;
                    let orig_sha = st.orig_sha.clone();

                    let st2 = StateFile {
                        schema: STATE_SCHEMA.to_string(),
                        orig_sha,
                        patched_sha: sha_post.clone(),
                        override_sha: over_sha.clone(),
                        locale: args.locale.clone(),
                        hits: vec![PatchHit {
                            hdr_off: plan.hdr_off as u64,
                            cap: plan.cap,
                            sig: plan.sig.clone(),
                        }],
                    };
                    write_state(&args.state, &st2)?;

                    println!("[kbdpatch] PATCHED OK new_sha={}", sha_post);
                    return Ok(Outcome::Patched);
                }
            }

            if args.verbose {
                println!("[kbdpatch] state-hit repatch failed; falling back to scan");
            }
        }
    }

    // Fallback: scan and choose best match by locale signature (initial patch, or after OS update)
    let expected_full = locale_full_sig(&args.locale)?;

    let raw_candidates = scan_keyboard_json(bytes)?;
    if raw_candidates.is_empty() {
        bail!("no keyboard JSON candidates found (zstd blobs). xochitl format may have changed.");
    }

    let mut cands: Vec<Cand> = Vec::new();
    for (hdr_off, cap, v) in raw_candidates {
        let (s0, s1, s2) = match full_signature_rows(&v) {
            Some(x) => x,
            None => continue,
        };

        let exact = s0 == expected_full.0 && s1 == expected_full.1 && s2 == expected_full.2;
        let score = score_candidate(&args.locale, &s0, &s1, &s2, exact);

        cands.push(Cand {
            hdr_off,
            cap,
            sig0: s0,
            sig1: s1,
            sig2: s2,
            score,
            exact,
            v,
        });
    }

    if cands.is_empty() {
        bail!("found zstd JSON blobs, but none looked like keyboard layouts");
    }

    cands.sort_by(|a, b| b.score.cmp(&a.score));

    if args.verbose {
        println!("[kbdpatch] Candidates (top 12):");
        for (i, c) in cands.iter().take(12).enumerate() {
            println!(
                "  #{}: hdr_off=0x{:x} cap={} score={} exact={} rows=[\"{}\",\"{}\",\"{}\"]",
                i, c.hdr_off, c.cap, c.score, c.exact, c.sig0, c.sig1, c.sig2
            );
        }
    }

    let chosen = &cands[0];
    if args.verbose {
        println!(
            "[kbdpatch] chosen: hdr_off=0x{:x} cap={} rows=[\"{}\",\"{}\",\"{}\"]",
            chosen.hdr_off, chosen.cap, chosen.sig0, chosen.sig1, chosen.sig2
        );
    }

    let before = chosen.v.clone();
    let (after, touched, changed) =
        compute_after(&before, &mapping, &args.locale, false).context("apply mapping")?;

    if touched == 0 {
        bail!("mapping touched 0 keys (base layout unexpected?)");
    }

    // If nothing changes, still write state (so future runs don't keep trying)
    if changed == 0 {
        dump_json(&args.dump_dir, &args.locale, "before", chosen.hdr_off, &before).ok();
        dump_json(&args.dump_dir, &args.locale, "after", chosen.hdr_off, &after).ok();

        let sig = format!("{}|{}|{}", chosen.sig0, chosen.sig1, chosen.sig2);
        let orig_sha = sha_cur.clone();
        let st2 = StateFile {
            schema: STATE_SCHEMA.to_string(),
            orig_sha,
            patched_sha: sha_cur.clone(),
            override_sha: over_sha.clone(),
            locale: args.locale.clone(),
            hits: vec![PatchHit {
                hdr_off: chosen.hdr_off as u64,
                cap: chosen.cap,
                sig,
            }],
        };
        write_state(&args.state, &st2)?;

        if args.verbose {
            println!("[kbdpatch] UNCHANGED (already matches desired mapping)");
        }
        return Ok(Outcome::Unchanged);
    }

    validate_layout(&after)?;
    dump_json(&args.dump_dir, &args.locale, "before", chosen.hdr_off, &before).ok();
    dump_json(&args.dump_dir, &args.locale, "after", chosen.hdr_off, &after).ok();

    let after_min = serde_json::to_vec(&after)?;
    let (new_payload, lvl, pad) = compress_to_exact_cap(&after_min, chosen.cap as usize)?;
    if args.verbose {
        println!(
            "[kbdpatch] plan @0x{:x}: cap={} zstd_level={} padded={}",
            chosen.hdr_off, chosen.cap, lvl, pad
        );
    }

    let p0 = chosen.hdr_off + 4;
    let p1 = p0 + chosen.cap as usize;
    if p1 > bytes.len() {
        bail!("candidate range out of file bounds");
    }
    let old_payload = bytes[p0..p1].to_vec();

    drop(mm);

    let sig = format!("{}|{}|{}", chosen.sig0, chosen.sig1, chosen.sig2);
    let plan = Plan {
        hdr_off: chosen.hdr_off,
        cap: chosen.cap,
        old_payload,
        new_payload,
        after,
        sig: sig.clone(),
    };

    apply_in_place(&args.xochitl, &plan)?;
    verify_one(&args.xochitl, &plan).or_else(|e| {
        rollback_in_place(&args.xochitl, &plan).ok();
        Err(e).context("verification failed; rolled back")
    })?;

    let sha_post = sha256_file(&args.xochitl)?;

    let st2 = StateFile {
        schema: STATE_SCHEMA.to_string(),
        orig_sha: sha_cur,
        patched_sha: sha_post.clone(),
        override_sha: over_sha,
        locale: args.locale.clone(),
        hits: vec![PatchHit {
            hdr_off: plan.hdr_off as u64,
            cap: plan.cap,
            sig,
        }],
    };
    write_state(&args.state, &st2)?;

    println!("[kbdpatch] PATCHED OK new_sha={}", sha_post);
    Ok(Outcome::Patched)
}

fn compute_after(
    before: &Value,
    mapping: &HashMap<char, (String, String)>,
    locale: &str,
    allow_position_fallback: bool,
) -> Result<(Value, usize, usize)> {
    let mut after = before.clone();
    let (touched, changed) = apply_mapping_by_base_letter(&mut after, mapping)
        .context("apply by base-letter")?;

    if touched == 0 && allow_position_fallback {
        let (t2, c2) =
            apply_mapping_by_position(locale, &mut after, mapping).context("apply by position")?;
        return Ok((after, t2, c2));
    }

    Ok((after, touched, changed))
}

fn apply_mapping_by_position(
    locale: &str,
    base: &mut Value,
    mapping: &HashMap<char, (String, String)>,
) -> Result<(usize, usize)> {
    match locale {
        "de_DE" => apply_mapping_by_position_de_de(base, mapping),
        _ => bail!("unsupported locale {}", locale),
    }
}

fn apply_mapping_by_position_de_de(
    base: &mut Value,
    mapping: &HashMap<char, (String, String)>,
) -> Result<(usize, usize)> {
    let bobj = base.as_object_mut().ok_or_else(|| anyhow!("base not object"))?;
    let balpha = bobj
        .get_mut("alphabetic")
        .ok_or_else(|| anyhow!("base missing alphabetic"))?
        .as_array_mut()
        .ok_or_else(|| anyhow!("base alphabetic not array"))?;

    if balpha.len() < 3 {
        bail!("base alphabetic < 3 rows");
    }

    // --- E0499 fix: take non-overlapping mutable borrows of rows ---
    let (r0_slice, rest) = balpha.split_at_mut(1);
    let (r1_slice, r2_slice) = rest.split_at_mut(1);

    let row0 = r0_slice[0]
        .as_array_mut()
        .ok_or_else(|| anyhow!("row0 not array"))?;
    let row1 = r1_slice[0]
        .as_array_mut()
        .ok_or_else(|| anyhow!("row1 not array"))?;
    let row2 = r2_slice[0]
        .as_array_mut()
        .ok_or_else(|| anyhow!("row2 not array"))?;
    // -------------------------------------------------------------

    // These are the same "logical positions" we already assume in build_letter_mapping_de_de
    if row0.len() < 10 {
        bail!("row0 too short (need >= 10)");
    }
    if row1.len() < 9 {
        bail!("row1 too short (need >= 9)");
    }
    if row2.len() < 8 {
        bail!("row2 too short (need >= 8)");
    }

    let mut touched = 0usize;
    let mut changed = 0usize;

    let row0_letters = ['q', 'w', 'e', 'r', 't', 'z', 'u', 'i', 'o', 'p'];
    for (i, ch) in row0_letters.iter().enumerate() {
        let (nd, ns) = mapping
            .get(ch)
            .ok_or_else(|| anyhow!("mapping missing {}", ch))?;
        let did = set_key_pair(&mut row0[i], nd, ns)
            .with_context(|| format!("row0 idx {} letter {}", i, ch))?;
        touched += 1;
        if did {
            changed += 1;
        }
    }
	// Extra German key at row0[10] (ü)
	if row0.len() >= 11 {
		let (nd, ns) = mapping.get(&'ü').ok_or_else(|| anyhow!("mapping missing ü"))?;
		let did = set_key_pair(&mut row0[10], nd, ns).context("row0 idx 10 (ü)")?;
		touched += 1;
		if did { changed += 1; }
	}


    let row1_letters = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
    for (i, ch) in row1_letters.iter().enumerate() {
        let (nd, ns) = mapping
            .get(ch)
            .ok_or_else(|| anyhow!("mapping missing {}", ch))?;
        let did = set_key_pair(&mut row1[i], nd, ns)
            .with_context(|| format!("row1 idx {} letter {}", i, ch))?;
        touched += 1;
        if did {
            changed += 1;
        }
    }
	// Extra German keys at row1[9], row1[10] (ö, ä)
	if row1.len() >= 11 {
		let (nd, ns) = mapping.get(&'ö').ok_or_else(|| anyhow!("mapping missing ö"))?;
		let did = set_key_pair(&mut row1[9], nd, ns).context("row1 idx 9 (ö)")?;
		touched += 1;
		if did { changed += 1; }

		let (nd, ns) = mapping.get(&'ä').ok_or_else(|| anyhow!("mapping missing ä"))?;
		let did = set_key_pair(&mut row1[10], nd, ns).context("row1 idx 10 (ä)")?;
		touched += 1;
		if did { changed += 1; }
	}


    // row2 has shift at idx0, then y..m at idx1..7
    let row2_letters = ['y', 'x', 'c', 'v', 'b', 'n', 'm'];
    for (i, ch) in row2_letters.iter().enumerate() {
        let idx = i + 1;
        let (nd, ns) = mapping
            .get(ch)
            .ok_or_else(|| anyhow!("mapping missing {}", ch))?;
        let did = set_key_pair(&mut row2[idx], nd, ns)
            .with_context(|| format!("row2 idx {} letter {}", idx, ch))?;
        touched += 1;
        if did {
            changed += 1;
        }
    }

    Ok((touched, changed))
}

fn set_key_pair(key: &mut Value, nd: &str, ns: &str) -> Result<bool> {
    let ko = key
        .as_object_mut()
        .ok_or_else(|| anyhow!("key not object"))?;

    if ko.get("special").is_some() {
        bail!("expected normal key, got special");
    }

    // Current values
    let cur_def0 = ko
        .get("default")
        .and_then(|v| v.as_array())
        .and_then(|a| a.get(0))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let cur_sh0 = ko
        .get("shifted")
        .and_then(|v| v.as_array())
        .and_then(|a| a.get(0))
        .and_then(|v| v.as_str())
        .unwrap_or(cur_def0);

    let cur_def_len = ko
        .get("default")
        .and_then(|v| v.as_array())
        .map(|a| a.len())
        .unwrap_or(0);

    let cur_sh_len = ko
        .get("shifted")
        .and_then(|v| v.as_array())
        .map(|a| a.len())
        .unwrap_or(0);

    let needs = cur_def_len != 1 || cur_sh_len != 1 || cur_def0 != nd || cur_sh0 != ns;
    if needs {
        ko.insert(
            "default".to_string(),
            Value::Array(vec![Value::String(nd.to_string())]),
        );
        ko.insert(
            "shifted".to_string(),
            Value::Array(vec![Value::String(ns.to_string())]),
        );
        return Ok(true);
    }

    Ok(false)
}

fn signature_string(v: &Value) -> String {
    if let Some((a, b, c)) = full_signature_rows(v) {
        format!("{}|{}|{}", a, b, c)
    } else {
        "unknown".to_string()
    }
}

fn load_candidate_at(bytes: &[u8], hdr_off: usize, cap: u32) -> Result<Value> {
    if hdr_off + 8 > bytes.len() {
        bail!("hdr_off out of range");
    }

    // Validate cap matches header (BE or LE)
    let cap_be = read_u32_be(bytes, hdr_off).unwrap_or(0);
    let cap_le = read_u32_le(bytes, hdr_off).unwrap_or(0);
    if cap != cap_be && cap != cap_le {
        bail!(
            "cap mismatch at 0x{:x}: state cap={} file cap_be={} cap_le={}",
            hdr_off,
            cap,
            cap_be,
            cap_le
        );
    }

    let p0 = hdr_off + 4;
    let p1 = p0 + cap as usize;
    if p1 > bytes.len() {
        bail!("payload out of range");
    }

    let payload = &bytes[p0..p1];
    if !payload.starts_with(MAGIC_ZSTD) {
        bail!("payload at 0x{:x} missing zstd magic", hdr_off);
    }

    let decoded =
        zstd::stream::decode_all(std::io::Cursor::new(payload)).context("zstd decode")?;
    let v: Value = serde_json::from_slice(&decoded).context("json parse")?;

    if v.get("alphabetic").and_then(|x| x.as_array()).is_none() {
        bail!("json at hit does not look like keyboard layout (missing alphabetic)");
    }

    Ok(v)
}

fn locale_full_sig(locale: &str) -> Result<(String, String, String)> {
    match locale {
        "de_DE" => Ok((
            format!("qwertzuiop{}", '\u{00FC}'),
            format!("asdfghjkl{}{}", '\u{00F6}', '\u{00E4}'),
            "yxcvbnm".to_string(),
        )),
        _ => bail!("unsupported locale {}", locale),
    }
}

fn score_candidate(locale: &str, r0: &str, r1: &str, r2: &str, exact: bool) -> i32 {
    match locale {
        "de_DE" => {
            let mut s = 0i32;
            if contains_ordered(r0, "qwertzuiop") {
                s += 1200;
            }
            if contains_ordered(r1, "asdfghjkl") {
                s += 1200;
            }
            if contains_ordered(r2, "yxcvbnm") {
                s += 900;
            }

            if r0.contains('\u{00FC}') {
                s += 8000;
            }
            if r1.contains('\u{00F6}') && r1.contains('\u{00E4}') {
                s += 8000;
            }
            if exact {
                s += 20000;
            }
            s
        }
        _ => 0,
    }
}

fn contains_ordered(hay: &str, needle: &str) -> bool {
    let mut it = hay.chars();
    for c in needle.chars() {
        if it.find(|h| *h == c).is_none() {
            return false;
        }
    }
    true
}

fn validate_override(over: &Value) -> Result<()> {
    let o = over
        .as_object()
        .ok_or_else(|| anyhow!("override not object"))?;
    let a = o
        .get("alphabetic")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("override missing alphabetic[]"))?;
    if a.len() != 3 {
        bail!("override alphabetic must have 3 rows");
    }
    Ok(())
}

fn validate_layout(v: &Value) -> Result<()> {
    let o = v.as_object().ok_or_else(|| anyhow!("layout not object"))?;
    let alpha = o
        .get("alphabetic")
        .and_then(|x| x.as_array())
        .ok_or_else(|| anyhow!("missing alphabetic"))?;
    if alpha.len() < 3 {
        bail!("alphabetic must have >= 3 rows");
    }
    Ok(())
}

fn full_signature_rows(v: &Value) -> Option<(String, String, String)> {
    let alpha = v.get("alphabetic")?.as_array()?;
    if alpha.len() < 3 {
        return None;
    }
    let r0 = full_sig_row(alpha[0].as_array()?);
    let r1 = full_sig_row(alpha[1].as_array()?);
    let r2 = full_sig_row(alpha[2].as_array()?);
    Some((r0, r1, r2))
}

fn full_sig_row(arr: &[Value]) -> String {
    let mut s = String::new();
    for key in arr {
        let o = match key.as_object() {
            Some(o) => o,
            None => continue,
        };
        if o.get("special").is_some() {
            continue;
        }
        let def0 = match o
            .get("default")
            .and_then(|v| v.as_array())
            .and_then(|a| a.get(0))
            .and_then(|v| v.as_str())
        {
            Some(v) => v,
            None => continue,
        };
        if def0.chars().count() != 1 {
            continue;
        }
        s.push_str(def0);
    }
    s
}

fn build_letter_mapping(locale: &str, over: &Value) -> Result<HashMap<char, (String, String)>> {
    match locale {
        "de_DE" => build_letter_mapping_de_de(over),
        _ => bail!("unsupported locale {}", locale),
    }
}

fn build_letter_mapping_de_de(over: &Value) -> Result<HashMap<char, (String, String)>> {
    let alpha = over
        .get("alphabetic")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("override missing alphabetic"))?;
    if alpha.len() != 3 {
        bail!("override alphabetic must have 3 rows");
    }

    let r0 = alpha[0]
        .as_array()
        .ok_or_else(|| anyhow!("override row0 not array"))?;
    let r1 = alpha[1]
        .as_array()
        .ok_or_else(|| anyhow!("override row1 not array"))?;
    let r2 = alpha[2]
        .as_array()
        .ok_or_else(|| anyhow!("override row2 not array"))?;

	if r0.len() < 11 { bail!("override row0 too short (need >= 11 incl ü-key)"); }
	if r1.len() < 11 { bail!("override row1 too short (need >= 11 incl ö/ä-keys)"); }
	if r2.len() < 8  { bail!("override row2 too short (need >= 8)"); }

    let mut m: HashMap<char, (String, String)> = HashMap::new();

    let row0_letters = ['q', 'w', 'e', 'r', 't', 'z', 'u', 'i', 'o', 'p'];
    for (i, ch) in row0_letters.iter().enumerate() {
        let (d, s) =
            key_pair_from_val(&r0[i]).with_context(|| format!("override row0 idx {}", i))?;
        m.insert(*ch, (d, s));
    }
	// German extra key: ü (row0 idx 10)
	let (d, s) = key_pair_from_val(&r0[10]).with_context(|| "override row0 idx 10 (ü)")?;
	m.insert('ü', (d, s));

    let row1_letters = ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'];
    for (i, ch) in row1_letters.iter().enumerate() {
        let (d, s) =
            key_pair_from_val(&r1[i]).with_context(|| format!("override row1 idx {}", i))?;
        m.insert(*ch, (d, s));
    }
	// German extra keys: ö, ä (row1 idx 9,10)
	let (d, s) = key_pair_from_val(&r1[9]).with_context(|| "override row1 idx 9 (ö)")?;
	m.insert('ö', (d, s));

	let (d, s) = key_pair_from_val(&r1[10]).with_context(|| "override row1 idx 10 (ä)")?;
	m.insert('ä', (d, s));

    let row2_letters = ['y', 'x', 'c', 'v', 'b', 'n', 'm'];
    for (i, ch) in row2_letters.iter().enumerate() {
        let idx = i + 1; // skip shift
        let (d, s) =
            key_pair_from_val(&r2[idx]).with_context(|| format!("override row2 idx {}", idx))?;
        m.insert(*ch, (d, s));
    }

    Ok(m)
}

fn key_pair_from_val(v: &Value) -> Result<(String, String)> {
    let o = v.as_object().ok_or_else(|| anyhow!("key not object"))?;
    if o.get("special").is_some() {
        bail!("expected normal key, got special");
    }
    let def0 = get0_str_val(o, "default").ok_or_else(|| anyhow!("missing default[0]"))?;
    let sh0 = get0_str_val(o, "shifted").unwrap_or(def0);

    ensure_one_char(def0)?;
    ensure_one_char(sh0)?;

    Ok((def0.to_string(), sh0.to_string()))
}

fn ensure_one_char(s: &str) -> Result<()> {
    if s.chars().count() != 1 {
        bail!("expected 1 char, got {:?}", s);
    }
    Ok(())
}

fn get0_str_val<'a>(map: &'a serde_json::Map<String, Value>, field: &str) -> Option<&'a str> {
    map.get(field)?.as_array()?.get(0)?.as_str()
}

// Patch by base Latin letter. Replace WHOLE arrays (Python-style).
fn apply_mapping_by_base_letter(
    base: &mut Value,
    mapping: &HashMap<char, (String, String)>,
) -> Result<(usize, usize)> {
    let bobj = base.as_object_mut().ok_or_else(|| anyhow!("base not object"))?;
    let balpha = bobj
        .get_mut("alphabetic")
        .ok_or_else(|| anyhow!("base missing alphabetic"))?
        .as_array_mut()
        .ok_or_else(|| anyhow!("base alphabetic not array"))?;

    if balpha.len() < 3 {
        bail!("base alphabetic < 3 rows");
    }

    let mut touched = 0usize;
    let mut changed = 0usize;

    for row in balpha.iter_mut().take(3) {
        let row_arr = match row.as_array_mut() {
            Some(a) => a,
            None => continue,
        };
        for key in row_arr.iter_mut() {
            let ko = match key.as_object_mut() {
                Some(o) => o,
                None => continue,
            };
            if ko.get("special").is_some() {
                continue;
            }

            let base_def0 = match ko
                .get("default")
                .and_then(|v| v.as_array())
                .and_then(|a| a.get(0))
                .and_then(|v| v.as_str())
            {
                Some(s) => s,
                None => continue,
            };
            if base_def0.chars().count() != 1 {
                continue;
            }
            let c = base_def0.chars().next().unwrap();
            let key = if c.is_ascii_alphabetic() {
				c.to_ascii_lowercase()
			} else {
				c
			};

			if let Some((nd, ns)) = mapping.get(&key) {

                touched += 1;

                let cur_def0 = ko
                    .get("default")
                    .and_then(|v| v.as_array())
                    .and_then(|a| a.get(0))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let cur_sh0 = ko
                    .get("shifted")
                    .and_then(|v| v.as_array())
                    .and_then(|a| a.get(0))
                    .and_then(|v| v.as_str())
                    .unwrap_or(cur_def0);

                let cur_def_len = ko
                    .get("default")
                    .and_then(|v| v.as_array())
                    .map(|a| a.len())
                    .unwrap_or(0);
                let cur_sh_len = ko
                    .get("shifted")
                    .and_then(|v| v.as_array())
                    .map(|a| a.len())
                    .unwrap_or(0);

                let needs =
                    cur_def_len != 1 || cur_sh_len != 1 || cur_def0 != nd || cur_sh0 != ns;
                if needs {
                    ko.insert(
                        "default".to_string(),
                        Value::Array(vec![Value::String(nd.clone())]),
                    );
                    ko.insert(
                        "shifted".to_string(),
                        Value::Array(vec![Value::String(ns.clone())]),
                    );
                    changed += 1;
                }
            }
        }
    }

    Ok((touched, changed))
}

fn scan_keyboard_json(bytes: &[u8]) -> Result<Vec<(usize, u32, Value)>> {
    let finder = memmem::Finder::new(MAGIC_ZSTD);
    let mut out = Vec::new();
    let mut seen: HashSet<(usize, u32)> = HashSet::new();

    for hit in finder.find_iter(bytes) {
        if hit < 4 {
            continue;
        }
        let hdr_off = hit - 4;

        let cap_be = read_u32_be(bytes, hdr_off).unwrap_or(0);
        let cap_le = read_u32_le(bytes, hdr_off).unwrap_or(0);

        for cap in [cap_be, cap_le] {
            if cap < 80 || cap > 20000 {
                continue;
            }
            if !seen.insert((hdr_off, cap)) {
                continue;
            }

            let p0 = hdr_off + 4;
            let p1 = p0 + cap as usize;
            if p1 > bytes.len() {
                continue;
            }

            let payload = &bytes[p0..p1];
            if !payload.starts_with(MAGIC_ZSTD) {
                continue;
            }

            let decoded = match zstd::stream::decode_all(std::io::Cursor::new(payload)) {
                Ok(v) => v,
                Err(_) => continue,
            };
            let v: Value = match serde_json::from_slice(&decoded) {
                Ok(v) => v,
                Err(_) => continue,
            };

            if v.get("alphabetic").and_then(|x| x.as_array()).is_none() {
                continue;
            }
            out.push((hdr_off, cap, v));
        }
    }

    Ok(out)
}

fn compress_to_exact_cap(raw: &[u8], cap: usize) -> Result<(Vec<u8>, i32, usize)> {
    let levels: [i32; 8] = [3, 5, 8, 10, 12, 15, 18, 22];

    for &lvl in &levels {
        let comp = zstd::bulk::compress(raw, lvl).context("zstd bulk compress")?;
        if comp.len() > cap {
            continue;
        }
        let pad = cap - comp.len();
        if pad == 0 {
            return Ok((comp, lvl, 0));
        }
        if pad >= 8 {
            let mut out = Vec::with_capacity(cap);
            out.extend_from_slice(&comp);
            out.extend_from_slice(&make_skippable_frame(pad)?);
            if out.len() == cap {
                return Ok((out, lvl, pad));
            }
        }
    }

    bail!("unable to compress+pad to cap={}", cap)
}

fn make_skippable_frame(total_bytes: usize) -> Result<Vec<u8>> {
    if total_bytes < 8 {
        bail!("skippable needs >= 8");
    }
    let payload_len = (total_bytes - 8) as u32;
    let magic: u32 = 0x184D2A50;
    let mut v = Vec::with_capacity(total_bytes);
    v.extend_from_slice(&magic.to_le_bytes());
    v.extend_from_slice(&payload_len.to_le_bytes());
    v.extend(std::iter::repeat(0u8).take(payload_len as usize));
    Ok(v)
}

fn apply_in_place(path: &Path, plan: &Plan) -> Result<()> {
    let mut f = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .with_context(|| format!("open for write {}", path.display()))?;

    let off = (plan.hdr_off + 4) as u64;
    f.seek(SeekFrom::Start(off))?;
    f.write_all(&plan.new_payload)?;
    f.flush().ok();
    f.sync_all().ok();
    Ok(())
}

fn rollback_in_place(path: &Path, plan: &Plan) -> Result<()> {
    let mut f = OpenOptions::new().read(true).write(true).open(path)?;
    let off = (plan.hdr_off + 4) as u64;
    f.seek(SeekFrom::Start(off))?;
    f.write_all(&plan.old_payload)?;
    f.flush().ok();
    f.sync_all().ok();
    Ok(())
}

fn verify_one(path: &Path, plan: &Plan) -> Result<()> {
    let f = File::open(path)?;
    let mm = unsafe { Mmap::map(&f)? };
    let bytes: &[u8] = &mm[..];

    let cap_be = read_u32_be(bytes, plan.hdr_off).unwrap_or(0);
    let cap_le = read_u32_le(bytes, plan.hdr_off).unwrap_or(0);

    let cap = if cap_be == plan.cap { cap_be } else { cap_le };
    if cap != plan.cap {
        bail!("cap changed unexpectedly at 0x{:x}", plan.hdr_off);
    }

    let p0 = plan.hdr_off + 4;
    let p1 = p0 + cap as usize;
    if p1 > bytes.len() {
        bail!("verify out of range");
    }

    let payload = &bytes[p0..p1];
    if !payload.starts_with(MAGIC_ZSTD) {
        bail!("verify missing zstd magic");
    }

    let decoded = zstd::stream::decode_all(std::io::Cursor::new(payload)).context("zstd decode")?;
    let got: Value = serde_json::from_slice(&decoded).context("json parse verify")?;
    if got != plan.after {
        bail!("verify mismatch at 0x{:x}", plan.hdr_off);
    }

    Ok(())
}

fn dump_json(dir: &Path, locale: &str, tag: &str, hdr_off: usize, v: &Value) -> Result<()> {
    let p = dir.join(format!("{}.{}.0x{:x}.json", locale, tag, hdr_off));
    let b = serde_json::to_vec_pretty(v)?;
    fs::write(&p, b)?;
    Ok(())
}

fn read_u32_be(bytes: &[u8], off: usize) -> Result<u32> {
    if off + 4 > bytes.len() {
        bail!("read_u32_be out of range");
    }
    Ok(u32::from_be_bytes(
        bytes[off..off + 4].try_into().unwrap(),
    ))
}

fn read_u32_le(bytes: &[u8], off: usize) -> Result<u32> {
    if off + 4 > bytes.len() {
        bail!("read_u32_le out of range");
    }
    Ok(u32::from_le_bytes(
        bytes[off..off + 4].try_into().unwrap(),
    ))
}

fn sha256_with_schema(over_min: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(over_min);
    h.update(STATE_SCHEMA.as_bytes());
    hex::encode(h.finalize())
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut f = File::open(path).with_context(|| format!("open {}", path.display()))?;
    let mut h = Sha256::new();
    let mut buf = [0u8; 1024 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(hex::encode(h.finalize()))
}

fn ensure_backup(xochitl: &Path, backup_dir: &Path, sha: &str) -> Result<()> {
    fs::create_dir_all(backup_dir).ok();
    let p = backup_dir.join(format!("xochitl.{}.orig", sha));
    if p.exists() {
        return Ok(());
    }
    fs::copy(xochitl, &p).with_context(|| format!("backup to {}", p.display()))?;
    Ok(())
}

fn read_state(path: &Path) -> Option<StateFile> {
    let txt = fs::read_to_string(path).ok()?;
    serde_json::from_str::<StateFile>(&txt).ok()
}

fn write_state(path: &Path, st: &StateFile) -> Result<()> {
    if let Some(p) = path.parent() {
        fs::create_dir_all(p).ok();
    }
    let b = serde_json::to_vec_pretty(st)?;
    fs::write(path, b)?;
    Ok(())
}

fn read_text_allow_bom(path: &Path) -> Result<String> {
    let b = fs::read(path).with_context(|| format!("read {}", path.display()))?;
    if b.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return Ok(String::from_utf8(b[3..].to_vec()).context("utf8")?);
    }
    if b.starts_with(&[0xFF, 0xFE]) {
        if (b.len() - 2) % 2 != 0 {
            bail!("utf16le odd length");
        }
        let mut u16s = Vec::with_capacity((b.len() - 2) / 2);
        for i in (2..b.len()).step_by(2) {
            u16s.push(u16::from_le_bytes([b[i], b[i + 1]]));
        }
        return Ok(String::from_utf16(&u16s).context("utf16le")?);
    }
    if b.starts_with(&[0xFE, 0xFF]) {
        if (b.len() - 2) % 2 != 0 {
            bail!("utf16be odd length");
        }
        let mut u16s = Vec::with_capacity((b.len() - 2) / 2);
        for i in (2..b.len()).step_by(2) {
            u16s.push(u16::from_be_bytes([b[i], b[i + 1]]));
        }
        return Ok(String::from_utf16(&u16s).context("utf16be")?);
    }
    Ok(String::from_utf8(b).context("utf8")?)
}
