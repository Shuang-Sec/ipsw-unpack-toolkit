# ipsw-unpack-toolkit

**English** | [简体中文](README.zh-CN.md)

Unpack the `dyld_shared_cache` out of a public Apple IPSW — no jailbreak, no physical device,
no developer account.

This is a small, focused toolkit built around three concrete problems that break the usual
extraction pipeline. Each is documented below with the symptom, the root cause, and how this
repo works around it.

---

## What this solves

### Problem 1 — APFS unpacking fails without `apfs-fuse`

**Symptom**

```
$ ipsw extract --dyld --remote <IPSW_URL> -o out/
[!] failed to find apfs-fuse
```

Nothing is extracted. `ipsw` has already decrypted the image, but it cannot read the
filesystem inside without a mounter.

**Root cause**

`ipsw` shells out to `apfs-fuse` to mount the APFS volume. That binary is awkward to depend on:

- it needs the FUSE kernel module, which containers and CI runners usually lack;
- it links against an old `libcrypto` and frequently fails to build on current distros;
- mounting a volume requires root.

**Fix**

`ipsw` accepts an `IPSW_APFS_FUSE_PATH` override for the mounter. `src/fake-apfs-fuse`
uses that hook: instead of mounting anything, it hands 7-Zip an include list and extracts
**only** the files under `System/Library/Caches/com.apple.dyld/`.

Two benefits beyond "it runs":

| | Full mount | This toolkit |
| :--- | ---: | ---: |
| APFS content unpacked | ~3.8 GB | ~520 MB |
| Root required | yes | no |
| FUSE required | yes | no |

The intermediate image is deleted right after extraction, so peak disk usage stays near 5 GB.

---

### Problem 2 — files unpack to 0 bytes

**Symptom**

```
dyld_shared_cache_arm64e.35.dylddata      0 bytes
```

7-Zip reports `ERROR: Unsupported Method` and leaves an empty file. The file is present and
correctly named, so downstream parsers fail with confusing "no data" errors instead of an
obvious decompression failure.

**Root cause**

Some files on APFS are stored with **transparent compression** (`decmpfs`): the payload lives
in `<file>:com.apple.ResourceFork`, with a small header in `<file>:com.apple.decmpfs`.

Compression type **14 = `CMP_RSRC_LZBITMAP`** has **no public specification**. Neither 7-Zip
nor any mainstream archive library implements it, so the file silently comes out empty.

On some device models the `.dylddata` segment — which holds the string pool and constant
arrays — is stored exactly this way. Skip this step and you get files that exist but contain
nothing.

**Fix**

`src/lzbitmap/` is a dependency-free C implementation of the LZBitmap decompressor
(`libzbitmap.c`, ~1,200 lines) plus a CLI (`zbm`). `src/decmpfs_fix.py` scans an unpacked
directory, finds zero-byte files that carry decmpfs attributes, and reconstructs them.

> **The trap that costs the most time here**: `zbm_decompress()` returns **0 on success** —
> negative values are error codes. Writing `if (ret > 0)` marks *every block* as a failure,
> and since 0 also looks like "no bytes written", the error path gives no useful signal.
> Full write-up: [docs/03-lzbitmap.md](docs/03-lzbitmap.md).

---

### Problem 3 — long batch runs fall over

**Symptom**

Running a few hundred device/version combinations unattended, something always breaks:
a network hiccup, an `ipsw` process that hangs at 0% CPU, or the disk filling up.

**Fix**

`src/batch_unpack.sh` adds four guards around the single-combination script:

| Guard | How |
| :--- | :--- |
| **Resume** | Checks for **artifacts on disk**, not a completion list |
| **Retry** | Up to 2 attempts per combination, with temp cleanup between |
| **Hang guard** | `timeout` around the extraction step |
| **Disk guard** | Cleans temp dirs when free space drops below a threshold |

The resume rule is deliberate. An earlier version recorded completion in a state file, and
a bug meant the artifact was never moved into place — **the log said "done" while the output
directory was empty**. Deciding on the artifact itself makes that class of bug impossible.
Details: [docs/04-batch-pipeline.md](docs/04-batch-pipeline.md).

---

## Quick start

```bash
git clone https://github.com/Shuang-Sec/ipsw-unpack-toolkit.git
cd ipsw-unpack-toolkit

# 1) Build the LZBitmap decompressor (pure C, no dependencies)
make -C src/lzbitmap
export PATH="$PWD/src/lzbitmap:$PATH"

# 2) Unpack one firmware version (iPhone 14 Pro / iOS 26.6.2 here)
./src/run_ipsw_unpack.sh iPhone15,2 23G90 ./work
```

Result:

```
work/dsc_iPhone15_2__23G90/System/Library/Caches/com.apple.dyld/
├── dyld_shared_cache_arm64e              main cache
├── dyld_shared_cache_arm64e.atlas        index
├── dyld_shared_cache_arm64e.01.dylddata  data segment (string pool, constants)
├── dyld_shared_cache_arm64e.<N>          split sub-caches for large frameworks
└── ⋮
```

Batch mode:

```bash
./src/batch_unpack.sh examples/devices.txt ./work
```

---

## Repository layout

```
├── docs/
│   ├── 01-ipsw-fetch.md        fetching and decrypting an IPSW (AEA1/WKMS)
│   ├── 02-apfs-unpack.md       unpacking APFS without apfs-fuse
│   ├── 03-lzbitmap.md          ★ decmpfs type 14: format and implementation
│   └── 04-batch-pipeline.md    engineering notes for long batch runs
├── src/
│   ├── lzbitmap/               ★ LZBitmap decompressor (pure C, no dependencies)
│   │   ├── libzbitmap.c/.h
│   │   ├── zbm.c
│   │   └── Makefile
│   ├── decmpfs_fix.py          batch repair of zero-byte compressed files
│   ├── fake-apfs-fuse          pseudo-mounter invoked by ipsw
│   ├── run_ipsw_unpack.sh      single combination
│   └── batch_unpack.sh         batch driver with the four guards
├── examples/devices.txt        combination list example
└── tools/PUT_TOOLS_HERE.md     how to obtain the external dependencies
```

---

## Requirements

| Dependency | Version | Purpose |
| :--- | :--- | :--- |
| [`ipsw`](https://github.com/blacktop/ipsw) | v3.1.x tested | firmware streaming, decryption, mounter dispatch |
| [7-Zip](https://www.7-zip.org/) | **21.02+** | APFS unpacking (older builds lack APFS support) |
| `python3` | 3.8+ | `decmpfs_fix.py` (no third-party packages needed) |
| `curl`, `jq` | — | resolving download URLs |
| C compiler | — | building `zbm` |

Setup notes: [`tools/PUT_TOOLS_HERE.md`](tools/PUT_TOOLS_HERE.md).

---

## Environment variables

| Variable | Default | Meaning |
| :--- | :--- | :--- |
| `DSC_DEST` | — | **required**, unpack destination (read by `fake-apfs-fuse`) |
| `IPSW_BIN` | `ipsw` | path to the `ipsw` binary |
| `SEVEN_ZIP` | `7zz` | path to the 7-Zip binary |
| `ZBM_BIN` | `zbm` | path to the LZBitmap decompressor |
| `TIMEOUT_SEC` | `900` | per-extraction timeout |
| `DSC_FULL` | `0` | set to 1 to unpack every sub-cache (for debugging) |
| `KEEP_DMG` | `0` | set to 1 to keep the intermediate image |
| `MIN_FREE_KB` | `7000000` | disk guard threshold in batch mode |

---

## Known issues

- **`ipsw` prints `failed to find dyld_shared_cache(s) in DMG` and keeps a backing image** —
  expected when a substitute mounter is used. The content has been extracted; the message is
  noise.
- **Never point `TMPDIR` at `tmpfs`.** Firmware images are several GB; this fills memory and
  fails with `EDQUOT`. The scripts explicitly place `TMPDIR` on the work disk.
- **Zero-byte `.dylddata` files** mean transparent compression — run `decmpfs_fix.py`. This is
  the direct reason this repository exists.

---

## Scope

This project only uses firmware that Apple publishes publicly, together with open-source
tools. It is intended for firmware format research and interoperability analysis. The file
formats involved (APFS, decmpfs, dyld shared cache) are discussed openly in the Apple
reverse-engineering community.

The LZBitmap implementation is based on [blacktop/lzfse-cgo](https://github.com/blacktop/lzfse-cgo),
repackaged as a standalone C library.

## License

MIT
