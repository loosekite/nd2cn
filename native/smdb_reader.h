/*
 * smdb_reader.h - read-only, lock-free reader for the Mazda CMU "SMDB"
 * shared memory databases (libjcismdb.so, firmware 74.00.324A).
 *
 * Self-contained C99: open/fstat/mmap/close + string.h. No vendor library,
 * no malloc, no semaphore, nothing is ever created, truncated or written.
 * Layout reference: smdb-layout.md next to this file.
 *
 * Region layout (all fields little-endian uint32, offsets from region start):
 *
 *   0x00 total_size   == size of the shm object
 *   0x04 entry_count  n
 *   0x08 data_size
 *   0x0C path_off     0, or 16*(n+1) when the DB has a flash image path
 *   0x10 entry[0..n-1], 16 bytes each: name_off, size, type, data_off
 *   16*(n+1)          optional image path string, then the entry names
 *   total-data_size   data area
 *
 * Every access is bounds-checked against the mapped size, so a wrong layout
 * assumption gives an error code instead of a crash. The one thing that can
 * not be caught is another process shrinking the object while it is mapped
 * (SIGBUS); the vendor library never does that to a live database.
 *
 * Usage:
 *   struct smdb_ro db;
 *   if (smdb_ro_open("vdm_vdt_current_data", &db) == SMDB_RO_OK) {
 *       int i = smdb_ro_find(&db, "EngineSpeed");
 *       long v;
 *       if (i >= 0 && smdb_ro_read_int(&db, i, &v) == SMDB_RO_OK) { ... }
 *       smdb_ro_close(&db);
 *   }
 */
#ifndef SMDB_READER_H
#define SMDB_READER_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif
#ifndef O_NONBLOCK
#define O_NONBLOCK 0
#endif

/* Directory glibc's shm_open() uses, with trailing slash. */
#ifndef SMDB_RO_SHM_DIR
#define SMDB_RO_SHM_DIR "/dev/shm/"
#endif
/* Sanity caps; the largest real schema is far below both. */
#ifndef SMDB_RO_MAX_SIZE
#define SMDB_RO_MAX_SIZE (16u * 1024u * 1024u)
#endif
#ifndef SMDB_RO_MAX_ENTRIES
#define SMDB_RO_MAX_ENTRIES 65536u
#endif

/* Type codes stored in the entry table. */
#define SMDB_RO_TYPE_INT    1
#define SMDB_RO_TYPE_STRING 2
#define SMDB_RO_TYPE_BINARY 3

/* Return codes. 0 is success, everything else is negative. */
#define SMDB_RO_OK       0
#define SMDB_RO_EARG    (-1)  /* bad argument or handle not open            */
#define SMDB_RO_EOPEN   (-2)  /* open() failed, errno is left set           */
#define SMDB_RO_ESTAT   (-3)  /* fstat() failed or not a regular file       */
#define SMDB_RO_ESIZE   (-4)  /* empty, too small or too large; an empty
                                 object means "not initialised yet": retry  */
#define SMDB_RO_EMAP    (-5)  /* mmap() failed, errno is left set           */
#define SMDB_RO_EHDR    (-6)  /* header fields are inconsistent             */
#define SMDB_RO_EENTRY  (-7)  /* an entry is inconsistent (h->bad_index)    */
#define SMDB_RO_ERANGE  (-8)  /* index out of range                         */
#define SMDB_RO_ENOENT  (-9)  /* name not found                             */
#define SMDB_RO_ETYPE   (-10) /* entry has a different type                 */
#define SMDB_RO_EBUF    (-11) /* caller buffer too small                    */

struct smdb_ro {
    const unsigned char *base; /* NULL when not open                     */
    size_t   map_len;          /* mapped length == object size           */
    uint32_t total;            /* header: total size                     */
    uint32_t count;            /* header: number of entries              */
    uint32_t data_size;        /* header: size of the data area          */
    uint32_t path_off;         /* header: image path offset or 0         */
    uint32_t table_end;        /* 16 * (count + 1)                       */
    uint32_t data_start;       /* total - data_size                      */
    int      bad_index;        /* entry that failed validation, else -1  */
};

/* Decoded and validated entry (internal). */
struct smdb_ro__ent {
    uint32_t name_off, size, type, data_off;
};

static inline uint32_t smdb_ro__u32(const unsigned char *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/*
 * Load and validate entry `index`. Each field is read once into a local and
 * only the validated locals are used afterwards.
 */
static inline int smdb_ro__entry(const struct smdb_ro *h, int index,
                          struct smdb_ro__ent *e)
{
    const unsigned char *p;

    if (h == NULL || h->base == NULL || e == NULL)
        return SMDB_RO_EARG;
    if (index < 0 || (uint32_t)index >= h->count)
        return SMDB_RO_ERANGE;

    /* index < count and 16*(count+1) <= total, so this stays in the map. */
    p = h->base + 16u + 16u * (size_t)index;
    e->name_off = smdb_ro__u32(p);
    e->size     = smdb_ro__u32(p + 4);
    e->type     = smdb_ro__u32(p + 8);
    e->data_off = smdb_ro__u32(p + 12);

    /* Name: inside [table_end, data_start) and NUL-terminated in there. */
    if (e->name_off < h->table_end || e->name_off >= h->data_start)
        return SMDB_RO_EENTRY;
    if (memchr(h->base + e->name_off, 0,
               (size_t)(h->data_start - e->name_off)) == NULL)
        return SMDB_RO_EENTRY;

    if (e->type < SMDB_RO_TYPE_INT || e->type > SMDB_RO_TYPE_BINARY)
        return SMDB_RO_EENTRY;

    /* Data: inside [data_start, total). */
    if (e->size == 0)
        return SMDB_RO_EENTRY;
    if (e->data_off < h->data_start || e->data_off > h->total)
        return SMDB_RO_EENTRY;
    if (e->size > h->total - e->data_off)
        return SMDB_RO_EENTRY;

    /* The library stores ints as one aligned 32-bit word. */
    if (e->type == SMDB_RO_TYPE_INT &&
        (e->size != 4 || (e->data_off & 3u) != 0))
        return SMDB_RO_EENTRY;

    return SMDB_RO_OK;
}

static inline void smdb_ro__reset(struct smdb_ro *h)
{
    memset(h, 0, sizeof(*h));
    h->bad_index = -1;
}

static inline void smdb_ro_close(struct smdb_ro *h)
{
    if (h == NULL)
        return;
    if (h->base != NULL)
        munmap((void *)(uintptr_t)h->base, h->map_len);
    smdb_ro__reset(h);
}

static inline int smdb_ro__open_fd(int fd, struct smdb_ro *h)
{
    struct stat st;
    void *m;
    uint32_t i;

    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode))
        return SMDB_RO_ESTAT;
    if (st.st_size < 16 || (uint64_t)st.st_size > (uint64_t)SMDB_RO_MAX_SIZE)
        return SMDB_RO_ESIZE;

    m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED)
        return SMDB_RO_EMAP;

    h->base      = (const unsigned char *)m;
    h->map_len   = (size_t)st.st_size;
    h->total     = smdb_ro__u32(h->base);
    h->count     = smdb_ro__u32(h->base + 4);
    h->data_size = smdb_ro__u32(h->base + 8);
    h->path_off  = smdb_ro__u32(h->base + 12);

    /* There is no magic number: these consistency rules stand in for one. */
    if ((uint64_t)h->total != (uint64_t)h->map_len)
        goto bad_hdr;
    /* count == 0 is what a reader sees while the owner is still creating
     * the database (total_size is stored before entry_count): not usable. */
    if (h->count == 0 || h->count > SMDB_RO_MAX_ENTRIES ||
        h->count > (h->total - 16u) / 16u)
        goto bad_hdr;
    h->table_end = 16u * (h->count + 1u);
    if (h->data_size > h->total - h->table_end)
        goto bad_hdr;
    h->data_start = h->total - h->data_size;
    if ((h->data_start & 3u) != 0)
        goto bad_hdr;
    if (h->path_off != 0) {
        if (h->path_off != h->table_end || h->path_off >= h->data_start)
            goto bad_hdr;
        if (memchr(h->base + h->path_off, 0,
                   (size_t)(h->data_start - h->path_off)) == NULL)
            goto bad_hdr;
    }

    /* Validate the whole (immutable) entry table once. */
    for (i = 0; i < h->count; i++) {
        struct smdb_ro__ent e;
        if (smdb_ro__entry(h, (int)i, &e) != SMDB_RO_OK) {
            smdb_ro_close(h);
            h->bad_index = (int)i;
            return SMDB_RO_EENTRY;
        }
    }
    return SMDB_RO_OK;

bad_hdr:
    smdb_ro_close(h);
    return SMDB_RO_EHDR;
}

/*
 * Open an image by file path (test images, or a /data/smdb_<name>.dat flash
 * dump, which has the same layout). Read-only; never creates anything.
 */
static inline int smdb_ro_open_path(const char *path, struct smdb_ro *h)
{
    int fd, rc;

    if (h == NULL)
        return SMDB_RO_EARG;
    smdb_ro__reset(h);
    if (path == NULL || path[0] == '\0')
        return SMDB_RO_EARG;

    fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0)
        return SMDB_RO_EOPEN;
    rc = smdb_ro__open_fd(fd, h);
    close(fd); /* the mapping stays valid without the descriptor */
    return rc;
}

/*
 * Open database `db_name` (e.g. "vdm_vdt_current_data"), i.e. the object
 * /dev/shm/smdb_<db_name>, O_RDONLY + PROT_READ. No O_CREAT, no ftruncate,
 * no semaphore. If the owner has not created or filled it yet this returns
 * SMDB_RO_EOPEN / SMDB_RO_ESIZE / SMDB_RO_EENTRY: just retry later.
 */
static inline int smdb_ro_open(const char *db_name, struct smdb_ro *h)
{
    char path[256];
    static const char prefix[] = SMDB_RO_SHM_DIR "smdb_";
    size_t plen = sizeof(prefix) - 1, nlen, i;
    int fd, rc;

    if (h == NULL)
        return SMDB_RO_EARG;
    smdb_ro__reset(h);
    if (db_name == NULL)
        return SMDB_RO_EARG;
    nlen = strlen(db_name);
    if (nlen == 0 || nlen > sizeof(path) - plen - 1)
        return SMDB_RO_EARG;
    for (i = 0; i < nlen; i++)
        if (db_name[i] == '/')
            return SMDB_RO_EARG;
    memcpy(path, prefix, plen);
    memcpy(path + plen, db_name, nlen + 1);

    fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW);
    if (fd < 0)
        return SMDB_RO_EOPEN;
    rc = smdb_ro__open_fd(fd, h);
    close(fd);
    return rc;
}

/* Number of entries (>= 0), or a negative error. */
static inline int smdb_ro_count(const struct smdb_ro *h)
{
    if (h == NULL || h->base == NULL)
        return SMDB_RO_EARG;
    return (int)h->count;
}

/*
 * Describe entry `index`. Any out pointer may be NULL. *name points into the
 * mapping (valid until smdb_ro_close). *size is the stored size: 4 for int,
 * the XML size for binary, the XML size + 1 (room for the NUL) for string.
 */
static inline int smdb_ro_entry(const struct smdb_ro *h, int index,
                         const char **name, int *type, unsigned *size)
{
    struct smdb_ro__ent e;
    int rc = smdb_ro__entry(h, index, &e);

    if (rc != SMDB_RO_OK)
        return rc;
    if (name != NULL)
        *name = (const char *)(h->base + e.name_off);
    if (type != NULL)
        *type = (int)e.type;
    if (size != NULL)
        *size = (unsigned)e.size;
    return SMDB_RO_OK;
}

static inline int smdb_ro__ieq(const char *a, const char *b)
{
    for (;; a++, b++) {
        unsigned char x = (unsigned char)*a, y = (unsigned char)*b;
        if (x >= 'A' && x <= 'Z')
            x = (unsigned char)(x - 'A' + 'a');
        if (y >= 'A' && y <= 'Z')
            y = (unsigned char)(y - 'A' + 'a');
        if (x != y)
            return 0;
        if (x == 0)
            return 1;
    }
}

/*
 * Index of the entry called `name` (>= 0), or a negative error. Matches the
 * library: linear scan, ASCII case-insensitive, last match wins.
 */
static inline int smdb_ro_find(const struct smdb_ro *h, const char *name)
{
    int found = SMDB_RO_ENOENT;
    uint32_t i;

    if (h == NULL || h->base == NULL || name == NULL)
        return SMDB_RO_EARG;
    for (i = 0; i < h->count; i++) {
        struct smdb_ro__ent e;
        int rc = smdb_ro__entry(h, (int)i, &e);
        if (rc != SMDB_RO_OK)
            return rc;
        if (smdb_ro__ieq(name, (const char *)(h->base + e.name_off)))
            found = (int)i;
    }
    return found;
}

/*
 * Read an "int" entry: one aligned 32-bit load, value is a signed 32-bit
 * integer. No lock is taken; the writer updates the word with a single
 * aligned 32-bit store, so the value is either the old or the new one.
 */
static inline int smdb_ro_read_int(const struct smdb_ro *h, int index, long *out)
{
    struct smdb_ro__ent e;
    const volatile uint32_t *p;
    unsigned char b[4];
    uint32_t raw, v;
    int rc = smdb_ro__entry(h, index, &e);

    if (rc != SMDB_RO_OK)
        return rc;
    if (out == NULL)
        return SMDB_RO_EARG;
    if (e.type != SMDB_RO_TYPE_INT)
        return SMDB_RO_ETYPE;

    /* base is page-aligned and data_off % 4 == 0 was checked. */
    p = (const volatile uint32_t *)(const void *)(h->base + e.data_off);
    raw = *p;
    memcpy(b, &raw, 4);
    v = smdb_ro__u32(b);
    *out = (v & 0x80000000u) ? -(long)(0xFFFFFFFFu - v) - 1 : (long)v;
    return SMDB_RO_OK;
}

/*
 * Copy the raw bytes of any entry (int, string or binary) into buf. *len
 * (optional) receives the stored size. Not atomic against a concurrent
 * writer: a multi-byte value may be seen half-updated.
 */
static inline int smdb_ro_read_bytes(const struct smdb_ro *h, int index,
                              void *buf, size_t buf_size, unsigned *len)
{
    struct smdb_ro__ent e;
    int rc = smdb_ro__entry(h, index, &e);

    if (rc != SMDB_RO_OK)
        return rc;
    if (len != NULL)
        *len = (unsigned)e.size;
    if (buf == NULL || buf_size < e.size)
        return SMDB_RO_EBUF;
    memcpy(buf, h->base + e.data_off, e.size);
    return SMDB_RO_OK;
}

static inline const char *smdb_ro_strerror(int rc)
{
    switch (rc) {
    case SMDB_RO_OK:     return "ok";
    case SMDB_RO_EARG:   return "bad argument";
    case SMDB_RO_EOPEN:  return "open failed";
    case SMDB_RO_ESTAT:  return "fstat failed or not a regular file";
    case SMDB_RO_ESIZE:  return "object empty, too small or too large";
    case SMDB_RO_EMAP:   return "mmap failed";
    case SMDB_RO_EHDR:   return "inconsistent header";
    case SMDB_RO_EENTRY: return "inconsistent entry";
    case SMDB_RO_ERANGE: return "index out of range";
    case SMDB_RO_ENOENT: return "entry not found";
    case SMDB_RO_ETYPE:  return "type mismatch";
    case SMDB_RO_EBUF:   return "buffer too small";
    default:             return "unknown error";
    }
}

#endif /* SMDB_READER_H */
