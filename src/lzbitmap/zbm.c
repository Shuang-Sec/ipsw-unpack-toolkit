/* zbm —— 解 decmpfs type 14 (CMP_RSRC_LZBITMAP) 透明压缩文件
 * 用法: zbm <com.apple.decmpfs> <com.apple.ResourceFork> <输出文件>
 * 格式: decmpfs = magic(4)+type(4)+usize(8)；ResourceFork = 偏移表(uint32×N) + N 个压缩块
 * 注意: zbm_decompress 返回 0 表示成功（负数才是错误），输出长度由 out_len 给出。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "libzbitmap.h"

#define BLOCK 0x10000

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t rd64(const uint8_t *p) {
    return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "用法: zbm <decmpfs> <ResourceFork> <输出文件>\n"); return 2; }

    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("打开 decmpfs"); return 1; }
    uint8_t hdr[16];
    if (fread(hdr, 1, 16, f) != 16) { fprintf(stderr, "decmpfs 头过短\n"); return 1; }
    fclose(f);
    uint32_t ctype = rd32(hdr + 4);
    uint64_t usize = rd64(hdr + 8);
    fprintf(stderr, "type=%u uncompressedSize=%llu\n", ctype, (unsigned long long)usize);
    if (ctype != 14) { fprintf(stderr, "本工具只处理 type 14\n"); return 1; }

    f = fopen(argv[2], "rb");
    if (!f) { perror("打开 ResourceFork"); return 1; }
    fseek(f, 0, SEEK_END); long rs = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *rsrc = malloc((size_t)rs);
    if (!rsrc || fread(rsrc, 1, (size_t)rs, f) != (size_t)rs) { fprintf(stderr, "读 ResourceFork 失败\n"); return 1; }
    fclose(f);

    uint32_t first = rd32(rsrc);
    int n = (int)(first / 4);
    fprintf(stderr, "块数=%d 预期=%llu\n", n, (unsigned long long)((usize + BLOCK - 1) / BLOCK));

    uint8_t *out = malloc((size_t)usize + BLOCK);
    uint8_t dec[BLOCK];
    size_t total = 0; int ok = 0, fail = 0;
    for (int i = 0; i < n; i++) {
        uint32_t s = rd32(rsrc + (size_t)i * 4);
        uint32_t e = (i + 1 < n) ? rd32(rsrc + (size_t)(i + 1) * 4) : (uint32_t)rs;
        if (s >= e || e > (uint32_t)rs) break;
        size_t outlen = 0;
        int rc = zbm_decompress(dec, BLOCK, rsrc + s, e - s, &outlen);   /* 0 = 成功 */
        if (rc == 0 && outlen > 0) {
            if (total + outlen > (size_t)usize) outlen = (size_t)usize - total;
            memcpy(out + total, dec, outlen);
            total += outlen; ok++;
        } else {
            if (fail < 3) fprintf(stderr, "  块 %d 失败 rc=%d size=%u\n", i, rc, e - s);
            fail++;
        }
        if (total >= (size_t)usize) break;
    }
    fprintf(stderr, "解压 %d 块成功 / %d 失败, 共 %zu 字节\n", ok, fail, total);

    f = fopen(argv[3], "wb");
    if (!f) { perror("写输出"); return 1; }
    fwrite(out, 1, total, f);
    fclose(f);
    free(rsrc); free(out);
    return (total > 0) ? 0 : 1;
}
