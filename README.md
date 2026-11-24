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

1. CI (`.github/workflows/build-images.yml`) builds uncompressed images of the
   golden image dataset: erofs and ext4 on Linux, UFS and ZFS with the makefs of
   a FreeBSD virtual machine. They are published as the parts
   `benchmark-images.tar.gz.01`, `.02`, ... of a release, at most 1 GB each.
2. On FreeBSD `scripts/bench run -p <variant>=<device> ...` downloads the parts of the latest
   release into `./benchmark-images/` (skipped when they are already there),
   unpacks them, and writes each image with `dd` straight into the partition
   you gave for it (`-p <variant>=<device>`). You create the partitions, bench
   only writes into them, and nothing is ever copied into a mounted file
   system. The contents of the partitions are destroyed.
3. It then mounts each variant read-only from its partition, reads the
   files with `tools/rdbench.c`, and writes `raw.csv`, `summary.md` and
   `env.txt` into `results/<time>/`.

The release holds only the uncompressed erofs image, so board 5 (compression)
is skipped until compressed erofs images are on the disk.

## Accuracy measures

- Every round mounts the variant fresh (ZFS: pool import), so the first
  measurement is cold, then the same workload runs again warm.
- Variants alternate inside a round; all rounds are kept in `raw.csv`; the
  summary shows the median and the range.
- The manifest (size and hash of every file) is read from the erofs image.
  Before measuring, every file of every other variant is read and compared with
  it. A variant that returns different data aborts the run.
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

CI, from the Actions tab: run the `build-images` workflow.

FreeBSD target. Create four partitions yourself (the sizes of the images in
the release, or bigger), then pass them; all of their data is lost. The targets
are erofs (uncompressed), ufs, zfs and ext4:

    scripts/bench run -e kernel \
        -p erofs=/dev/ada1p4 -p ufs=/dev/ada1p5 \
        -p zfs=/dev/ada1p6 -p ext4=/dev/ada1p7

The partitions already hold the images (no download, no dd), benchmark only ufs
and zfs, boards 1 and 4:

    scripts/bench run -e kernel --mount ufs --mount zfs \
        -p erofs=/dev/ada1p4 -p ufs=/dev/ada1p5 -p zfs=/dev/ada1p6 1 4

The kernel with erofs comes from the latest release of
`imrcpan/erofs-freebsd-releases` (`erofs_freebsd_kernel_amd64_*.tar.gz`, the
non-debug kernel); `scripts/dangerous-install-kernel.sh -f <tar.gz>` installs it.
