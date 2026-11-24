/*
 * rdbench - read benchmark helper. Portable C, builds on FreeBSD and Linux.
 *
 * Modes:
 *   rdbench -G root
 *       Print a manifest of every regular file below root, one line per file:
 *       "<size>\t<hash>\t<relative path>".
 *   rdbench -r root -m manifest [-l min] [-u max] [-o seq|shuffle] [-R seed]
 *           [-b bytes] [-v] [-n]
 *       Read the manifest files (size in [min, max)) under root, in manifest
 *       order or in a seeded shuffled order, and print the timing.
 *   rdbench -r root -w [-m manifest] [-b bytes]
 *       Walk root in directory order and read every regular file.
 *
 * Only the open/read/close loop is timed. Hashing (-v) is for verification
 * runs and its time must not be used as a result.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <sys/types.h>
#include <sys/stat.h>

#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define FNV_INIT	0xcbf29ce484222325ULL
#define FNV_PRIME	0x100000001b3ULL

struct ent {
	char		*rel;
	char		*full;
	uint64_t	 size;
	uint64_t	 hash;
};

static double
now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((double)ts.tv_sec + (double)ts.tv_nsec * 1e-9);
}

static void
usage(void)
{
	fprintf(stderr,
	    "usage: rdbench -G root\n"
	    "       rdbench -r root -m manifest [-l min] [-u max] "
	    "[-o seq|shuffle] [-R seed] [-b bytes] [-v] [-n]\n"
	    "       rdbench -r root -w [-m manifest] [-b bytes]\n");
	exit(2);
}

static uint64_t
fnv_update(uint64_t h, const unsigned char *p, size_t n)
{
	while (n--) {
		h ^= *p++;
		h *= FNV_PRIME;
	}
	return (h);
}

/* Read a whole file. Returns 0 on success, -1 on error. */
static int
read_one(const char *path, unsigned char *buf, size_t bs, int dohash,
    uint64_t *size, uint64_t *hash)
{
	uint64_t h = FNV_INIT, total = 0;
	ssize_t n;
	int fd, bad;

	fd = open(path, O_RDONLY);
	if (fd < 0)
		return (-1);
	while ((n = read(fd, buf, bs)) > 0) {
		total += (uint64_t)n;
		if (dohash)
			h = fnv_update(h, buf, (size_t)n);
	}
	bad = (n < 0);
	close(fd);
	if (bad)
		return (-1);
	*size = total;
	*hash = h;
	return (0);
}

#ifdef __FreeBSD__
#define FTS_CMP_ARG const FTSENT * const *
#else
#define FTS_CMP_ARG const FTSENT **
#endif

static int
cmp_fts(FTS_CMP_ARG a, FTS_CMP_ARG b)
{
	return (strcmp((*a)->fts_name, (*b)->fts_name));
}

static void
strip_slashes(char *s)
{
	size_t n = strlen(s);

	while (n > 1 && s[n - 1] == '/')
		s[--n] = '\0';
}

static int
gen_manifest(char *root)
{
	char *argv[2];
	unsigned char *buf;
	const size_t bs = 1 << 20;
	FTS *fts;
	FTSENT *e;
	uint64_t size, hash;
	size_t rl;
	int rc = 0;

	strip_slashes(root);
	rl = strlen(root);
	argv[0] = root;
	argv[1] = NULL;
	buf = malloc(bs);
	fts = fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR, cmp_fts);
	if (buf == NULL || fts == NULL) {
		perror("rdbench");
		return (1);
	}
	while ((e = fts_read(fts)) != NULL) {
		const char *rel;

		if (e->fts_info == FTS_DNR || e->fts_info == FTS_ERR ||
		    e->fts_info == FTS_NS) {
			fprintf(stderr, "rdbench: %s: %s\n", e->fts_path,
			    strerror(e->fts_errno));
			rc = 1;
			continue;
		}
		if (e->fts_info != FTS_F)
			continue;
		rel = e->fts_path + rl;
		while (*rel == '/')
			rel++;
		if (strchr(rel, '\t') != NULL || strchr(rel, '\n') != NULL) {
			fprintf(stderr, "rdbench: bad path: %s\n", e->fts_path);
			rc = 1;
			continue;
		}
		if (read_one(e->fts_path, buf, bs, 1, &size, &hash) != 0) {
			fprintf(stderr, "rdbench: read %s: %s\n", e->fts_path,
			    strerror(errno));
			rc = 1;
			continue;
		}
		printf("%" PRIu64 "\t%016" PRIx64 "\t%s\n", size, hash, rel);
	}
	fts_close(fts);
	free(buf);
	return (rc);
}

static struct ent *
load_manifest(const char *path, const char *root, size_t *count)
{
	FILE *fp;
	char *line = NULL;
	size_t cap = 0, n = 0, alloc = 0;
	ssize_t len;
	struct ent *v = NULL;

	fp = fopen(path, "r");
	if (fp == NULL) {
		perror(path);
		exit(1);
	}
	while ((len = getline(&line, &cap, fp)) > 0) {
		char *p, *q;
		struct ent *e;

		if (line[len - 1] == '\n')
			line[--len] = '\0';
		if (len == 0)
			continue;
		if (n == alloc) {
			alloc = alloc ? alloc * 2 : 4096;
			v = realloc(v, alloc * sizeof(*v));
			if (v == NULL) {
				perror("realloc");
				exit(1);
			}
		}
		e = &v[n];
		e->size = strtoull(line, &p, 10);
		if (*p != '\t')
			goto bad;
		e->hash = strtoull(p + 1, &q, 16);
		if (*q != '\t')
			goto bad;
		e->rel = strdup(q + 1);
		if (asprintf(&e->full, "%s/%s", root, e->rel) < 0 ||
		    e->rel == NULL) {
			perror("alloc");
			exit(1);
		}
		n++;
		continue;
bad:
		fprintf(stderr, "rdbench: bad manifest line: %s\n", line);
		exit(1);
	}
	free(line);
	fclose(fp);
	*count = n;
	return (v);
}

/* splitmix64, so the order does not depend on the libc of the host. */
static uint64_t
rng_next(uint64_t *s)
{
	uint64_t z = (*s += 0x9e3779b97f4a7c15ULL);

	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return (z ^ (z >> 31));
}

static void
shuffle(struct ent *v, size_t n, uint64_t seed)
{
	size_t i, j;
	struct ent t;

	if (n < 2)
		return;
	for (i = n - 1; i > 0; i--) {
		j = (size_t)(rng_next(&seed) % (i + 1));
		t = v[i];
		v[i] = v[j];
		v[j] = t;
	}
}

static void
report(uint64_t files, uint64_t bytes, double secs, unsigned errors,
    uint64_t hash)
{
	printf("files=%" PRIu64 " bytes=%" PRIu64 " secs=%.6f mibs=%.3f "
	    "errors=%u hash=%016" PRIx64 "\n", files, bytes, secs,
	    secs > 0 ? (double)bytes / secs / 1048576.0 : 0.0, errors, hash);
}

int
main(int argc, char **argv)
{
	const char *root = NULL, *mpath = NULL, *order = "seq";
	uint64_t minsz = 0, maxsz = UINT64_MAX, seed = 1;
	size_t bs = 131072, nall = 0, n = 0, i;
	int ch, walk = 0, verify = 0, dry = 0, gen = 0;
	struct ent *all = NULL, *sel;
	unsigned char *buf;
	uint64_t files = 0, bytes = 0, sum = 0, size, hash;
	unsigned errors = 0;
	double t0, t1;

	while ((ch = getopt(argc, argv, "G:r:m:l:u:o:R:b:wvn")) != -1) {
		switch (ch) {
		case 'G': gen = 1; root = optarg; break;
		case 'r': root = optarg; break;
		case 'm': mpath = optarg; break;
		case 'l': minsz = strtoull(optarg, NULL, 10); break;
		case 'u': maxsz = strtoull(optarg, NULL, 10); break;
		case 'o': order = optarg; break;
		case 'R': seed = strtoull(optarg, NULL, 10); break;
		case 'b': bs = (size_t)strtoull(optarg, NULL, 10); break;
		case 'w': walk = 1; break;
		case 'v': verify = 1; break;
		case 'n': dry = 1; break;
		default: usage();
		}
	}
	if (root == NULL || bs == 0)
		usage();
	if (gen)
		return (gen_manifest((char *)root));
	if (strcmp(order, "seq") != 0 && strcmp(order, "shuffle") != 0)
		usage();
	if (!walk && mpath == NULL)
		usage();

	buf = malloc(bs);
	if (buf == NULL) {
		perror("malloc");
		return (1);
	}
	if (mpath != NULL)
		all = load_manifest(mpath, root, &nall);

	if (walk) {
		char *av[2] = { (char *)root, NULL };
		FTS *fts;
		FTSENT *e;
		uint64_t mfiles = 0, mbytes = 0;

		for (i = 0; i < nall; i++) {
			mfiles++;
			mbytes += all[i].size;
		}
		fts = fts_open(av, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
		if (fts == NULL) {
			perror("fts_open");
			return (1);
		}
		t0 = now();
		while ((e = fts_read(fts)) != NULL) {
			if (e->fts_info == FTS_DNR || e->fts_info == FTS_ERR ||
			    e->fts_info == FTS_NS) {
				errors++;
				continue;
			}
			if (e->fts_info != FTS_F)
				continue;
			if (read_one(e->fts_path, buf, bs, 0, &size,
			    &hash) != 0) {
				errors++;
				continue;
			}
			files++;
			bytes += size;
		}
		t1 = now();
		fts_close(fts);
		if (mpath != NULL && (files != mfiles || bytes != mbytes)) {
			fprintf(stderr, "rdbench: walk saw %" PRIu64 " files "
			    "%" PRIu64 " bytes, manifest has %" PRIu64 " and "
			    "%" PRIu64 "\n", files, bytes, mfiles, mbytes);
			errors++;
		}
		report(files, bytes, t1 - t0, errors, 0);
		return (errors != 0);
	}

	sel = malloc((nall ? nall : 1) * sizeof(*sel));
	if (sel == NULL) {
		perror("malloc");
		return (1);
	}
	for (i = 0; i < nall; i++)
		if (all[i].size >= minsz && all[i].size < maxsz)
			sel[n++] = all[i];
	if (strcmp(order, "shuffle") == 0)
		shuffle(sel, n, seed);
	if (dry) {
		for (i = 0; i < n; i++) {
			files++;
			bytes += sel[i].size;
		}
		report(files, bytes, 0, 0, 0);
		return (0);
	}

	t0 = now();
	for (i = 0; i < n; i++) {
		if (read_one(sel[i].full, buf, bs, verify, &size, &hash) != 0) {
			if (errors++ < 20)
				fprintf(stderr, "rdbench: read %s: %s\n",
				    sel[i].full, strerror(errno));
			continue;
		}
		if (size != sel[i].size ||
		    (verify && hash != sel[i].hash)) {
			if (errors++ < 20)
				fprintf(stderr, "rdbench: mismatch: %s\n",
				    sel[i].full);
			continue;
		}
		files++;
		bytes += size;
		sum += hash;
	}
	t1 = now();
	report(files, bytes, t1 - t0, errors, verify ? sum : 0);
	return (errors != 0);
}
