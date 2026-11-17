# SMDB shared memory layout (libjcismdb.so, CMU firmware 74.00.324A)

Source: static disassembly of `jci/lib/libjcismdb.so`, `jci/lib/libjcixmlreader.so`
and `jci/smdb/smdb-read`. Addresses are in `libjcismdb.so` unless prefixed
(`xmlreader:` or `smdb-read:`).

- **PROVEN** = read directly from the instructions cited.
- **INFERRED** = follows from glibc / kernel / ARM behaviour, not from this code.
- Nothing here has been checked on the car, and the vendor code could not be
  run here (no ARM glibc in the dump). Section 8 lists cheap on-car checks.

## 1. Object names, open flags

| Point | Status | Evidence |
|---|---|---|
| shm name is `"/smdb_" + dbname`, e.g. `/smdb_vdm_vdt_current_data` | PROVEN | `SMDB_SHMEM_Open` 0x1e30-0x1e44: `snprintf(buf, 0x1000, "/%s%s", "smdb_", handle->name)`; strings at 0x4b58, 0x4b60 |
| File is `/dev/shm/smdb_vdm_vdt_current_data` | INFERRED | glibc `shm_open` maps `/x` to `<shm tmpfs>/x`, default `/dev/shm` |
| Library opens with `O_RDWR\|O_CREAT`, mode 0777, for every caller, readers included | PROVEN | 0x1e54-0x1e64: `shm_open(buf, 0x42, 0x1ff)`. The access argument of `SMDB_Open` is not consulted here |
| Existing object (`st_size != 0`): `mmap(NULL, st_size, PROT_READ\|PROT_WRITE, MAP_SHARED, fd, 0)`, no header validation at all | PROVEN | `__fxstat` 0x1e78-0x1e84, `st_size` test 0x1e98-0x1ea0, mmap 0x21c4-0x21dc, return 0 at 0x21ec |
| Empty object (`st_size == 0`): the caller creates the database from `/jci/smdb/<dbname>.xml` | PROVEN | 0x1ea4 onward: `SMDB_XML_Open`, `ftruncate` 0x1f28-0x1f30, mmap 0x1f3c-0x1f5c; XML path `"%s/%s.%s"` in `SMDB_XML_Open` 0x4028-0x4040 |
| A separate reader can use `open(O_RDONLY)` + `mmap(PROT_READ, MAP_SHARED)` and create nothing | INFERRED | It is an ordinary tmpfs file created with mode 0777 & ~umask; a read-only shared mapping of an `O_RDONLY` fd is allowed by Linux |
| One named semaphore per database, name `"/smdb_" + dbname`, created with `O_CREAT`, mode 0777, initial value 1 | PROVEN | `SMDB_LockInit` 0x3cec-0x3d28: same `snprintf`, then `sem_open(name, 0x40, 0x1ff, 1)` |
| Semaphore file is `/dev/shm/sem.smdb_<dbname>` | INFERRED | glibc naming convention for named semaphores |
| The `SMDB_Mutex*` helpers (pthread mutex) are not used by the library itself | PROVEN | no `bl SMDB_Mutex*` anywhere in the disassembly |
| The library never `munmap`s; `SMDB_Close` only closes the fd | PROVEN | `SMDB_SHMEM_Close` 0x285c-0x2860; no `munmap` import |

Internal handle (20 bytes, `SMDB_Open` 0x2d94): `+0 sem_t*`, `+4 fd`,
`+8 map base`, `+0xC access (bit0 read, bit1 write)`, `+0x10 strdup(name)`.

## 2. Region layout

All fields are native-endian (little-endian) `uint32`. Offsets are from the
start of the region. There is no magic number and no version field.

```
0x00  total_size    size of the whole region == ftruncate length == st_size
0x04  entry_count   n
0x08  data_size     size of the data area (sum of the padded slots)
0x0C  path_off      16*(n+1) if the XML root has a path attribute, else 0
0x10  entry[0]      16 bytes each, i = 0 .. n-1, at 0x10 + 16*i
        +0  name_off   offset of the NUL-terminated entry name
        +4  size       int: 4 | binary: XML size | string: XML size + 1
        +8  type       1 = int, 2 = string, 3 = binary
        +12 data_off   offset of the value
16*(n+1)            image path "<path>/smdb_<dbname>.dat\0"; reserved length
                    pad4(strlen(path) + strlen(dbname) + 11); absent (0 bytes)
                    when the XML root has no path attribute
...                 names: NUL-terminated, packed in entry order; the whole
                    block is padded to a multiple of 4
total - data_size   data: one slot per entry in entry order
                      int     4 bytes, signed 32-bit
                      binary  size bytes, slot padded to a multiple of 4
                      string  size bytes including the NUL, slot padded to 4
total_size          end
```

`total_size = 16*(n+1) + path_block + names_block + data_size`, every term a
multiple of 4, so every `data_off` is 4-byte aligned.

| Point | Status | Evidence |
|---|---|---|
| Header words | PROVEN | 0x1f7c `str r5,[lr]` (total), 0x1f88 `str r9,[lr,#4]` (count), 0x1f80 `str sl,[lr,#8]` (data size), 0x1f8c `str fp,[lr,#12]` with `fp = (n+1)<<4` (0x1f10-0x1f18) |
| `total` formula, and it is also the `ftruncate` length | PROVEN | 0x1f14-0x1f20, `ftruncate(fd, r5)` 0x1f28-0x1f30 |
| `path_off` is set to 0 when there is no path attribute | PROVEN | 0x22c0-0x22c8, 0x24d0-0x24d4 |
| Entry `i` lives at `16*(i+1)`; `name_off` at +0 | PROVEN | 0x2098 `add r6,r6,#1`, 0x209c `str r7,[r4,r6,lsl #4]`, name copied by `strcpy` 0x20b0-0x20b4 |
| `size` at +4, `type` at +8, `data_off` at +12 | PROVEN | 0x20c0-0x20c8, 0x1fe4, 0x23c0 (int) and 0x23f8 (binary, string) |
| Names start right after the path block and are packed | PROVEN | start 0x1fcc `r7 = pathpad + hdr[0xC]`; step 0x2034-0x2040 `r7 += strlen(name) + 1` |
| Data starts at `16*(n+1) + pathpad + names` = `total - data_size` | PROVEN | 0x1fb8-0x1fc4; flash loader uses `total - data_size` at 0x2570-0x257c and 0x2784-0x2790 |
| Slot sizes: int 4, others rounded up to 4 | PROVEN | 0x23b8-0x23c8 (int), 0x23e4-0x23fc (binary, string); same sums in `SMDB_XML_Open` 0x4098-0x40ac, 0x417c-0x41cc |
| String size is XML size + 1 | PROVEN | `SMDB_XML_Open` 0x419c-0x41ac, `SMDB_XML_GetNewEntry` 0x486c-0x4878 |
| Names block padded to 4 | PROVEN | `SMDB_XML_Open` 0x41d4-0x41e4 |
| Path block length and content | PROVEN | length 0x1ec8-0x1ee8; content 0x22cc-0x2344 (path, `/` if missing, `smdb_`, name, `.dat`) |
| Defaults: int `strtol(value, NULL, 0)`; binary zero-filled (value ignored); string `strncpy` then forced NUL | PROVEN | 0x23a0-0x23b4, 0x23d0-0x23e0, 0x2404-0x2448 |
| The readers in the library use the same offsets | PROVEN | `SMDB_SHMEM_GetEntryByIndex` 0x2cc4-0x2cfc, `SMDB_SHMEM_GetEntryByName` 0x2a20-0x2a40, `SMDB_SHMEM_GetEntryCnt` 0x2d28-0x2d30 |
| `/data/smdb_<dbname>.dat` is a byte-for-byte dump of the region | PROVEN | `SMDB_SHMEM_CommitToFlash` 0x2a80-0x2af8 (path at `base + hdr[0xC]`), 0x2b48-0x2b58 `FILE_Write(base, 1, hdr[0], f)` |
| At creation, a `.dat` whose metadata (first `total - data_size` bytes) equals the fresh one has its data area copied in | PROVEN | 0x2570-0x27a4 (`memcmp` 0x25cc-0x25e0, `memcpy` 0x2784-0x2790) |

Predicted object sizes (generator `mkimage.py --sizes`, same arithmetic):

| database | n | total bytes | data bytes | path_off |
|---|---:|---:|---:|---:|
| vdm_vdt_current_data | 279 | 18148 | 8516 | 0 |
| vdm_vdt_pid_data | 82 | 3436 | 604 | 0 |
| vdm | 39 | 1832 | 504 | 0 |
| vdm_idm | 55 | 2080 | 240 | 0 |
| vdm_driverid | 1 | 52 | 4 | 0 |
| vdm_vdt_history_data | 121 | 208680 | 204880 | 1952 |
| vdm_vdt_settings_data | 28 | 1172 | 132 | 464 |
| vdm_vdt_odr_data | 14 | 24700 | 24304 | 240 |
| vwm | 64 | 3436 | 256 | 1040 |
| traffic_stm | 19 | 3444 | 2852 | 320 |
| vdm_vdt_onehrlog_data | 1 | 1292516 | 1292428 | 32 |
| vdm_vdt_5000DrvLog_data | 1 | 645084 | 645000 | 32 |

(The other nine schemas are in the test output.) If `ls -l /dev/shm` on the
car shows these exact sizes, the sizing rules are confirmed.

## 3. Entry order and lookup by name

| Point | Status | Evidence |
|---|---|---|
| Entry `i` is the `(i+1)`-th XML element in document order (element 0 is the root). Not sorted | PROVEN | `xmlreader:` `xmlreader_StartElement` 0xb44-0xb7c appends each element, count++ at 0xc74-0xc7c. `SMDB_XML_Open` sets the cursor to 1 (0x401c-0x4020); `SMDB_XML_GetNewEntry` reads `nodes[cursor]` (0x45c4-0x45c8) and advances it (0x4774-0x478c, 0x47d8-0x47f8) |
| Every element after the root must carry `type` and `value`; all 21 shipped schemas do, with no nesting | PROVEN | `SMDB_XML_GetNewEntry` 0x467c-0x46b0; schemas checked with a script |
| Names that differ only by case are rejected at creation | PROVEN | `SMDB_XML_GetNewEntry` 0x45e4-0x4618, `strcasecmp` against all earlier elements |
| Lookup is a linear scan with `strcasecmp` (case-insensitive), no early exit, so the last match wins | PROVEN | `SMDB_SHMEM_GetEntryIndexByName` 0x28cc-0x290c (`strcasecmp` 0x28e8); `SMDB_SHMEM_GetEntryByName` 0x29c8-0x2a14 |
| XML type names are matched case-insensitively; attribute names (`type`, `value`, `size`) are case-sensitive | PROVEN | `strcasecmp` 0x4124-0x4150; `xmlreader:` `XMLREADER_FindAttributeByName` uses `strcmp` at 0x10d4 |

## 4. How SMDB_ReadIntData reads an int

Signature (PROVEN from `smdb-read:` 0x8c1c-0x8c28 and 0x2fb0-0x2fc4):
`int SMDB_ReadIntData(handle, const char *name, int *out)`. It takes the
name, not an index.

1. Requires access bit 0, else status 4 (0x2fdc-0x2fe4).
2. `SMDB_Lock` = `sem_wait`, retried on `EINTR`, `abort()` on any other
   error (0x304c; `SMDB_Lock` 0x3df0-0x3e3c).
3. `SMDB_SHMEM_GetEntryByName` gives data pointer, type and size (0x3050-0x3068).
4. Type must be 1, else status 10 (0x3080-0x3088).
5. One 32-bit load from the data pointer, stored to `*out` (0x3120 `ldr r3,[r3]`,
   0x3124 `str r3,[r6]`). Four bytes, native endian. All PROVEN.
6. `SMDB_Unlock` = `sem_post` (0x3114-0x3118).

Signedness: the value is a plain 32-bit word. Defaults come from `strtol`
and `smdb-read` prints it with `%d`, so it is treated as a signed int
(PROVEN for those two uses; what each producer means by the bits is not
decided by this library).

Is skipping the lock safe for a 4-byte read?

| Point | Status | Evidence |
|---|---|---|
| `SMDB_WriteIntData` writes with a single 32-bit store, under the semaphore | PROVEN | 0x35c0 lock, 0x35fc `streq r7,[r3]`, 0x3630-0x3634 unlock |
| The slot is 4-byte aligned | PROVEN | section 2: every block size is a multiple of 4 and the mapping is page-aligned |
| An aligned 32-bit store is atomic on ARMv7, so a lock-free reader sees the old or the new value, never a mix | INFERRED | architecture property, not something this code states |
| The only other writes to an int slot happen while the database is being created (default at 0x23b4, `.dat` load `memcpy` at 0x2790) | PROVEN for this library | writers that bypass the library, if any exist, are unknown |
| The lock gives no consistency across two entries anyway | PROVEN | it is taken and released inside each call |

Conclusion: reading one int without the semaphore is safe. Strings and
binaries are written with `strcpy` / `memcpy` under the lock, so a lock-free
reader can see those half-updated.

## 5. Type codes and what smdb-read prints

| code | name | Evidence |
|---|---|---|
| 1 | int | `SMDB_GetTypeString` 0x3c54-0x3c64, table at 0x4ef0 = `"int"`, `"string"`, `"binary"`; values assigned in `SMDB_XML_GetNewEntry` 0x4778, 0x488c, 0x47e4 |
| 2 | string | same |
| 3 | binary | same |

`smdb-read` (all PROVEN, addresses in `smdb-read`):

- Opens with `SMDB_Open(name, 1)` (0x8f28-0x8f2c). Without `-e` it loops
  `SMDB_GetEntryCount` then index 0..n-1 (0x91c4-0x91fc); with `-e` it uses
  `SMDB_GetEntryIndexByName` (0x8f44-0x8f4c).
- Per entry: `SMDB_GetEntryByIndex(h, index, &name, &type, &size)` (0x8b10-0x8b20).
  For strings the public call reports `size - 1` (0x3bd0-0x3be0).
- Verbose prefix: `"%s (%s, %d): "` with name, type string, size (0x8c58-0x8c74).
- int: `SMDB_ReadIntData`, printed as `%d` (0x8c1c-0x8c4c).
- string: buffer of size+1, `SMDB_ReadString(h, name, buf, size+1)`, printed
  as `%s` (0x8bc4-0x8bfc). `SMDB_ReadString` needs `strlen < bufsize`, else
  status 9 (0x32c8-0x32e0).
- binary: `SMDB_ReadBinaryData(h, name, buf, size)`; the size must equal the
  entry size exactly, else status 9 (0x34e4-0x3520). Printed as `%02X` per
  byte, or written raw to stdout with `-b raw` (0x8cb8-0x8ce8, 0x8d8c-0x8da0).
- A newline follows unless the binary format is raw (0x8b6c-0x8b7c).

Status codes (table at 0x4e94): 0 Success, 1 Open failed, 2 Close failed,
3 Not present, 4 No read permissions, 5 No write permissions, 6 Invalid
handle, 7 Flash write failed, 8 Failed, 9 Invalid parameter, 10 Type
mismatch, 11 Corrupt data.

## 6. What a reader must not do

1. **No `O_CREAT`.** Creating the object does not break the owner by itself
   (an empty object is still initialised, 0x1e98-0x1ea0), but it fixes the
   owner and mode of the file. Do not do it.
2. **No `ftruncate`, no `O_TRUNC`.** A non-empty object is mapped by the
   library with no validation (0x21c4), so a zero-filled object of any size
   would be accepted as a database with 0 entries by every later opener.
   Shrinking a live object makes existing mappers take `SIGBUS`.
3. **No `SMDB_Open` / `smdb-read` for a database that does not exist yet.**
   The vendor open path creates it from the XML, loads the `.dat` image and
   creates the semaphore (0x1ea4 onward, 0x3d28).
4. **No `sem_open(O_CREAT)`, no `sem_wait`.** The semaphore is not robust: a
   reader that dies or stalls while holding it blocks every writer, and the
   library `abort()`s on semaphore errors (0x3e3c, 0x3f14).
5. **No `PROT_WRITE`, no `shm_unlink`.** With an `O_RDONLY` fd a shared
   writable mapping is refused by the kernel anyway.
6. **Do not trust the object during creation.** Between `ftruncate` and the
   end of the fill loop the header is present but entries are still zero.
   `smdb_reader.h` rejects that state (`SMDB_RO_ESIZE` or `SMDB_RO_EENTRY`);
   retry later.

## 7. Deliverables in this folder

- `smdb_reader.h`: the read-only reader. Opens `/dev/shm/smdb_<name>` with
  `O_RDONLY`, maps `PROT_READ, MAP_SHARED`, validates header and the whole
  entry table at open, re-checks every entry on each access.
  Header rules used in place of a magic number: `total == st_size`,
  `16*(n+1) <= total`, `data_size <= total - 16*(n+1)`, data start 4-aligned,
  `path_off` is 0 or `16*(n+1)`. Entry rules: name inside
  `[16*(n+1), data_start)` and NUL-terminated there, type 1..3, data inside
  `[data_start, total)`, int has size 4 and aligned offset.
- `mkimage.py`: builds an image from an XML schema with the same arithmetic.
- `smdb_dump.c`: dumps an image file (`--file`) or a live database (`--db`).
- `smdb_fuzz.c`, `run_tests.sh`: tests. `build/test_output.txt`: last run.

The tests only show that the reader and the generator agree with each other
and that corrupted input is rejected without a crash. Both were written from
the same reading of the disassembly, so a shared misreading would not be
caught.

## 8. Read-only checks on the car (not done)

1. `ls -l /dev/shm/` : expect `smdb_<db>` and `sem.smdb_<db>` files, and the
   sizes in section 2 (18148 bytes for `smdb_vdm_vdt_current_data`). This
   also confirms the `/dev/shm` mount point, which is INFERRED.
2. `cp /dev/shm/smdb_vdm_vdt_current_data <usb>/` and, at the same moment,
   `/jci/smdb/smdb-read -n vdm_vdt_current_data > <usb>/ref.txt`. Offline,
   `smdb_dump --file` on the copy must list the same names in the same order
   with matching values for signals that were not changing. Only do this for
   a database that `ls` already shows, see rule 3 above.
3. Any `/data/smdb_*.dat` file is the same layout and can be fed to
   `smdb_dump --file` as a second sample.
