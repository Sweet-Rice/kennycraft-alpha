// newlib system calls for Doom on KennyCraft (doom/README.md).
//
// stdout/stderr go to UART_TX. The only file is the WAD ("doom1.wad", any
// directory prefix), read-only: it sits raw in DDR3 at 0x0040_0000 (CPU
// 0x8040_0000, through the D-cache) and reads are memcpy from there. Every
// other path fails with ENOENT (config files, savegames, response files),
// which Doom handles. The heap runs from the end of .bss up to the stack.
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

#define WAD_BASE ((const uint8_t *)0x80400000u)
#define WAD_MAX  (0x00C00000u)     // up to the data area at 0x8100_0000

#undef errno
extern int errno;

#define MMIO ((volatile uint32_t *)0x50000000u)
#define MMIO_UART_STATUS 0x14
#define MMIO_UART_TX     0x18

#define WAD_NAME "doom1.wad"
#define MAX_FDS  4                 // open handles on the WAD, fds 3..

extern char end[];                 // kc_doom.ld: end of .bss
extern char __stack_limit[];       // kc_doom.ld: bottom of the stack reservation

static char *heap_top = end;

static const uint8_t *wad;         // WAD_BASE once the header checked out
static uint32_t  wad_size;
static int       fd_open[MAX_FDS];
static uint32_t  fd_pos[MAX_FDS];

void kc_uart_putc(char c) {
    while (MMIO[MMIO_UART_STATUS >> 2] & 2u) {}
    MMIO[MMIO_UART_TX >> 2] = (uint8_t)c;
}

void kc_uart_puts(const char *s) {
    while (*s) kc_uart_putc(*s++);
}

__attribute__((noreturn)) static void halt(void) {
    for (;;) {}
}

void *_sbrk(ptrdiff_t incr) {
    char *old = heap_top;
    if (incr > __stack_limit - heap_top || incr < end - heap_top) {
        errno = ENOMEM;
        return (void *)-1;
    }
    heap_top += incr;
    return old;
}

void _exit(int status) {
    kc_uart_puts(status ? "\nkc: exit (error)\n" : "\nkc: exit\n");
    halt();
}

int _kill(int pid, int sig) {
    (void)pid; (void)sig;
    kc_uart_puts("\nkc: abort\n");
    halt();
    return -1;
}

int _getpid(void) { return 1; }

static int is_wad(const char *path) {
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return strcmp(base, WAD_NAME) == 0;
}

static uint32_t rd32le(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

// WAD length from its header and directory (DDR3 holds no file length):
// the end of the directory or of the furthest lump, whichever is later.
static int wad_load(void) {
    const uint8_t *hdr = WAD_BASE;
    if (memcmp(hdr + 1, "WAD", 3) != 0 || (hdr[0] != 'I' && hdr[0] != 'P')) return -1;
    uint32_t n = rd32le(hdr + 4), dir = rd32le(hdr + 8);
    if (n > 65536u || dir > WAD_MAX || dir + n * 16u > WAD_MAX) return -1;
    uint32_t size = dir + n * 16u;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t e = rd32le(WAD_BASE + dir + 16 * i) + rd32le(WAD_BASE + dir + 16 * i + 4);
        if (e > size) size = e;
    }
    if (size > WAD_MAX) return -1;
    wad = WAD_BASE;
    wad_size = size;
    printf("kc: WAD %lu bytes at 0x80400000\n", (unsigned long)size);
    return 0;
}

int _open(const char *path, int flags, int mode) {
    (void)mode;
    if (!is_wad(path)) { errno = ENOENT; return -1; }
    if ((flags & O_ACCMODE) != O_RDONLY) { errno = EACCES; return -1; }
    if (!wad && wad_load() < 0) { errno = EIO; return -1; }
    for (int i = 0; i < MAX_FDS; i++) {
        if (!fd_open[i]) {
            fd_open[i] = 1;
            fd_pos[i] = 0;
            return 3 + i;
        }
    }
    errno = EMFILE;
    return -1;
}

static int wad_fd(int fd) {
    int i = fd - 3;
    return (i >= 0 && i < MAX_FDS && fd_open[i]) ? i : -1;
}

int _close(int fd) {
    int i = wad_fd(fd);
    if (i < 0) { errno = EBADF; return -1; }
    fd_open[i] = 0;
    return 0;
}

int _read(int fd, void *buf, size_t len) {
    int i = wad_fd(fd);
    if (i < 0) { errno = EBADF; return -1; }
    uint32_t left = wad_size - fd_pos[i];
    if (len > left) len = left;
    memcpy(buf, wad + fd_pos[i], len);
    fd_pos[i] += len;
    return (int)len;
}

int _write(int fd, const void *buf, size_t len) {
    if (fd != 1 && fd != 2) { errno = EBADF; return -1; }
    const char *p = buf;
    for (size_t k = 0; k < len; k++) kc_uart_putc(p[k]);
    return (int)len;
}

off_t _lseek(int fd, off_t off, int whence) {
    int i = wad_fd(fd);
    if (i < 0) { errno = (fd >= 0 && fd <= 2) ? ESPIPE : EBADF; return -1; }
    int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? (int64_t)fd_pos[i]
                 : whence == SEEK_END ? (int64_t)wad_size : -1;
    int64_t p = base + off;
    if (base < 0 || p < 0 || p > wad_size) { errno = EINVAL; return -1; }
    fd_pos[i] = (uint32_t)p;
    return (off_t)p;
}

int _fstat(int fd, struct stat *st) {
    memset(st, 0, sizeof *st);
    if (fd >= 0 && fd <= 2) { st->st_mode = S_IFCHR; return 0; }
    if (wad_fd(fd) < 0) { errno = EBADF; return -1; }
    st->st_mode = S_IFREG | 0444;
    st->st_size = wad_size;
    return 0;
}

int _stat(const char *path, struct stat *st) {
    if (!is_wad(path)) { errno = ENOENT; return -1; }
    int fd = _open(path, O_RDONLY, 0);
    if (fd < 0) return -1;
    int r = _fstat(fd, st);
    _close(fd);
    return r;
}

int _isatty(int fd) {
    if (fd >= 0 && fd <= 2) return 1;
    errno = wad_fd(fd) < 0 ? EBADF : ENOTTY;
    return 0;
}

int _link(const char *old, const char *new) {
    (void)old; (void)new;
    errno = EACCES;
    return -1;
}

int _unlink(const char *path) {
    (void)path;
    errno = ENOENT;
    return -1;
}

int mkdir(const char *path, mode_t mode) {
    (void)path; (void)mode;
    errno = EACCES;
    return -1;
}
