# erofs-freebsd read benchmark

Read benchmark for erofs on FreeBSD against the other on-disk file systems
(UFS, ZFS, ext2fs/ext4). Everything is driven by `scripts/bench`.

## Boards

| # | board | variants |
|---|-------|----------|
| 1 | large file sequential read (files >= 16 MiB) | erofs, ufs, zfs, ext4, all uncompressed |
| 2 | small files (< 64 KiB), sorted order | same |
| 3 | small files, seeded random order | same |
| 4 | golden image: walk and read the whole tree | same |
| 5 | erofs against itself: none, lz4, lz4hc, lzma, deflate, zstd | erofs only |

The golden image dataset is the one of `erofsstress-freebsd/genimage`: the
files of the Android 11 GSI `system.img`, enwik8, silesia and calgary.
Cross file system boards use only uncompressed images.

## How it works

1. On a Linux host `scripts/bench build-image` downloads the dataset, bootstraps
   `makefs` from a FreeBSD source tree, and builds one image per variant
   (`mkfs.erofs`, `makefs -t ffs`, `makefs -t zfs`, `mkfs.ext4`). The images
   are written into GPT partitions of a single raw disk image, `bench.img`.
   The label of each partition is the variant name. A `meta` partition holds
   the layout and a manifest with size and hash of every file.
2. The disk image is written to the disk of the FreeBSD machine. Nothing is
   ever copied into the partitions on the FreeBSD side.
3. On FreeBSD `scripts/bench run` mounts each variant read-only from
   `/dev/gpt/<label>`, reads the files with `tools/rdbench.c`, and writes
   `raw.csv`, `summary.md` and `env.txt` into `results/<time>/`.

## Accuracy measures

- Every round mounts the variant fresh (ZFS: pool import), so the first
  measurement is cold, then the same workload runs again warm.
- Variants alternate inside a round; all rounds are kept in `raw.csv`; the
  summary shows the median and the range.
- Before measuring, every file of every variant is read and compared with the
  hash in the manifest. A variant that returns wrong data aborts the run.
- Only the open/read/close loop is timed. The file order of boards 2 and 3 comes
  from the manifest and a fixed seed, so it is identical on all file systems.
- When the disk is a virtual disk, attach it with host caching off (for QEMU,
  `cache=none`), or the numbers include the host page cache.

## erofs modes

`bench run -e module -s <erofs-freebsd tree>` builds `erofs.ko` from the tree
against the running system and loads it. The `__FreeBSD_version` of the tree
and of the running system must match. `-k <erofs.ko>` uses a prebuilt module.
`bench run -e kernel` expects erofs in the running kernel.

## Usage

Linux host:

    scripts/bench build-image -w ./bench-work          # full dataset
    scripts/bench build-image -p small -w ./bench-work # silesia and calgary only

FreeBSD target, with `bench.img` attached as a disk:

    scripts/bench run -s /path/to/erofs-freebsd        # all boards
    scripts/bench run -e kernel 1 4                    # boards 1 and 4
