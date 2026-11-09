# Memory and latency profile: soc4x4_regions

Mesh 4x4, routing `xy`, router 2 cy, link 1 cy, NI 1 cy.

Minimum read latency (first data beat) = request path + slave access + response path, where one path over h links = NI + (h+1)·router + h·link cycles. The testbench scoreboard checks every transaction against this number. All averages below are weighted by call count.

## Result

| Step | Avg min read latency (cycles) | vs. before |
|---|---|---|
| Before: naive placement, data where the config puts it | 30.017 |  |
| Endpoint placement only | 25.966 | 13.5% lower |
| Placement + data placement + read-only copies | 21.126 | 29.6% lower |

After optimisation an average call spends **10.336 cycles in the network** and **10.79 cycles in the memory itself**. The floor, if every caller sat on the same router as its data in the fastest memory it may use, is 10.487 cycles. Endpoints with a fixed `node` and regions with `pin: true` are not moved.

## Placement

Before:
```
M:cpu0,S:ddr1 | M:gpu,S:sram0 | M:dma,S:sram1 | M:cpu1,S:regs
    M:npu     |     (1,1)     |     (2,1)     |     (3,1)    
    (0,2)     |     (1,2)     |     (2,2)     |     (3,2)    
    M:pcie    |     (1,3)     |     (2,3)     |     S:ddr0   
```

After (use this placement):
```
M:cpu0,S:sram1 |     S:regs     |     (2,0)      | M:cpu1,S:ddr1 
    (0,1)      |     (1,1)      |     (2,1)      | M:npu,S:sram0 
    (0,2)      |     (1,2)      |     (2,2)      |     M:dma     
    M:pcie     |     (1,3)      |     (2,3)      |  M:gpu,S:ddr0 
```

## Address map

| Slave | Kind | Base | Size | Node (x,y) | Access cycles |
|---|---|---|---|---|---|
| ddr0 | memory | 0x0000000000 | 1 GB | (3,3) | 20 |
| ddr1 | memory | 0x0040000000 | 1 GB | (3,0) | 20 |
| sram0 | memory | 0x0080000000 | 1 MB | (3,1) | 2 |
| sram1 | memory | 0x0080100000 | 1 MB | (0,0) | 2 |
| regs | device | 0xf000000000 | 64 KB | (1,0) | 1 |

## Data placement

Where each data region should live. A region with more than one copy is read-only and has been copied next to its callers; each caller should use the copy listed for it.

| Region | Size | Was in | Now in (address) | Callers: copy used, min read cycles |
|---|---|---|---|---|
| cpu0_stack | 64 KB | sram0 | sram1 (0x00801c0000) **moved** | cpu0: sram1 8 cy |
| cpu0_data | 512 KB | sram0 | sram1 (0x0080100000) **moved** | cpu0: sram1 8 cy |
| cpu1_stack | 64 KB | sram1 | sram0 (0x00800c0000) **moved** | cpu1: sram0 14 cy |
| cpu1_data | 512 KB | sram1 | ddr1 (0x0046000000) **moved** | cpu1: ddr1 26 cy |
| kernel_text (RO) | 256 KB | ddr0 | sram1 (0x0080180000) **moved** | cpu0: sram1 8 cy, cpu1: sram1 26 cy |
| os_heap | 64 MB | ddr1 | ddr1 (0x0040000000) | cpu0: ddr1 44 cy, cpu1: ddr1 26 cy |
| frame_buf | 32 MB | ddr0 | ddr0 (0x0000000000) | gpu: ddr0 26 cy, dma: ddr0 32 cy |
| textures_0 (RO) | 32 MB | ddr1 | ddr0 (0x0002000000) **moved** | gpu: ddr0 26 cy, dma: ddr0 32 cy |
| textures_1 (RO) | 32 MB | ddr1 | ddr0 (0x0004000000) **moved** | gpu: ddr0 26 cy, dma: ddr0 32 cy |
| textures_2 (RO) | 32 MB | ddr1 | ddr0 (0x0006000000) **moved** | gpu: ddr0 26 cy, dma: ddr0 32 cy |
| textures_3 (RO) | 32 MB | ddr1 | ddr0 (0x0008000000) **moved** | gpu: ddr0 26 cy, dma: ddr0 32 cy |
| gpu_cmdq | 64 KB | sram1 | sram0 (0x00800d0000) **moved** | gpu: sram0 20 cy |
| dma_desc0 | 128 KB | sram0 | sram0 (0x0080080000) | dma: sram0 14 cy |
| dma_desc1 | 128 KB | sram1 | sram0 (0x00800a0000) **moved** | dma: sram0 14 cy |
| npu_weights (RO) | 256 KB | sram0 | sram0 (0x0080040000) | npu: sram0 8 cy |
| npu_act | 256 KB | sram1 | sram0 (0x0080000000) **moved** | npu: sram0 8 cy |
| npu_model (RO) | 32 MB | ddr1 | ddr1 (0x0044000000) | npu: ddr1 32 cy |
| pcie_rx | 8 MB | ddr0 | ddr0 (0x000a000000) | pcie: ddr0 44 cy |
| pcie_tx | 8 MB | ddr1 | ddr0 (0x000a800000) **moved** | pcie: ddr0 44 cy |

## Memory ranking per master

Memories ranked by minimum read latency from each master: where to put any data not listed above.

**cpu0**: sram1 (8 cy), regs (13 cy), sram0 (32 cy), ddr1 (44 cy), ddr0 (62 cy)
**cpu1**: sram0 (14 cy), regs (19 cy), ddr1 (26 cy), sram1 (26 cy), ddr0 (44 cy)
**gpu**: sram0 (20 cy), ddr0 (26 cy), regs (37 cy), ddr1 (44 cy), sram1 (44 cy)
**dma**: sram0 (14 cy), regs (31 cy), ddr0 (32 cy), ddr1 (38 cy), sram1 (38 cy)
**npu**: sram0 (8 cy), regs (25 cy), ddr1 (32 cy), sram1 (32 cy), ddr0 (38 cy)
**pcie**: sram1 (26 cy), regs (31 cy), sram0 (38 cy), ddr0 (44 cy), ddr1 (62 cy)

## Per-pair latency

| Master | Slave | Hops req/rsp | Req cy | Slave cy | Rsp cy | Min read cy | Calls |
|---|---|---|---|---|---|---|---|
| cpu0 | ddr0 | 6/6 | 21 | 20 | 21 | 62 | 0 |
| cpu0 | ddr1 | 3/3 | 12 | 20 | 12 | 44 | 10 |
| cpu0 | sram0 | 4/4 | 15 | 2 | 15 | 32 | 0 |
| cpu0 | sram1 | 0/0 | 3 | 2 | 3 | 8 | 50 |
| cpu0 | regs | 1/1 | 6 | 1 | 6 | 13 | 5 |
| cpu1 | ddr0 | 3/3 | 12 | 20 | 12 | 44 | 0 |
| cpu1 | ddr1 | 0/0 | 3 | 20 | 3 | 26 | 25 |
| cpu1 | sram0 | 1/1 | 6 | 2 | 6 | 14 | 25 |
| cpu1 | sram1 | 3/3 | 12 | 2 | 12 | 26 | 10 |
| cpu1 | regs | 2/2 | 9 | 1 | 9 | 19 | 5 |
| gpu | ddr0 | 0/0 | 3 | 20 | 3 | 26 | 60 |
| gpu | ddr1 | 3/3 | 12 | 20 | 12 | 44 | 0 |
| gpu | sram0 | 2/2 | 9 | 2 | 9 | 20 | 5 |
| gpu | sram1 | 6/6 | 21 | 2 | 21 | 44 | 0 |
| gpu | regs | 5/5 | 18 | 1 | 18 | 37 | 0 |
| dma | ddr0 | 1/1 | 6 | 20 | 6 | 32 | 40 |
| dma | ddr1 | 2/2 | 9 | 20 | 9 | 38 | 0 |
| dma | sram0 | 1/1 | 6 | 2 | 6 | 14 | 20 |
| dma | sram1 | 5/5 | 18 | 2 | 18 | 38 | 0 |
| dma | regs | 4/4 | 15 | 1 | 15 | 31 | 0 |
| npu | ddr0 | 2/2 | 9 | 20 | 9 | 38 | 0 |
| npu | ddr1 | 1/1 | 6 | 20 | 6 | 32 | 20 |
| npu | sram0 | 0/0 | 3 | 2 | 3 | 8 | 60 |
| npu | sram1 | 4/4 | 15 | 2 | 15 | 32 | 0 |
| npu | regs | 3/3 | 12 | 1 | 12 | 25 | 0 |
| pcie | ddr0 | 3/3 | 12 | 20 | 12 | 44 | 20 |
| pcie | ddr1 | 6/6 | 21 | 20 | 21 | 62 | 0 |
| pcie | sram0 | 5/5 | 18 | 2 | 18 | 38 | 0 |
| pcie | sram1 | 3/3 | 12 | 2 | 12 | 26 | 0 |
| pcie | regs | 4/4 | 15 | 1 | 15 | 31 | 2 |
