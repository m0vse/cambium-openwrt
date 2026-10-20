#!/usr/bin/env python3
"""Exercise the actual Miami bootinfo function using a synthetic ELF header.

Usage: test-miami-q6-bootinfo.py /path/to/patched/qcom_q6v5_wcss_sec.c
An optional second argument selects a private ELF fixture for local testing.
"""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).read_text()
start = source.index("struct miami_upd_bootinfo {")
end = source.index("\nstatic int wcss_sec_start(", start)
code = source[start:end].replace("struct elf32_hdr", "Elf32_Ehdr").replace("struct elf32_phdr", "Elf32_Phdr")
if len(sys.argv) > 2:
    data = Path(sys.argv[2]).read_bytes()
else:
    # A header-only split ELF: no proprietary firmware bytes are required.
    ident = b"\x7fELF\x01\x01\x01" + bytes(9)
    data = struct.pack("<16sHHIIIIIHHHHHH", ident, 2, 164, 1,
                       0x4adfc000, 52, 0, 0, 52, 32, 3, 0, 0, 0)
    data += bytes(64)
    data += struct.pack("<8I", 1, 0, 0x4adfc000, 0x4adfc000,
                        0x503b00, 0x504000, 7, 4096)
stub = r'''
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <elf.h>
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef uint16_t __le16;
typedef uint32_t __le32;
#define __packed __attribute__((packed))
#define U32_MAX UINT32_MAX
#define cpu_to_le16(x) (x)
#define cpu_to_le32(x) (x)
#define le32_to_cpu(x) (x)
#define min(a,b) ((a)<(b)?(a):(b))
#define max(a,b) ((a)>(b)?(a):(b))
#define IS_ERR(p) ((intptr_t)(p)<0)
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define memset_io memset
#define memcpy_toio memcpy
#define wmb() ((void)0)
#define dev_info(...) ((void)0)
struct firmware { size_t size; const uint8_t *data; } fw;
struct wcss_sec { void *dev; u64 mem_phys; size_t mem_size; };
static bool miami=true;
static int alloc_result;
static size_t smem_size=4096;
static uint8_t smem[4096];
static int requested, released;
static bool of_machine_is_compatible(const char *s) {
    assert(!strcmp(s,"cambiumnetworks,x7-35x")); return miami;
}
static int request_firmware(const struct firmware **f, const char *name, void *dev) {
    assert(!strcmp(name,"ath12k/IPQ5332/hw1.0/q6_fw1.mbn")); (void)dev;
    *f=&fw; requested++; return 0;
}
static void release_firmware(const struct firmware *f) { assert(f==&fw); released++; }
static int qcom_smem_alloc(int host,int id,size_t size) {
    assert(host==1 && id==507 && size==4096); return alloc_result;
}
static void *qcom_smem_get(int host,int id,size_t *size) {
    assert(host==1 && id==507); *size=smem_size; return smem;
}
'''
blob = "static uint8_t original[]={" + ",".join(str(b) for b in data) + "};\n"
main = r'''
int main(void) {
    static const uint8_t expected[]={0x02,0x00,0x0b,0x00,0x02,0x09,0x02,0x00,0xc0,0xdf,0x4a,0x00,0x3b,0x50,0x00};
    struct wcss_sec wcss={NULL,0x4a900000,0x2300000};
    uint8_t copy[sizeof(original)]; int count=0;
    fw=(struct firmware){sizeof(copy),copy};
    for (int i=0;i<9;i++) {
        memcpy(copy,original,sizeof(copy)); fw.size=sizeof(copy);
        memset(smem,0xa5,sizeof(smem)); miami=true; alloc_result=0; smem_size=4096;
        requested=released=0;
        Elf32_Ehdr *eh=(Elf32_Ehdr *)copy;
        Elf32_Phdr *ph=(Elf32_Phdr *)(copy+eh->e_phoff);
        int expected_ret=0;
        if(i==1) alloc_result=-EEXIST;
        if(i==2) { alloc_result=-ENOMEM; expected_ret=-ENOMEM; }
        if(i==3) { smem_size=1024; expected_ret=-EINVAL; }
        if(i==4) { eh->e_entry=0; expected_ret=-EINVAL; }
        if(i==5) { ph[2].p_filesz=ph[2].p_memsz+1; expected_ret=-EINVAL; }
        if(i==6) { fw.size=8; expected_ret=-EINVAL; }
        if(i==7) { eh->e_phoff=UINT32_MAX; expected_ret=-EINVAL; }
        if(i==8) miami=false;
        assert(wcss_miami_bootinfo(&wcss)==expected_ret);
        if(!expected_ret && miami) {
            assert(!memcmp(smem,expected,sizeof(expected)));
            for(unsigned j=sizeof(expected);j<sizeof(smem);j++) assert(smem[j]==0);
        } else {
            for(unsigned j=0;j<sizeof(smem);j++) assert(smem[j]==0xa5);
        }
        assert(requested==released && requested==(miami?1:0)); count++;
    }
    assert(count==9);
    puts("PASS: 9 actual-source cases; byte-exact OEM record, file size not page-rounded, malformed/bounds/allocation failures leave SMEM untouched, other boards untouched");
}
'''
with tempfile.TemporaryDirectory(prefix="miami-q6-bootinfo-test-") as temp:
    path = Path(temp)
    (path / "test.c").write_text(stub + blob + code + main)
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", "-fsanitize=undefined,address",
                    str(path / "test.c"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
