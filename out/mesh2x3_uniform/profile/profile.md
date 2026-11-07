# Memory and latency profile: tiny

Mesh 3x2, routing `shortest`, router 2 cy, link 1 cy, NI 1 cy.

Minimum read latency (first data beat) = request path + slave access + response path, where one path over h links = NI + (h+1)·router + h·link cycles. The testbench scoreboard checks every transaction against this number. All averages below are weighted by call count.

## Result

| Step | Avg min read latency (cycles) | vs. before |
|---|---|---|
| Before: naive placement, data where the config puts it | 18.0 |  |
| Endpoint placement only | 12.0 | 33.3% lower |

After optimisation an average call spends **9.0 cycles in the network** and **3.0 cycles in the memory itself**. The floor, if every caller sat on the same router as its data in the fastest memory it may use, is 9.0 cycles. Endpoints with a fixed `node` and regions with `pin: true` are not moved.

## Placement

Before:
```
M:m0,S:mem | M:m1,S:rom |   (2,0)   
  (0,1)    |   (1,1)    |   (2,1)   
```

After (use this placement):
```
M:m0,S:rom |   (1,0)    |   (2,0)   
M:m1,S:mem |   (1,1)    |   (2,1)   
```

## Address map

| Slave | Kind | Base | Size | Node (x,y) | Access cycles |
|---|---|---|---|---|---|
| mem | memory | 0x00000000 | 1 MB | (0,1) | 4 |
| rom | memory | 0x00100000 | 64 KB | (0,0) | 2 |

## Memory ranking per master

Memories ranked by minimum read latency from each master: where to put any data not listed above.

**m0**: rom (8 cy), mem (16 cy)
**m1**: mem (10 cy), rom (14 cy)

## Per-pair latency

| Master | Slave | Hops req/rsp | Req cy | Slave cy | Rsp cy | Min read cy | Calls |
|---|---|---|---|---|---|---|---|
| m0 | mem | 1/1 | 6 | 4 | 6 | 16 | 1 |
| m0 | rom | 0/0 | 3 | 2 | 3 | 8 | 1 |
| m1 | mem | 0/0 | 3 | 4 | 3 | 10 | 1 |
| m1 | rom | 1/1 | 6 | 2 | 6 | 14 | 1 |
