//! `brotli-oracle` - a small authoritative Rust Brotli oracle for the
//! brotli_neo project.
//!
//! It wraps the pure-Rust `brotli` crate (dropbox/rust-brotli) and offers:
//!
//!   * compress / decompress of files or stdin/stdout with quality, lgwin,
//!     mode (generic/text/font), lgblock and the non-RFC large-window switch;
//!   * `bench`: repeated encode/decode timing emitted as bench-svg canonical
//!     JSON (report object) and/or JSONL (one benchmark record per line);
//!   * `verify`: decode a .br stream and compare its SHA-256 with a raw file;
//!   * `info`: capability dump as JSON.
//!
//! Build:
//!   set CARGO_HOME=<repo>\.agents\tmp\cargo
//!   cargo build --release --manifest-path .agents\tools\oracle_rust\Cargo.toml
//!
//! The binary lands in `.agents/tools/oracle_rust/target/release/brotli-oracle(.exe)`.

use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::process::ExitCode;
use std::time::Instant;

use brotli::enc::backward_references::BrotliEncoderMode;
use brotli::enc::{BrotliEncoderParams, StandardAlloc};
use brotli::{
    Allocator, BrotliDecompressStream, BrotliResult, BrotliState, HeapAlloc, HuffmanCode,
    IoReaderWrapper, IoWriterWrapper, SliceWrapperMut,
};
use sha2::{Digest, Sha256};

const BROTLI_CRATE_VERSION: &str = "9.0.0";
const TOOL: &str = "rust-brotli-oracle";
const SCHEMA: &str = "bench-svg/report@1";

// ---------------------------------------------------------------------------
// small JSON helpers (no serde on purpose: one dependency, fast build)
// ---------------------------------------------------------------------------

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn json_str(s: &str) -> String {
    format!("\"{}\"", json_escape(s))
}

fn sha256_hex(data: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(data);
    let digest = h.finalize();
    let mut s = String::with_capacity(64);
    for b in digest {
        s.push_str(&format!("{:02x}", b));
    }
    s
}

// ---------------------------------------------------------------------------
// options
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct CompressOpts {
    quality: i32,
    lgwin: i32,
    lgblock: i32,
    mode: BrotliEncoderMode,
    large_window: bool,
    no_dictionary: bool,
    size_hint: usize,
}

impl Default for CompressOpts {
    fn default() -> Self {
        CompressOpts {
            quality: 11,
            lgwin: 22,
            lgblock: 0,
            mode: BrotliEncoderMode::BROTLI_MODE_GENERIC,
            large_window: false,
            no_dictionary: false,
            size_hint: 0,
        }
    }
}

impl CompressOpts {
    fn params(&self, input_len: usize) -> BrotliEncoderParams {
        let mut p = BrotliEncoderParams::default();
        p.quality = self.quality;
        p.lgwin = self.lgwin;
        p.lgblock = self.lgblock;
        p.mode = self.mode;
        p.large_window = self.large_window;
        p.use_dictionary = !self.no_dictionary;
        p.size_hint = if self.size_hint > 0 {
            self.size_hint
        } else {
            input_len
        };
        p
    }
}

fn mode_name(m: BrotliEncoderMode) -> &'static str {
    match m {
        BrotliEncoderMode::BROTLI_MODE_GENERIC => "generic",
        BrotliEncoderMode::BROTLI_MODE_TEXT => "text",
        BrotliEncoderMode::BROTLI_MODE_FONT => "font",
        BrotliEncoderMode::BROTLI_FORCE_LSB_PRIOR => "force-lsb-prior",
        BrotliEncoderMode::BROTLI_FORCE_MSB_PRIOR => "force-msb-prior",
        BrotliEncoderMode::BROTLI_FORCE_UTF8_PRIOR => "force-utf8-prior",
        BrotliEncoderMode::BROTLI_FORCE_SIGNED_PRIOR => "force-signed-prior",
    }
}

fn parse_mode(s: &str) -> Result<BrotliEncoderMode, String> {
    match s.to_ascii_lowercase().as_str() {
        "0" | "generic" | "m0" => Ok(BrotliEncoderMode::BROTLI_MODE_GENERIC),
        "1" | "text" | "m1" => Ok(BrotliEncoderMode::BROTLI_MODE_TEXT),
        "2" | "font" | "m2" => Ok(BrotliEncoderMode::BROTLI_MODE_FONT),
        other => Err(format!(
            "invalid mode {other:?}; expected 0/generic, 1/text or 2/font"
        )),
    }
}

fn parse_quality(s: &str) -> Result<i32, String> {
    let q: i32 = s
        .parse()
        .map_err(|_| format!("invalid quality {s:?}; expected an integer 0-11"))?;
    if !(0..=11).contains(&q) {
        return Err(format!("invalid quality {q}; range is 0-11"));
    }
    Ok(q)
}

fn parse_lgwin(s: &str) -> Result<i32, String> {
    let w: i32 = s
        .parse()
        .map_err(|_| format!("invalid lgwin {s:?}; expected an integer"))?;
    if !(10..=30).contains(&w) {
        return Err(format!(
            "invalid lgwin {w}; RFC 7932 range is 10-24, large-window extension 25-30"
        ));
    }
    Ok(w)
}

fn parse_lgblock(s: &str) -> Result<i32, String> {
    let b: i32 = s
        .parse()
        .map_err(|_| format!("invalid lgblock {s:?}; expected an integer"))?;
    if b != 0 && !(16..=24).contains(&b) {
        return Err(format!(
            "invalid lgblock {b}; range is 16-24, or 0 for the quality default"
        ));
    }
    Ok(b)
}

fn int_list<T, F>(s: &str, f: F) -> Result<Vec<T>, String>
where
    F: Fn(&str) -> Result<T, String>,
{
    let mut out = Vec::new();
    for part in s.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        out.push(f(part)?);
    }
    if out.is_empty() {
        return Err(format!("empty list {s:?}"));
    }
    Ok(out)
}

fn mode_list(s: &str) -> Result<Vec<BrotliEncoderMode>, String> {
    let mut out = Vec::new();
    for part in s.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        out.push(parse_mode(part)?);
    }
    if out.is_empty() {
        return Err(format!("empty mode list {s:?}"));
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// io helpers
// ---------------------------------------------------------------------------

fn read_input(path: &str) -> Result<Vec<u8>, String> {
    if path == "-" {
        let mut data = Vec::new();
        io::stdin()
            .read_to_end(&mut data)
            .map_err(|e| format!("read stdin: {e}"))?;
        Ok(data)
    } else {
        fs::read(path).map_err(|e| format!("read {path}: {e}"))
    }
}

fn write_output(path: &str, data: &[u8]) -> Result<(), String> {
    if path == "-" {
        let stdout = io::stdout();
        let mut lock = stdout.lock();
        lock.write_all(data)
            .and_then(|_| lock.flush())
            .map_err(|e| format!("write stdout: {e}"))
    } else {
        fs::write(path, data).map_err(|e| format!("write {path}: {e}"))
    }
}

fn compress_bytes(data: &[u8], opts: &CompressOpts) -> Result<Vec<u8>, String> {
    let params = opts.params(data.len());
    let mut out = Vec::with_capacity(data.len() / 2 + 64);
    brotli::BrotliCompress(&mut &data[..], &mut out, &params)
        .map_err(|e| format!("brotli compress: {e}"))?;
    Ok(out)
}

fn compress_bytes_streaming(
    data: &[u8],
    opts: &CompressOpts,
    chunk: usize,
) -> Result<Vec<u8>, String> {
    let params = opts.params(data.len());
    let mut reader = brotli::CompressorReader::with_params(&data[..], chunk.max(1), &params);
    let mut out = Vec::new();
    reader
        .read_to_end(&mut out)
        .map_err(|e| format!("brotli streaming compress: {e}"))?;
    Ok(out)
}

fn decompress_bytes_streaming(data: &[u8], chunk: usize) -> Result<Vec<u8>, String> {
    // The public streaming reader stops at the end of the first brotli stream
    // and leaves trailing bytes unread (and unreported); one-shot strict mode
    // (`decompress_strict`) is the default for verification.
    let mut reader = brotli::Decompressor::new(&data[..], chunk.max(1));
    let mut out = Vec::new();
    reader
        .read_to_end(&mut out)
        .map_err(|e| format!("brotli streaming decompress: {e}"))?;
    Ok(out)
}

/// Encode with a raw-prefix (custom/compound) dictionary supplied as one file.
///
/// This exercises the crate's `BrotliCompressCustomIoCustomDict` API, which is
/// otherwise not reachable through the high-level one-shot helper.
fn compress_bytes_with_dict(
    data: &[u8],
    opts: &CompressOpts,
    dict: &[u8],
) -> Result<Vec<u8>, String> {
    let params = opts.params(data.len());
    let mut out = Vec::new();
    let mut input_buffer = vec![0u8; 65536];
    let mut output_buffer = vec![0u8; 65536];
    let mut callback = |_pm: &mut brotli::interface::PredictionModeContextMap<
        brotli::InputReferenceMut,
    >,
                        _commands: &mut [brotli::interface::StaticCommand],
                        _input: brotli::InputPair,
                        _alloc: &mut StandardAlloc| {};
    brotli::BrotliCompressCustomIoCustomDict(
        &mut IoReaderWrapper(&mut &data[..]),
        &mut IoWriterWrapper(&mut out),
        &mut input_buffer,
        &mut output_buffer,
        &params,
        StandardAlloc::default(),
        &mut callback,
        dict,
        io::Error::new(io::ErrorKind::UnexpectedEof, "unexpected EOF"),
    )
    .map_err(|e| format!("brotli custom-dictionary compress: {e}"))?;
    Ok(out)
}

/// Decode with the same raw-prefix dictionary.  The low-level dictionary API
/// is stream-oriented, so (like `--chunk-size`) it does not report trailing
/// bytes; strict verification should use the no-dictionary one-shot path.
fn decompress_bytes_with_dict(data: &[u8], dict: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    let mut input_buffer = vec![0u8; 65536];
    let mut output_buffer = vec![0u8; 65536];
    let mut alloc_u8 = HeapAlloc::<u8>::new(0);
    let mut dict_mem = alloc_u8.alloc_cell(dict.len());
    dict_mem.slice_mut().copy_from_slice(dict);
    brotli::BrotliDecompressCustomIoCustomDict(
        &mut IoReaderWrapper(&mut &data[..]),
        &mut IoWriterWrapper(&mut out),
        &mut input_buffer,
        &mut output_buffer,
        alloc_u8,
        HeapAlloc::<u32>::new(0),
        HeapAlloc::<HuffmanCode>::new(HuffmanCode { bits: 2, value: 1 }),
        dict_mem,
        io::Error::new(io::ErrorKind::UnexpectedEof, "unexpected EOF"),
    )
    .map_err(|e| format!("brotli custom-dictionary decompress: {e}"))?;
    Ok(out)
}

/// Strict one-shot decode: unlike `brotli::BrotliDecompress`, this reports how
/// many input bytes were left after the first stream ended, so trailing junk
/// and concatenated streams are rejected (the strict RFC 7932 harness policy).
///
/// `allow_large_window` selects the decoder variant that accepts the non-RFC
/// "Large Window Brotli" stream header (lgwin 25-30).  The default variant is
/// strict RFC 7932.
fn decompress_bytes(data: &[u8], allow_large_window: bool) -> Result<(Vec<u8>, usize), String> {
    let alloc_u8 = HeapAlloc::<u8>::new(0);
    let alloc_u32 = HeapAlloc::<u32>::new(0);
    let alloc_hc = HeapAlloc::<HuffmanCode>::new(HuffmanCode { bits: 2, value: 1 });
    let mut state = if allow_large_window {
        BrotliState::new(alloc_u8, alloc_u32, alloc_hc)
    } else {
        BrotliState::new_strict(alloc_u8, alloc_u32, alloc_hc)
    };

    let mut available_in = data.len();
    let mut input_offset = 0usize;
    let mut out = Vec::with_capacity(data.len().saturating_mul(2).max(64));
    let mut output = vec![0u8; 65536];
    let mut available_out = output.len();
    let mut output_offset = 0usize;
    let mut total_out = 0usize;

    loop {
        let result = BrotliDecompressStream(
            &mut available_in,
            &mut input_offset,
            data,
            &mut available_out,
            &mut output_offset,
            &mut output,
            &mut total_out,
            &mut state,
        );
        match result {
            BrotliResult::ResultSuccess => {
                out.extend_from_slice(&output[..output_offset]);
                break;
            }
            BrotliResult::NeedsMoreOutput => {
                out.extend_from_slice(&output[..output_offset]);
                output_offset = 0;
                available_out = output.len();
            }
            BrotliResult::NeedsMoreInput => {
                return Err("unexpected end of compressed input (truncated stream)".to_string());
            }
            BrotliResult::ResultFailure => {
                return Err("invalid brotli stream (decoder failure)".to_string());
            }
        }
    }
    Ok((out, data.len().saturating_sub(input_offset)))
}

/// Strict decode that rejects trailing bytes.
fn decompress_strict(data: &[u8], allow_large_window: bool) -> Result<Vec<u8>, String> {
    let (out, leftover) = decompress_bytes(data, allow_large_window)?;
    if leftover > 0 {
        return Err(format!(
            "{leftover} trailing byte(s) after the end of the brotli stream"
        ));
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// bench records
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct BenchRecord {
    id: String,
    group: String,
    label: String,
    note: String,
    unit: String,
    value: f64,
    params: Vec<(String, String)>,
    rme_pct: Option<f64>,
}

impl BenchRecord {
    fn to_json(&self) -> String {
        let mut s = String::new();
        s.push('{');
        s.push_str(&format!("\"id\":{}", json_str(&self.id)));
        if !self.group.is_empty() {
            s.push_str(&format!(",\"group\":{}", json_str(&self.group)));
        }
        if !self.label.is_empty() {
            s.push_str(&format!(",\"label\":{}", json_str(&self.label)));
        }
        if !self.note.is_empty() {
            s.push_str(&format!(",\"note\":{}", json_str(&self.note)));
        }
        s.push_str(&format!(",\"unit\":{}", json_str(&self.unit)));
        s.push_str(&format!(",\"value\":{:.6}", self.value));
        s.push_str(",\"direction\":\"higher\"");
        if !self.params.is_empty() {
            s.push_str(",\"params\":{");
            for (i, (k, v)) in self.params.iter().enumerate() {
                if i > 0 {
                    s.push(',');
                }
                s.push_str(&format!("{}:{}", json_str(k), json_str(v)));
            }
            s.push('}');
        }
        if let Some(rme) = self.rme_pct {
            s.push_str(&format!(",\"stats\":{{\"rme_pct\":{:.4}}}", rme));
        }
        s.push('}');
        s
    }
}

struct Stats {
    mean_secs: f64,
    rme_pct: f64,
}

fn stats(samples: &[f64]) -> Stats {
    // samples are per-round wall seconds
    if samples.is_empty() {
        return Stats {
            mean_secs: 0.0,
            rme_pct: 0.0,
        };
    }
    let n = samples.len() as f64;
    let mean = samples.iter().sum::<f64>() / n;
    if samples.len() < 2 {
        return Stats {
            mean_secs: mean,
            rme_pct: 0.0,
        };
    }
    let var = samples
        .iter()
        .map(|x| {
            let d = x - mean;
            d * d
        })
        .sum::<f64>()
        / (n - 1.0);
    let sd = var.sqrt();
    let rme = 1.96 * sd / n.sqrt() / mean * 100.0;
    Stats {
        mean_secs: mean,
        rme_pct: rme,
    }
}

fn convert_unit(bytes_per_sec: f64, unit: &str) -> Result<f64, String> {
    let factor = match unit.to_ascii_lowercase().as_str() {
        "b/s" => 1.0,
        "kb/s" => 1e3,
        "mb/s" => 1e6,
        "mib/s" => 1024.0 * 1024.0,
        "gb/s" => 1e9,
        "gib/s" => 1024.0 * 1024.0 * 1024.0,
        other => {
            return Err(format!(
                "unsupported --unit {other:?}; use B/s, KB/s, MB/s, MiB/s, GB/s or GiB/s"
            ))
        }
    };
    Ok(bytes_per_sec / factor)
}

fn default_label(path: &str) -> String {
    if path == "-" {
        return "stdin".to_string();
    }
    let p = std::path::Path::new(path);
    p.file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| path.to_string())
}

fn human_bytes(n: usize) -> String {
    let f = n as f64;
    if f >= 1024.0 * 1024.0 {
        format!("{:.2} MiB", f / (1024.0 * 1024.0))
    } else if f >= 1024.0 {
        format!("{:.2} KiB", f / 1024.0)
    } else {
        format!("{n} B")
    }
}

// ---------------------------------------------------------------------------
// commands
// ---------------------------------------------------------------------------

fn cmd_compress(args: &[String]) -> Result<ExitCode, String> {
    let mut opts = CompressOpts::default();
    let mut input = "-".to_string();
    let mut output = "-".to_string();
    let mut chunk_size: usize = 0;
    let mut dictionary: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-i" | "--input" => {
                input = take(args, &mut i, "--input")?;
            }
            "-o" | "--output" => {
                output = take(args, &mut i, "--output")?;
            }
            "-q" | "--quality" => {
                opts.quality = parse_quality(&take(args, &mut i, "--quality")?)?;
            }
            "-w" | "--lgwin" => {
                opts.lgwin = parse_lgwin(&take(args, &mut i, "--lgwin")?)?;
            }
            "-m" | "--mode" => {
                opts.mode = parse_mode(&take(args, &mut i, "--mode")?)?;
            }
            "--lgblock" => {
                opts.lgblock = parse_lgblock(&take(args, &mut i, "--lgblock")?)?;
            }
            "--chunk-size" | "--buffer-size" => {
                chunk_size = take(args, &mut i, "--chunk-size")?
                    .parse()
                    .map_err(|_| "--chunk-size expects a positive byte count".to_string())?;
            }
            "--dictionary" | "--custom-dictionary" => {
                dictionary = Some(take(args, &mut i, "--dictionary")?);
            }
            "--large-window" => {
                opts.large_window = true;
                i += 1;
            }
            "--no-dictionary" => {
                opts.no_dictionary = true;
                i += 1;
            }
            "--size-hint" => {
                opts.size_hint = take(args, &mut i, "--size-hint")?
                    .parse()
                    .map_err(|_| "--size-hint expects a byte count".to_string())?;
            }
            "-h" | "--help" => {
                print!("{COMPRESS_HELP}");
                return Ok(ExitCode::SUCCESS);
            }
            other => return Err(format!("unknown compress option {other:?}")),
        }
    }
    if !opts.large_window && !(10..=24).contains(&opts.lgwin) {
        return Err(format!(
            "lgwin {} requires --large-window (non-RFC extension)",
            opts.lgwin
        ));
    }
    let data = read_input(&input)?;
    let out = if let Some(dict_path) = &dictionary {
        if chunk_size > 0 {
            return Err("--dictionary cannot be combined with --chunk-size".to_string());
        }
        let dict = fs::read(dict_path).map_err(|e| format!("read dictionary {dict_path}: {e}"))?;
        compress_bytes_with_dict(&data, &opts, &dict)?
    } else if chunk_size > 0 {
        compress_bytes_streaming(&data, &opts, chunk_size)?
    } else {
        compress_bytes(&data, &opts)?
    };
    write_output(&output, &out)?;
    Ok(ExitCode::SUCCESS)
}

fn cmd_decompress(args: &[String]) -> Result<ExitCode, String> {
    let mut input = "-".to_string();
    let mut output = "-".to_string();
    let mut large_window = false;
    let mut chunk_size: usize = 0;
    let mut dictionary: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-i" | "--input" => input = take(args, &mut i, "--input")?,
            "-o" | "--output" => output = take(args, &mut i, "--output")?,
            "--large-window" => {
                large_window = true;
                i += 1;
            }
            "--chunk-size" | "--buffer-size" => {
                chunk_size = take(args, &mut i, "--chunk-size")?
                    .parse()
                    .map_err(|_| "--chunk-size expects a positive byte count".to_string())?;
            }
            "--dictionary" | "--custom-dictionary" => {
                dictionary = Some(take(args, &mut i, "--dictionary")?);
            }
            "-h" | "--help" => {
                print!("{DECOMPRESS_HELP}");
                return Ok(ExitCode::SUCCESS);
            }
            other => return Err(format!("unknown decompress option {other:?}")),
        }
    }
    let data = read_input(&input)?;
    let out = if let Some(dict_path) = &dictionary {
        if chunk_size > 0 {
            return Err("--dictionary cannot be combined with --chunk-size".to_string());
        }
        let dict = fs::read(dict_path).map_err(|e| format!("read dictionary {dict_path}: {e}"))?;
        decompress_bytes_with_dict(&data, &dict)?
    } else if chunk_size > 0 {
        decompress_bytes_streaming(&data, chunk_size)?
    } else {
        decompress_strict(&data, large_window)?
    };
    write_output(&output, &out)?;
    Ok(ExitCode::SUCCESS)
}

fn cmd_verify(args: &[String]) -> Result<ExitCode, String> {
    let mut raw_path = "-".to_string();
    let mut packed_path: Option<String> = None;
    let mut expect_sha: Option<String> = None;
    let mut large_window = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-i" | "--input" | "--raw" => raw_path = take(args, &mut i, "--input")?,
            "-c" | "--compressed" => packed_path = Some(take(args, &mut i, "--compressed")?),
            "--sha256" => expect_sha = Some(take(args, &mut i, "--sha256")?),
            "--large-window" => {
                large_window = true;
                i += 1;
            }
            "-h" | "--help" => {
                print!("{VERIFY_HELP}");
                return Ok(ExitCode::SUCCESS);
            }
            other => return Err(format!("unknown verify option {other:?}")),
        }
    }
    let packed_path = packed_path.ok_or("verify requires --compressed PATH")?;
    let raw = read_input(&raw_path)?;
    let packed = read_input(&packed_path)?;
    let (decoded, leftover) = match decompress_bytes(&packed, large_window) {
        Ok(d) => d,
        Err(e) => {
            println!(
                "{{\"ok\":false,\"tool\":{},\"error\":{},\"compressed\":{},\"compressed_bytes\":{},\"raw_bytes\":{}}}",
                json_str(TOOL),
                json_str(&e),
                json_str(&packed_path),
                packed.len(),
                raw.len()
            );
            return Ok(ExitCode::from(2));
        }
    };
    let raw_sha = sha256_hex(&raw);
    let decoded_sha = sha256_hex(&decoded);
    let sha_ok = match &expect_sha {
        Some(s) => s.eq_ignore_ascii_case(&raw_sha),
        None => true,
    };
    let ok = decoded == raw && sha_ok && leftover == 0;
    println!(
        "{{\"ok\":{},\"tool\":{},\"compressed\":{},\"compressed_bytes\":{},\"raw_bytes\":{},\"decoded_bytes\":{},\"trailing_bytes\":{},\"raw_sha256\":{},\"decoded_sha256\":{},\"expected_sha256\":{},\"expected_sha256_matches\":{}}}",
        ok,
        json_str(TOOL),
        json_str(&packed_path),
        packed.len(),
        raw.len(),
        decoded.len(),
        leftover,
        json_str(&raw_sha),
        json_str(&decoded_sha),
        match &expect_sha {
            Some(s) => json_str(s),
            None => "null".to_string(),
        },
        sha_ok
    );
    Ok(if ok {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    })
}

fn platform_json() -> String {
    let cpu = env::var("PROCESSOR_IDENTIFIER").unwrap_or_else(|_| String::new());
    let cores = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(0);
    format!(
        "{{\"os\":{},\"arch\":{},\"cpu\":{},\"cores\":{}}}",
        json_str(env::consts::OS),
        json_str(env::consts::ARCH),
        json_str(&cpu),
        cores
    )
}

fn cmd_info(_args: &[String]) -> Result<ExitCode, String> {
    let cpu = platform_json();
    println!(
        "{{\"tool\":{},\"cli_version\":{},\"brotli_crate\":{},\"schema\":{},\"platform\":{},\"quality\":{{\"min\":0,\"max\":11}},\"lgwin\":{{\"rfc_min\":10,\"rfc_max\":24,\"large_min\":25,\"large_max\":30,\"large_window_default\":false}},\"lgblock\":{{\"default\":0,\"min\":16,\"max\":24}},\"modes\":[\"0/generic\",\"1/text\",\"2/font\"],\"custom_dictionary_cli\":true,\"custom_dictionary_scope\":\"one raw-prefix dictionary file per stream; stream-oriented, no trailing-byte reporting\",\"notes\":\"pure-Rust dropbox/rust-brotli; large-window is a non-RFC extension\"}}",
        json_str(TOOL),
        json_str(env!("CARGO_PKG_VERSION")),
        json_str(BROTLI_CRATE_VERSION),
        json_str(SCHEMA),
        cpu
    );
    Ok(ExitCode::SUCCESS)
}

fn cmd_bench(args: &[String]) -> Result<ExitCode, String> {
    let mut inputs: Vec<String> = Vec::new();
    let mut labels: Vec<String> = Vec::new();
    let mut qualities: Vec<i32> = vec![11];
    let mut lgwins: Vec<i32> = vec![22];
    let mut modes: Vec<BrotliEncoderMode> = vec![BrotliEncoderMode::BROTLI_MODE_GENERIC];
    let mut lgblock: i32 = 0;
    let mut rounds: usize = 5;
    let mut warmup: usize = 1;
    let mut unit = "MB/s".to_string();
    let mut jsonl_path: Option<String> = None;
    let mut json_path: Option<String> = None;
    let mut tool_version = BROTLI_CRATE_VERSION.to_string();
    let mut large_window = false;
    let mut no_dictionary = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-i" | "--input" => inputs.push(take(args, &mut i, "--input")?),
            "--label" => labels.push(take(args, &mut i, "--label")?),
            "-q" | "--quality" | "--qualities" => {
                qualities = int_list(&take(args, &mut i, "--qualities")?, parse_quality)?;
            }
            "-w" | "--lgwin" | "--lgwins" => {
                lgwins = int_list(&take(args, &mut i, "--lgwins")?, parse_lgwin)?;
            }
            "-m" | "--mode" | "--modes" => {
                modes = mode_list(&take(args, &mut i, "--modes")?)?;
            }
            "--lgblock" => lgblock = parse_lgblock(&take(args, &mut i, "--lgblock")?)?,
            "--rounds" => {
                rounds = take(args, &mut i, "--rounds")?
                    .parse()
                    .map_err(|_| "--rounds expects a positive integer".to_string())?;
                if rounds == 0 {
                    return Err("--rounds must be >= 1".to_string());
                }
            }
            "--warmup" => {
                warmup = take(args, &mut i, "--warmup")?
                    .parse()
                    .map_err(|_| "--warmup expects an integer".to_string())?;
            }
            "--unit" => unit = take(args, &mut i, "--unit")?,
            "--jsonl" => jsonl_path = Some(take(args, &mut i, "--jsonl")?),
            "--json" => json_path = Some(take(args, &mut i, "--json")?),
            "--tool-version" => tool_version = take(args, &mut i, "--tool-version")?,
            "--large-window" => {
                large_window = true;
                i += 1;
            }
            "--no-dictionary" => {
                no_dictionary = true;
                i += 1;
            }
            "-h" | "--help" => {
                print!("{BENCH_HELP}");
                return Ok(ExitCode::SUCCESS);
            }
            other => return Err(format!("unknown bench option {other:?}")),
        }
    }

    if inputs.is_empty() {
        inputs.push("-".to_string());
    }
    while labels.len() < inputs.len() {
        labels.push(default_label(&inputs[labels.len()]));
    }

    let mut records: Vec<BenchRecord> = Vec::new();
    for (idx, input) in inputs.iter().enumerate() {
        let label = labels[idx].clone();
        let data = read_input(input)?;
        for &q in &qualities {
            for &lgwin in &lgwins {
                if !large_window && !(10..=24).contains(&lgwin) {
                    return Err(format!(
                        "lgwin {lgwin} requires --large-window (non-RFC extension)"
                    ));
                }
                for &mode in &modes {
                    let opts = CompressOpts {
                        quality: q,
                        lgwin,
                        lgblock,
                        mode,
                        large_window,
                        no_dictionary,
                        size_hint: data.len(),
                    };
                    // Compress once for size and for the decompress benchmark.
                    let packed = compress_bytes(&data, &opts)?;
                    let pack_ratio = data.len() as f64 / packed.len().max(1) as f64;

                    // warmup
                    for _ in 0..warmup {
                        let _ = compress_bytes(&data, &opts)?;
                        let _ = decompress_strict(&packed, large_window)?;
                    }

                    let mut enc_samples = Vec::with_capacity(rounds);
                    let mut enc_bytes = 0usize;
                    for _ in 0..rounds {
                        let t = Instant::now();
                        let out = compress_bytes(&data, &opts)?;
                        enc_samples.push(t.elapsed().as_secs_f64());
                        enc_bytes = out.len();
                    }
                    let enc = stats(&enc_samples);
                    let enc_bps = data.len() as f64 / enc.mean_secs.max(1e-12);
                    let enc_value = convert_unit(enc_bps, &unit)?;

                    let mut dec_samples = Vec::with_capacity(rounds);
                    let mut dec_bytes = 0usize;
                    for _ in 0..rounds {
                        let t = Instant::now();
                        let out = decompress_strict(&packed, large_window)?;
                        dec_samples.push(t.elapsed().as_secs_f64());
                        dec_bytes = out.len();
                    }
                    if dec_bytes != data.len() {
                        return Err(format!(
                            "decompress round-trip mismatch for {} ({} != {})",
                            label,
                            dec_bytes,
                            data.len()
                        ));
                    }
                    let dec = stats(&dec_samples);
                    let dec_bps = data.len() as f64 / dec.mean_secs.max(1e-12);
                    let dec_value = convert_unit(dec_bps, &unit)?;

                    let base_params = vec![
                        ("tool".to_string(), "rust".to_string()),
                        ("backend".to_string(), "dropbox/rust-brotli".to_string()),
                        ("quality".to_string(), q.to_string()),
                        ("lgwin".to_string(), lgwin.to_string()),
                        ("mode".to_string(), mode_name(mode).to_string()),
                        ("input".to_string(), label.clone()),
                        ("raw_bytes".to_string(), data.len().to_string()),
                        ("compressed_bytes".to_string(), enc_bytes.to_string()),
                        ("ratio".to_string(), format!("{pack_ratio:.3}")),
                        ("bytes_per_second".to_string(), format!("{enc_bps:.0}")),
                    ];
                    let mut cparams = base_params.clone();
                    cparams.push(("op".to_string(), "compress".to_string()));
                    let id_prefix = format!(
                        "brotli.compress.q{q}.lgwin{lgwin}.mode{}",
                        mode as i32
                    );
                    records.push(BenchRecord {
                        id: format!("{id_prefix}.{label}"),
                        group: "brotli throughput".to_string(),
                        label: format!(
                            "Rust compress Q{q} lgwin {lgwin} {} - {label}",
                            mode_name(mode)
                        ),
                        note: format!(
                            "Q{q} · lgwin {lgwin} · {} · {} -> {} ({pack_ratio:.2}x)",
                            mode_name(mode),
                            human_bytes(data.len()),
                            human_bytes(enc_bytes)
                        ),
                        unit: unit.clone(),
                        value: enc_value,
                        params: cparams,
                        rme_pct: Some(enc.rme_pct),
                    });
                    let mut dparams = base_params;
                    dparams.push(("op".to_string(), "decompress".to_string()));
                    dparams.push((
                        "bytes_per_second".to_string(),
                        format!("{dec_bps:.0}"),
                    ));
                    let id_prefix = format!(
                        "brotli.decompress.q{q}.lgwin{lgwin}.mode{}",
                        mode as i32
                    );
                    records.push(BenchRecord {
                        id: format!("{id_prefix}.{label}"),
                        group: "brotli throughput".to_string(),
                        label: format!(
                            "Rust decompress Q{q} lgwin {lgwin} {} - {label}",
                            mode_name(mode)
                        ),
                        note: format!(
                            "Q{q} · lgwin {lgwin} · {} · decode {}",
                            mode_name(mode),
                            human_bytes(data.len())
                        ),
                        unit: unit.clone(),
                        value: dec_value,
                        params: dparams,
                        rme_pct: Some(dec.rme_pct),
                    });
                }
            }
        }
    }

    let jsonl = records
        .iter()
        .map(|r| r.to_json())
        .collect::<Vec<_>>()
        .join("\n");
    if let Some(path) = &jsonl_path {
        fs::write(path, format!("{jsonl}\n")).map_err(|e| format!("write {path}: {e}"))?;
    }
    if let Some(path) = &json_path {
        let report = format!(
            "{{\"schema\":{},\"meta\":{{\"tool\":{},\"tool_version\":{},\"platform\":{},\"backend\":\"dropbox/rust-brotli\"}},\"benchmarks\":[{}]}}\n",
            json_str(SCHEMA),
            json_str(TOOL),
            json_str(&tool_version),
            platform_json(),
            records
                .iter()
                .map(|r| r.to_json())
                .collect::<Vec<_>>()
                .join(",")
        );
        fs::write(path, report).map_err(|e| format!("write {path}: {e}"))?;
    }
    if jsonl_path.is_none() && json_path.is_none() {
        println!("{jsonl}");
    }
    Ok(ExitCode::SUCCESS)
}

fn take(args: &[String], i: &mut usize, name: &str) -> Result<String, String> {
    if *i + 1 >= args.len() {
        return Err(format!("{name} requires a value"));
    }
    let v = args[*i + 1].clone();
    *i += 2;
    Ok(v)
}

// ---------------------------------------------------------------------------
// help / main
// ---------------------------------------------------------------------------

const COMPRESS_HELP: &str = "\
brotli-oracle compress - encode a file or stdin with the Rust brotli crate

Usage:
  brotli-oracle compress [options]

Options:
  -i, --input PATH        input file, or '-' for stdin (default: -)
  -o, --output PATH       output file, or '-' for stdout (default: -)
  -q, --quality N         quality 0-11 (default: 11)
  -w, --lgwin N           window bits 10-24; 25-30 with --large-window (default: 22)
  -m, --mode MODE         0/generic, 1/text, 2/font (default: generic)
      --lgblock N         input block bits 16-24, or 0 for the quality default
      --chunk-size N      use the streaming CompressorReader with an N-byte buffer
                          (0 = one-shot, default)
      --dictionary FILE   raw-prefix custom/compound dictionary (library API path);
                          cannot be combined with --chunk-size
      --large-window      non-RFC extension: allow lgwin 25-30
      --no-dictionary     do not use the built-in static dictionary
      --size-hint N       override the encoder size hint (default: input length)
  -h, --help              show this help
";

const DECOMPRESS_HELP: &str = "\
brotli-oracle decompress - decode a .br stream from a file or stdin

Usage:
  brotli-oracle decompress [options]

Options:
  -i, --input PATH        compressed input file, or '-' for stdin (default: -)
  -o, --output PATH       raw output file, or '-' for stdout (default: -)
      --chunk-size N      use the streaming Decompressor with an N-byte buffer
                          (0 = strict one-shot, default; streaming ignores trailing)
      --dictionary FILE   raw-prefix custom/compound dictionary (library API path;
                          stream-oriented, ignores trailing bytes)
      --large-window      accept the non-RFC large-window stream header (lgwin 25-30)
  -h, --help              show this help
";

const VERIFY_HELP: &str = "\
brotli-oracle verify - decode a .br stream and compare it with a raw file

Usage:
  brotli-oracle verify -i RAW --compressed STREAM.br [--sha256 HEX] [--large-window]

Strict one-shot decode: truncated streams, corrupt streams and trailing bytes
after the first stream all fail. Exit codes: 0 match, 1 mismatch, 2 decode error.
";

const BENCH_HELP: &str = "\
brotli-oracle bench - time encode/decode and emit bench-svg canonical data

Usage:
  brotli-oracle bench [options] -i FILE [-i FILE ...]

Options:
  -i, --input PATH        corpus file, '-' for stdin; repeatable (default: -)
      --label NAME        label for the preceding input (default: file stem)
  -q, --qualities LIST    comma list of qualities 0-11 (default: 11)
  -w, --lgwins LIST       comma list of window bits 10-24 (default: 22)
  -m, --modes LIST        comma list of 0/generic,1/text,2/font (default: generic)
      --lgblock N         input block bits 16-24, or 0 (default: 0)
      --rounds N          timed rounds (default: 5)
      --warmup N          warmup runs (default: 1)
      --unit UNIT         B/s, KB/s, MB/s (default), MiB/s, GB/s, GiB/s
      --jsonl PATH        write one canonical benchmark record per line
      --json PATH         write one bench-svg/report@1 JSON object
      --tool-version S    tool_version in the report meta (default: 9.0.0)
      --large-window      non-RFC extension: allow lgwin 25-30
      --no-dictionary     do not use the built-in static dictionary
  -h, --help              show this help
";

fn run() -> Result<ExitCode, String> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        print!("{USAGE}");
        return Ok(ExitCode::from(64));
    }
    match args[0].as_str() {
        "compress" => cmd_compress(&args[1..]),
        "decompress" => cmd_decompress(&args[1..]),
        "verify" => cmd_verify(&args[1..]),
        "bench" => cmd_bench(&args[1..]),
        "info" => cmd_info(&args[1..]),
        "-h" | "--help" | "help" => {
            print!("{USAGE}");
            Ok(ExitCode::SUCCESS)
        }
        other => Err(format!(
            "unknown subcommand {other:?}; expected compress, decompress, verify, bench or info"
        )),
    }
}

const USAGE: &str = "\
brotli-oracle - authoritative Rust Brotli oracle (crate brotli 9.0.0)

Usage:
  brotli-oracle <command> [options]

Commands:
  compress      encode a file or stdin
  decompress    decode a .br file or stdin
  verify        decode and compare SHA-256 against a raw file
  bench         time encode/decode, emit bench-svg canonical JSON/JSONL
  info          print capability information as JSON

Run `brotli-oracle <command> --help` for command options.
";

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(e) => {
            eprintln!("brotli-oracle: {e}");
            ExitCode::from(64)
        }
    }
}
