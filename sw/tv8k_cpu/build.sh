#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the tv8k CPU program with clang/lld: <out_dir>/tv8k_cpu.hex (one 32-bit
# little-endian word per line from 0x8000_0000, the form xuanji's TBs load).
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-.}
mkdir -p "$OUT"
CF="--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -nostdlib -fno-builtin"
clang $CF -c start.S -o "$OUT/start.o"
clang $CF -c main.c -o "$OUT/main.o"
ld.lld -m elf64lriscv --no-relax -Ttext=0x80000000 -e _start "$OUT/start.o" "$OUT/main.o" -o "$OUT/tv8k_cpu.elf"
llvm-objcopy -O binary "$OUT/tv8k_cpu.elf" "$OUT/tv8k_cpu.bin"
python3 - "$OUT/tv8k_cpu.bin" "$OUT/tv8k_cpu.hex" <<'P'
import sys
b = open(sys.argv[1], 'rb').read()
b += b'\0' * (-len(b) % 4)
open(sys.argv[2], 'w').write(''.join('%08x\n' % int.from_bytes(b[i:i + 4], 'little') for i in range(0, len(b), 4)))
P
echo "$OUT/tv8k_cpu.hex: $(wc -l < "$OUT/tv8k_cpu.hex") words"
