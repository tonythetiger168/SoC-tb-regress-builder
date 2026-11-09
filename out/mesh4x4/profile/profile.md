# Memory and latency profile: soc4x4

Mesh 4x4, routing `xy`, router 2 cy, link 1 cy, NI 1 cy.

Minimum read latency (first data beat) = request path + slave access + response path, where one path over h links = NI + (h+1)·router + h·link cycles. The testbench scoreboard checks every transaction against this number. All averages below are weighted by call count.

## Result

| Step | Avg min read latency (cycles) | vs. before |
|---|---|---|
| Before: naive placement, data where the config puts it | 30.017 |  |
| Endpoint placement only | 25.966 | 13.5% lower |

After optimisation an average call spends **14.924 cycles in the network** and **11.042 cycles in the memory itself**. The floor, if every caller sat on the same router as its data in the fastest memory it may use, is 17.042 cycles. Endpoints with a fixed `node` and regions with `pin: true` are not moved.

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
M:cpu0,S:regs  |    S:sram0     |     M:npu      | M:cpu1,S:sram1
    (0,1)      |     (1,1)      |     (2,1)      |  M:dma,S:ddr1 
    (0,2)      |     (1,2)      |     (2,2)      |     M:gpu     
    M:pcie     |     (1,3)      |     (2,3)      |     S:ddr0    
```

## Address map

| Slave | Kind | Base | Size | Node (x,y) | Access cycles |
|---|---|---|---|---|---|
| ddr0 | memory | 0x0000000000 | 1 GB | (3,3) | 20 |
| ddr1 | memory | 0x0040000000 | 1 GB | (3,1) | 20 |
| sram0 | memory | 0x0080000000 | 1 MB | (1,0) | 2 |
| sram1 | memory | 0x0080100000 | 1 MB | (3,0) | 2 |
| regs | memory | 0xf000000000 | 64 KB | (0,0) | 1 |

## Memory ranking per master

Memories ranked by minimum read latency from each master: where to put any data not listed above.

**cpu0**: regs (7 cy), sram0 (14 cy), sram1 (26 cy), ddr1 (50 cy), ddr0 (62 cy)
**cpu1**: sram1 (8 cy), sram0 (20 cy), regs (25 cy), ddr1 (32 cy), ddr0 (44 cy)
**gpu**: sram1 (20 cy), ddr0 (32 cy), ddr1 (32 cy), sram0 (32 cy), regs (37 cy)
**dma**: sram1 (14 cy), ddr1 (26 cy), sram0 (26 cy), regs (31 cy), ddr0 (38 cy)
**npu**: sram0 (14 cy), sram1 (14 cy), regs (19 cy), ddr1 (38 cy), ddr0 (50 cy)
**pcie**: regs (25 cy), sram0 (32 cy), ddr0 (44 cy), sram1 (44 cy), ddr1 (56 cy)

## Per-pair latency

| Master | Slave | Hops req/rsp | Req cy | Slave cy | Rsp cy | Min read cy | Calls |
|---|---|---|---|---|---|---|---|
| cpu0 | ddr0 | 6/6 | 21 | 20 | 21 | 62 | 10 |
| cpu0 | ddr1 | 4/4 | 15 | 20 | 15 | 50 | 10 |
| cpu0 | sram0 | 1/1 | 6 | 2 | 6 | 14 | 40 |
| cpu0 | sram1 | 3/3 | 12 | 2 | 12 | 26 | 0 |
| cpu0 | regs | 0/0 | 3 | 1 | 3 | 7 | 5 |
| cpu1 | ddr0 | 3/3 | 12 | 20 | 12 | 44 | 10 |
| cpu1 | ddr1 | 1/1 | 6 | 20 | 6 | 32 | 10 |
| cpu1 | sram0 | 2/2 | 9 | 2 | 9 | 20 | 0 |
| cpu1 | sram1 | 0/0 | 3 | 2 | 3 | 8 | 40 |
| cpu1 | regs | 3/3 | 12 | 1 | 12 | 25 | 5 |
| gpu | ddr0 | 1/1 | 6 | 20 | 6 | 32 | 30 |
| gpu | ddr1 | 1/1 | 6 | 20 | 6 | 32 | 30 |
| gpu | sram0 | 4/4 | 15 | 2 | 15 | 32 | 0 |
| gpu | sram1 | 2/2 | 9 | 2 | 9 | 20 | 5 |
| gpu | regs | 5/5 | 18 | 1 | 18 | 37 | 0 |
| dma | ddr0 | 2/2 | 9 | 20 | 9 | 38 | 20 |
| dma | ddr1 | 0/0 | 3 | 20 | 3 | 26 | 20 |
| dma | sram0 | 3/3 | 12 | 2 | 12 | 26 | 10 |
| dma | sram1 | 1/1 | 6 | 2 | 6 | 14 | 10 |
| dma | regs | 4/4 | 15 | 1 | 15 | 31 | 0 |
| npu | ddr0 | 4/4 | 15 | 20 | 15 | 50 | 0 |
| npu | ddr1 | 2/2 | 9 | 20 | 9 | 38 | 20 |
| npu | sram0 | 1/1 | 6 | 2 | 6 | 14 | 30 |
| npu | sram1 | 1/1 | 6 | 2 | 6 | 14 | 30 |
| npu | regs | 2/2 | 9 | 1 | 9 | 19 | 0 |
| pcie | ddr0 | 3/3 | 12 | 20 | 12 | 44 | 10 |
| pcie | ddr1 | 5/5 | 18 | 20 | 18 | 56 | 10 |
| pcie | sram0 | 4/4 | 15 | 2 | 15 | 32 | 0 |
| pcie | sram1 | 6/6 | 21 | 2 | 21 | 44 | 0 |
| pcie | regs | 3/3 | 12 | 1 | 12 | 25 | 2 |
