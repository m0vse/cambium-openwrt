#!/usr/bin/env python3
"""Compile and exercise the production clock guard added by the MDIO patch."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
patch = Path(os.environ.get('CAMBIUM_MDIO_PATCH', root / 'target/linux/qualcommax/patches-6.18/0903-ipq5018-xv2-mdio1-ahb-clock.patch'))
block = '\n'.join(line[1:] for line in patch.read_text().splitlines()
                  if line.startswith('+') and not line.startswith('+++'))
prefix = r'''
#include <stdio.h>
#include <string.h>
struct clk { int unused; };
struct device { int unused; };
struct platform_device { struct device dev; };
static const char *model;
static int calls, fail_clock;
static struct clk clock_value;
static int of_machine_is_compatible(const char *name) { return !strcmp(model, name); }
static struct clk *devm_clk_get_enabled(struct device *dev, const char *name) {
    (void)dev;
    if (strcmp(name, "xv2-mdio1-ahb")) return NULL;
    calls++;
    return fail_clock ? NULL : &clock_value;
}
#define IS_ERR(value) ((value) == NULL)
#define PTR_ERR(value) (-22)
static int dev_err_probe(struct device *dev, int error, const char *message) {
    (void)dev; (void)message; return error;
}
static int probe(struct platform_device *pdev) {
'''
suffix = r'''
    return 0;
}
int main(int argc, char **argv) {
    struct platform_device pdev;
    if (argc != 3) return 2;
    model = argv[1]; fail_clock = argv[2][0] == '1';
    int result = probe(&pdev);
    printf("%d %d\n", result, calls);
    return 0;
}
'''
with tempfile.TemporaryDirectory() as work:
    work = Path(work)
    source = work / 'guard.c'
    source.write_text(prefix + block + suffix)
    binary = work / 'guard'
    subprocess.run([os.environ.get('CC', 'cc'), '-Wall', '-Wextra', '-Werror',
                    str(source), '-o', str(binary)], check=True)
    count = 0
    for board, required in [('xv2-21x', True), ('xv2-23t', True), ('xv2-22h', False), ('other', False)]:
        for failure in [False, True]:
            got = subprocess.check_output([str(binary), 'cambiumnetworks,' + board,
                                           str(int(failure))], text=True).strip()
            want = f'{-22 if required and failure else 0} {int(required)}'
            assert got == want, f'{board}, failure={failure}: got {got}, expected {want}'
            count += 1
print(f'Cheetah production MDIO clock guard: {count} cases passed')
