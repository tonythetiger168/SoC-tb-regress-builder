# SPDX-License-Identifier: Apache-2.0
"""nocgen -- the NoC RTL for socgen `noc.model: mesh`

From the elaborated SoC spec it writes
  rtl/noc_cfg_pkg.sv   mesh size, endpoints, placement, address decode and
                       flit / packet formats; the generic RTL in rtl/noc/
                       (noc_mesh, noc_ni_mst, noc_ni_slv, noc_router_open)
                       imports it by this fixed name
  rtl/<soc>_noc.sv     the NoC: one named AMBA port per master and per slave
                       port (AXI4, AXI4-Lite, AHB-Lite or APB4), the protocol
                       adapters, the network interfaces and the router mesh
and the tb_top text that wires it to the bench's AXI4 VIP ports (with a test
shim for every port that is not AXI4).
"""
import math

# AMBA port signals: (name, width, direction seen from the endpoint that drives
# the request, i.e. "o" = driven by the master side)
AXI4 = [("awid", "IDW", "o"), ("awaddr", 32, "o"), ("awlen", 8, "o"), ("awsize", 3, "o"),
        ("awburst", 2, "o"), ("awprot", 3, "o"), ("awvalid", 1, "o"), ("awready", 1, "i"),
        ("wdata", 32, "o"), ("wstrb", 4, "o"), ("wlast", 1, "o"), ("wvalid", 1, "o"), ("wready", 1, "i"),
        ("bid", "IDW", "i"), ("bresp", 2, "i"), ("bvalid", 1, "i"), ("bready", 1, "o"),
        ("arid", "IDW", "o"), ("araddr", 32, "o"), ("arlen", 8, "o"), ("arsize", 3, "o"),
        ("arburst", 2, "o"), ("arprot", 3, "o"), ("arvalid", 1, "o"), ("arready", 1, "i"),
        ("rid", "IDW", "i"), ("rdata", 32, "i"), ("rresp", 2, "i"), ("rlast", 1, "i"),
        ("rvalid", 1, "i"), ("rready", 1, "o")]
LITE = [("awaddr", 32, "o"), ("awprot", 3, "o"), ("awvalid", 1, "o"), ("awready", 1, "i"),
        ("wdata", 32, "o"), ("wstrb", 4, "o"), ("wvalid", 1, "o"), ("wready", 1, "i"),
        ("bresp", 2, "i"), ("bvalid", 1, "i"), ("bready", 1, "o"),
        ("araddr", 32, "o"), ("arprot", 3, "o"), ("arvalid", 1, "o"), ("arready", 1, "i"),
        ("rdata", 32, "i"), ("rresp", 2, "i"), ("rvalid", 1, "i"), ("rready", 1, "o")]
# AHB-Lite: on a master port the NoC is the slave (hsel, hready in; hreadyout out);
# on a slave port the NoC is the only master of its slave (hsel out = 1, hready in)
AHB_MST = [("hsel", 1, "o"), ("haddr", 32, "o"), ("htrans", 2, "o"), ("hwrite", 1, "o"),
           ("hsize", 3, "o"), ("hburst", 3, "o"), ("hprot", 4, "o"), ("hwdata", 32, "o"),
           ("hready", 1, "o"), ("hrdata", 32, "i"), ("hreadyout", 1, "i"), ("hresp", 1, "i")]
AHB_SLV = [("hsel", 1, "o"), ("haddr", 32, "o"), ("htrans", 2, "o"), ("hwrite", 1, "o"),
           ("hsize", 3, "o"), ("hburst", 3, "o"), ("hprot", 4, "o"), ("hwdata", 32, "o"),
           ("hrdata", 32, "i"), ("hready", 1, "i"), ("hresp", 1, "i")]
APB = [("paddr", 32, "o"), ("psel", 1, "o"), ("penable", 1, "o"), ("pwrite", 1, "o"),
       ("pwdata", 32, "o"), ("pstrb", 4, "o"), ("pprot", 3, "o"),
       ("prdata", 32, "i"), ("pready", 1, "i"), ("pslverr", 1, "i")]

# CHI RN-F port (noc_cfg_pkg chi_*_t flits): TX = from the RN-F, RX = to it
CHI = [("txreq_valid", 1, "o"), ("txreq_ready", 1, "i"), ("txreq_flit", "chi_req_t", "o"),
       ("txrsp_valid", 1, "o"), ("txrsp_ready", 1, "i"), ("txrsp_flit", "chi_rsp_t", "o"),
       ("txdat_valid", 1, "o"), ("txdat_ready", 1, "i"), ("txdat_flit", "chi_dat_t", "o"),
       ("rxrsp_valid", 1, "i"), ("rxrsp_flit", "chi_rsp_t", "i"),
       ("rxdat_valid", 1, "i"), ("rxdat_flit", "chi_dat_t", "i"),
       ("rxsnp_valid", 1, "i"), ("rxsnp_flit", "chi_snp_t", "i")]

MST_SIGS = {"axi4": AXI4, "axi4lite": LITE, "ahb": AHB_MST, "chi": CHI}
SLV_SIGS = {"axi4": AXI4, "axi4lite": LITE, "ahb": AHB_SLV, "apb": APB}

PROTO_NAME = {"axi4": "AXI4", "axi4lite": "AXI4-Lite", "ahb": "AHB-Lite", "apb": "APB4", "chi": "CHI RN-F"}


def clog2(n):
    return max(1, math.ceil(math.log2(n))) if n > 1 else 1


def params(m):
    """derived NoC parameters"""
    nm, ns = len(m.masters), len(m.targets)
    ngw = m.chiplet.dies if m.chiplet.dies > 1 else 0
    nhn = len(m.chi.homes) if m.chi.rn else 0
    nep = nm + ns + ngw + nhn
    p = dict(nm=nm, ns=ns, ngw=ngw, nhn=nhn, nep=nep, epb=clog2(nep + 1),
             xb=2 if m.noc.router_ip == "orca" else clog2(m.noc.cols),
             yb=2 if m.noc.router_ip == "orca" else clog2(m.noc.rows),
             qd=(nm + nhn) * m.noc_ni.maxo, hq=2 * nm * m.noc_ni.maxo)
    return p


def _w(width):
    if width == 1:
        return ""
    if width == "IDW":
        return "[ID_WIDTH-1:0] "
    return f"[{width - 1}:0] "


def _decl(width, name, pkg=""):
    """a wire / port type and name: logic [..] name, or a noc_cfg_pkg CHI flit type"""
    if isinstance(width, str) and width.startswith("chi_"):
        return f"{pkg}{width} {name}"
    return f"logic {_w(width)}{name}"


def cfg_pkg(m):
    p = params(m)
    P = f"{m.name}_pkg"
    gws = m.chiplet.gateways if p["ngw"] else []
    eps = [x.name for x in m.masters] + [t.name for t in m.targets] + [f"d2d{d}" for d in range(len(gws))]
    ex = [x.node[0] for x in m.masters] + [t.node[0] for t in m.targets] + [g[0] for g in gws]
    ey = [x.node[1] for x in m.masters] + [t.node[1] for t in m.targets] + [g[1] for g in gws]
    ed = [x.die for x in m.masters] + [t.die for t in m.targets] + list(range(len(gws)))
    for k, h in enumerate(m.chi.homes if p["nhn"] else []):
        eps.append(f"hnf{k}")
        ex.append(h.node[0])
        ey.append(h.node[1])
        ed.append(h.die)
    coh = ", ".join("1'b1" if t.index in m.chi.coh_targets else "1'b0" for t in m.targets)
    rn_ep = ", ".join(str(i) for i in m.chi.rn) if m.chi.rn else "0"
    names = "\n".join(f"      {i}: return \"{n}\";" for i, n in enumerate(eps))
    return f"""// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// noc_cfg_pkg -- generated by socgen (nocgen) for {m.name}
// ----------------------------------------------------------------------------
// Configuration of the generic NoC RTL in rtl/noc/ (noc_mesh, noc_ni_mst,
// noc_ni_slv, noc_router_open): mesh size, endpoints and their routers, the
// address decode, and the flit / packet formats. Endpoints: masters 0..NM-1
// in {P} M_* order, then the NoC slave ports NM + S_*.
//
// The flit has the bit layout of xuanji-core orca_pkg::flit_t (525 bits with
// 2-bit mesh coordinates), so orca_noc_router and noc_router_open both carry
// it. One packet = one single flit: a chunk of up to 8 32-bit words.
// ============================================================================
package noc_cfg_pkg;

  // ---------------- mesh ----------------
  localparam int MESH_X = {m.noc.cols};
  localparam int MESH_Y = {m.noc.rows};
  localparam int XB = {p['xb']}, YB = {p['yb']};          // mesh coordinate bits{' (orca_pkg NOC_X_BITS / NOC_Y_BITS)' if m.noc.router_ip == 'orca' else ''}
  localparam int PAYLOAD_W = 512;         // orca_pkg NOC_DATA_WIDTH

  typedef enum logic [1:0] {{ FT_HEAD = 2'd0, FT_BODY = 2'd1, FT_TAIL = 2'd2, FT_SINGLE = 2'd3 }} ftype_e;

  typedef struct packed {{
    logic [PAYLOAD_W-1:0] payload;
    logic [XB-1:0]        dest_x;
    logic [YB-1:0]        dest_y;
    logic [XB-1:0]        src_x;
    logic [YB-1:0]        src_y;
    logic [1:0]           vc_id;
    ftype_e               ftype;
    logic                 valid;
  }} noc_flit_t;
  localparam int FLIT_W = $bits(noc_flit_t);

  localparam logic [1:0] VC_REQ = 2'd0;
  localparam logic [1:0] VC_RSP = 2'd1;

  // ---------------- endpoints ----------------
  localparam int NM  = {p['nm']};
  localparam int NS  = {p['ns']};
  localparam int NGW = {p['ngw']};                  // die-to-die gateways (endpoints NM + NS ..)
  localparam int NHN = {p['nhn']};                  // CHI home nodes (HN-F), endpoints NM + NS + NGW ..
  localparam int NEP = NM + NS + NGW + NHN;
  localparam int NDIE = {m.chiplet.dies};
  localparam int EPB = {p['epb']};                  // endpoint id width
  localparam logic [EPB-1:0] EP_NONE = '1;      // decode miss: DECERR from the master NI

  localparam int EP_X [NEP] = '{{ {', '.join(map(str, ex))} }};
  localparam int EP_Y [NEP] = '{{ {', '.join(map(str, ey))} }};
  localparam int EP_DIE [NEP] = '{{ {', '.join(map(str, ed))} }};

  // the endpoint a flit for endpoint d leaves the mesh of die `die` at: d
  // itself, or that die's die-to-die gateway when d is on another die
  function automatic int local_ep(int d, int die);
    return (NGW == 0 || EP_DIE[d] == die) ? d : NM + NS + die;
  endfunction

  function automatic string ep_name(int e);
    case (e)
{names}
      default: return "none";
    endcase
  endfunction

  // ---------------- CHI coherence ----------------
  localparam int HN_EP = NM + NS + NGW;           // the first HN-F endpoint
  localparam int HN_G = {int(math.log2(m.chi.granule)) if m.chi.rn else 12};                     // homes interleave on 2**HN_G bytes
  localparam int HN_K = {m.chi.hbits if m.chi.rn else 0};                      // log2(NHN)
  localparam bit CHI_DMT = 1'b{1 if m.chi.dmt else 0};             // memory data straight to the requester
  localparam bit CHI_DCT = 1'b{1 if m.chi.dct else 0};             // the owner forwards the line to the requester
  localparam int NRN = {len(m.chi.rn) if m.chi.rn else 1};                   // RN-F ports (protocol chi masters)
  localparam int RN_EP [NRN] = '{{ {rn_ep} }};
  localparam int CHI_LINES = {m.chi.lines or 4};            // RN-F cache lines (64-byte, direct-mapped)
  localparam bit S_COH [NS] = '{{ {coh} }};   // slave port inside the coherent memory

  // ---------------- address map: {P}::{m.prefix}_decode ----------------
  // the slave port that owns address a
  function automatic logic [EPB-1:0] decode_tgt(logic [31:0] a);
    int s = {P}::{m.prefix}_decode(a);
    return (s >= NS) ? EP_NONE : EPB'(NM + s);
  endfunction

  // coherent (cacheable) memory: the HN-F serves it
  function automatic logic cacheable(logic [31:0] a);
    int s = {P}::{m.prefix}_decode(a);
    return NHN != 0 && s < NS && S_COH[s];
  endfunction

  // the home of address a: granule-interleaved over the NHN homes, xor-folded
  function automatic logic [EPB-1:0] hn_ep(logic [31:0] a);
    logic [31:0] k;
    k = (HN_K == 0) ? 32'd0 : (((a >> HN_G) ^ (a >> (HN_G + HN_K))) & ((32'd1 << HN_K) - 1));
    return EPB'(HN_EP + int'(k));
  endfunction

  // where a master NI sends a chunk: the slave port, or the home for coherent memory
  function automatic logic [EPB-1:0] decode(logic [31:0] a);
    return cacheable(a) ? hn_ep(a) : decode_tgt(a);
  endfunction

  // ---------------- NI packet (flit payload) ----------------
  // OP_RD .. OP_WRSP: AMBA chunks (master NI <-> slave NI / HN-F); OP_C*: CHI
  // messages (RN-F <-> HN-F) on the REQ, SNP, RSP and DAT channels
  typedef enum logic [2:0] {{ OP_RD = 3'd0, OP_WR = 3'd1, OP_RDATA = 3'd2, OP_WRSP = 3'd3,
                             OP_CREQ = 3'd4, OP_CSNP = 3'd5, OP_CRSP = 3'd6, OP_CDAT = 3'd7 }} op_e;
  localparam int CW = 8;                  // 32-bit words per chunk
  localparam int TAGW = 6;                // master NI slot / burst tag

  typedef struct packed {{
    op_e               op;
    logic [EPB-1:0]    dst_ep;
    logic [EPB-1:0]    src_ep;
    logic [TAGW-1:0]   tag;
    logic [31:0]       addr;              // first word address (requests)
    logic [2:0]        nm1;               // words - 1
    logic [2:0]        size;              // AxSIZE of each word access (<= 2)
    logic              fixed;             // FIXED burst (else INCR)
    logic [2:0]        prot;
    logic [1:0]        resp;              // WRSP: BRESP; CHI RSP / DAT: RespErr
    logic [5:0]        copc;              // CHI opcode (REQ / SNP / RSP / DAT)
    logic [2:0]        cresp;             // CHI Resp (cache state)
    logic [TAGW-1:0]   dbid;              // CHI DBID
    logic [1:0]        dataid;            // CHI DataID: 0 / 2 = bytes 0..31 / 32..63 of the line
    logic [EPB-1:0]    hnid;              // CHI HomeNID: where the requester sends CompAck
    logic [EPB-1:0]    fwd;               // CHI FwdNID (DCT snoop; FwdTxnID in dbid)
    logic [CW-1:0][1:0]  rresp;           // RDATA: RRESP per word
    logic [CW-1:0][3:0]  strb;            // WR: WSTRB per word
    logic [CW-1:0][31:0] data;            // WR / RDATA
  }} pkt_t;
  localparam int PKT_W = $bits(pkt_t);

  // ---------------- CHI port (RN-F <-> NoC) ----------------
  // CHI Issue B/C fields, narrowed: node IDs are NoC endpoints (nid = SrcID on
  // RX, TgtID on TX; requests go to the address's home); 256-bit data (a
  // 64-byte line is two DAT flits, DataID 0 and 2); L-Credits replaced by
  // valid / ready on the RN-F's TX channels, and the RN-F always accepts on RX.
  typedef struct packed {{
    logic [TAGW-1:0] txnid;
    logic [5:0]      opcode;
    logic [31:0]     addr;
    logic [2:0]      size;
  }} chi_req_t;
  typedef struct packed {{
    logic [EPB-1:0]  nid;                 // SrcID (the home)
    logic [TAGW-1:0] txnid;
    logic [4:0]      opcode;
    logic [31:0]     addr;
    logic [EPB-1:0]  fwdnid;              // DCT: the requester to forward to
    logic [TAGW-1:0] fwdtxnid;
  }} chi_snp_t;
  typedef struct packed {{
    logic [EPB-1:0]  nid;                 // RX: SrcID, TX: TgtID
    logic [TAGW-1:0] txnid;
    logic [3:0]      opcode;
    logic [2:0]      resp;
    logic [1:0]      resperr;
    logic [TAGW-1:0] dbid;
  }} chi_rsp_t;
  typedef struct packed {{
    logic [EPB-1:0]  nid;                 // RX: SrcID, TX: TgtID
    logic [EPB-1:0]  homenid;             // CompData: the home that gets the CompAck
    logic [TAGW-1:0] txnid;
    logic [3:0]      opcode;
    logic [2:0]      resp;
    logic [1:0]      resperr;
    logic [1:0]      dataid;
    logic [31:0]     be;
    logic [255:0]    data;
  }} chi_dat_t;

  // opcodes (CHI Issue B)
  localparam logic [5:0] REQ_READSHARED = 6'h01, REQ_READNOSNP = 6'h04, REQ_READUNIQUE = 6'h07,
                         REQ_CLEANUNIQUE = 6'h0B, REQ_EVICT = 6'h0D, REQ_WRITEBACKFULL = 6'h1B,
                         REQ_WRITENOSNPPTL = 6'h1C;
  localparam logic [4:0] SNP_SHARED = 5'h01, SNP_UNIQUE = 5'h07, SNP_CLEANSHARED = 5'h08,
                         SNP_SHAREDFWD = 5'h11, SNP_UNIQUEFWD = 5'h17;
  localparam logic [3:0] RSP_SNPRESP = 4'h1, RSP_COMPACK = 4'h2, RSP_COMP = 4'h4,
                         RSP_COMPDBIDRESP = 4'h5, RSP_DBIDRESP = 4'h6, RSP_SNPRESPFWDED = 4'h9;
  localparam logic [3:0] DAT_SNPRESPDATA = 4'h1, DAT_COPYBACKWRDATA = 4'h2,
                         DAT_NONCOPYBACKWRDATA = 4'h3, DAT_COMPDATA = 4'h4, DAT_SNPRESPDATAFWDED = 4'h6;
  // Resp: cache state (Comp / CompData / CopyBackWrData: I, SC, UC, UD_PD;
  // SnpResp*: I, SC, UC, plus _PD = dirty data passed to the home)
  localparam logic [2:0] RESP_I = 3'd0, RESP_SC = 3'd1, RESP_UC = 3'd2, RESP_UD_PD = 3'd6,
                         RESP_I_PD = 3'd4, RESP_SC_PD = 3'd5, RESP_UC_PD = 3'd6;
  // RespErr
  localparam logic [1:0] RESPERR_OK = 2'b00, RESPERR_DERR = 2'b10, RESPERR_NDERR = 2'b11;

  function automatic noc_flit_t mk_flit(pkt_t p, int src, logic [1:0] vc);
    noc_flit_t f;
    f = '0;
    f.payload = PAYLOAD_W'(p);
    f.dest_x  = XB'(EP_X[local_ep(int'(p.dst_ep), EP_DIE[src])]);
    f.dest_y  = YB'(EP_Y[local_ep(int'(p.dst_ep), EP_DIE[src])]);
    f.src_x   = XB'(EP_X[src]);
    f.src_y   = YB'(EP_Y[src]);
    f.vc_id   = vc;
    f.ftype   = FT_SINGLE;
    f.valid   = 1'b1;
    return f;
  endfunction

  function automatic pkt_t pkt_of(noc_flit_t f);
    return pkt_t'(f.payload[PKT_W-1:0]);
  endfunction
endpackage
"""


def _ports(prefix, sigs, noc_is_master):
    """port declarations of one endpoint; noc_is_master: the NoC drives the "o" signals"""
    out = []
    for n, w, d in sigs:
        drives = (d == "o") == noc_is_master
        out.append(f"  {'output' if drives else 'input '} {_decl(w, f'{prefix}_{n}')}")
    return out


def noc_module(m):
    """<soc>_noc: named AMBA ports, adapters, NIs and the mesh"""
    p = params(m)
    ni = m.noc_ni
    hdr = [f"// SPDX-License-Identifier: Apache-2.0",
           "// " + "=" * 76,
           f"// {m.name}_noc -- generated by socgen (nocgen) from the {m.name} SoC spec",
           "// " + "-" * 76,
           f"// {m.noc.cols}x{m.noc.rows} mesh of {'xuanji-core orca_noc_router (+define+NOC_OPEN_ROUTER: noc_router_open)' if m.noc.router_ip == 'orca' else 'noc_router_open routers'},",
           f"// XY routing, {p['nm']} master ports, {p['ns']} slave ports. Every port is 32-bit data.",
           "// Master ports (the NoC is the slave):"]
    for x in m.masters:
        hdr.append(f"//   {x.name:<14} {PROTO_NAME[x.protocol]:<10} router [{x.node[0]}, {x.node[1]}]")
    hdr.append("// Slave ports (the NoC is the master):")
    for t in m.targets:
        hdr.append(f"//   {t.name:<14} {PROTO_NAME[t.protocol]:<10} router [{t.node[0]}, {t.node[1]}]"
                   f"  0x{t.base:08X}{' (interleaved)' if t.kind == 'channel' else ''}")
    hdr += ["// AXI4 IDs are ID_WIDTH bits; responses come back in order per master port.",
            "// AXI4-Lite, AHB-Lite and APB4 ports go through noc_axi2lite / noc_ahb2axi /",
            "// noc_axi2ahb / axi2apb_bridge in front of the network interface.",
            "// " + "=" * 76]
    L = hdr + [f"module {m.name}_noc", "  import noc_cfg_pkg::*;", "#(", "  parameter int ID_WIDTH = "
               f"{m.id_width}", ")(", "  input  logic clk,", "  input  logic rst_n,"]
    ports = []
    for x in m.masters:
        ports += [f"  // ---- master port {x.name}: {PROTO_NAME[x.protocol]} ----"] + \
            _ports(x.name, MST_SIGS[x.protocol], noc_is_master=False)
    for t in m.targets:
        ports += [f"  // ---- slave port {t.name}: {PROTO_NAME[t.protocol]} ----"] + \
            _ports(t.name, SLV_SIGS[t.protocol], noc_is_master=True)
    if p["ngw"]:
        ports += ["  // ---- die-to-die link status: d2d_up = both UCIe adapters ACTIVE; d2d_error = a",
                  "  // gateway queue overflowed or an adapter entered LINKERROR; d2d_flits = flits the",
                  "  // PHY model corrupted (+D2D_ERR_EVERY); d2d_replays = UCIe Retry replays ----",
                  "  output logic d2d_up", "  output logic d2d_error",
                  "  output logic [31:0] d2d_flits", "  output logic [31:0] d2d_replays"]
    # commas: every port line but the last gets one (comments excluded)
    idx = [i for i, s in enumerate(ports) if not s.lstrip().startswith("//")]
    for i in idx[:-1]:
        ports[i] += ","
    L += ports + [");", ""]
    L += ["  noc_flit_t inj_flit [NEP], ej_flit [NEP];",
          "  logic      inj_valid [NEP], inj_ready [NEP], ej_valid [NEP], ej_ready [NEP];", ""]
    if not p["ngw"]:
        L += ["  logic      busy;",
              f"  noc_mesh #(.NUM_VC({m.noc.num_vc}), .BUF_DEPTH({m.noc.buf_depth})) u_mesh (",
              "    .clk, .rst_n, .inj_flit, .inj_valid, .inj_ready, .ej_flit, .ej_valid, .ej_ready, .busy);", ""]
    else:
        L += _chiplet(m, p)
    axi_names = [n for n, _, _ in AXI4]
    for i, x in enumerate(m.masters):
        a = f"{x.name}_ax"          # AXI4 wires between the adapter and the NI
        L.append(f"  // ---------------- master {i}: {x.name} ({PROTO_NAME[x.protocol]}) ----------------")
        if x.protocol == "chi":
            L.append(f"  noc_ni_chi #(.SELF({i})) u_ni_{x.name} (.clk, .rst_n,")
            L.append("    " + ", ".join(f".{n}({x.name}_{n})" for n, _, _ in CHI) + ",")
            L.append(f"    .inj_flit(inj_flit[{i}]), .inj_valid(inj_valid[{i}]), .inj_ready(inj_ready[{i}]),")
            L.append(f"    .ej_flit(ej_flit[{i}]), .ej_valid(ej_valid[{i}]), .ej_ready(ej_ready[{i}]));")
            L.append("")
            continue
        if x.protocol == "axi4":
            conn = {n: f"{x.name}_{n}" for n in axi_names}
        else:
            for n, w, _ in AXI4:
                L.append(f"  logic {_w(w)}{a}_{n};")
            conn = {n: f"{a}_{n}" for n in axi_names}
            if x.protocol == "axi4lite":
                for n, _, d in LITE:
                    L.append(f"  assign {a}_{n} = {x.name}_{n};" if d == "o" else f"  assign {x.name}_{n} = {a}_{n};")
                L += [f"  assign {a}_awid = '0;", f"  assign {a}_awlen = 8'd0;", f"  assign {a}_awsize = 3'd2;",
                      f"  assign {a}_awburst = 2'b01;", f"  assign {a}_wlast = 1'b1;", f"  assign {a}_arid = '0;",
                      f"  assign {a}_arlen = 8'd0;", f"  assign {a}_arsize = 3'd2;", f"  assign {a}_arburst = 2'b01;"]
            else:   # ahb
                L.append(f"  noc_ahb2axi #(.IDW(ID_WIDTH)) u_{x.name}_ahb (.clk, .rst_n,")
                L.append("    " + ", ".join(f".{n}({x.name}_{n})" for n, _, _ in AHB_MST) + ",")
                L.append("    " + ", ".join(f".m_{n}({a}_{n})" for n in axi_names) + ");")
        L.append(f"  noc_ni_mst #(.SELF({i}), .DW(32), .IDW(ID_WIDTH), .MAXB({ni.maxb}), .MAXO({ni.maxo})) u_ni_{x.name} (")
        L.append("    .clk, .rst_n,")
        L.append("    " + ", ".join(f".s_{n}({conn[n]})" for n in axi_names) + ",")
        L.append(f"    .inj_flit(inj_flit[{i}]), .inj_valid(inj_valid[{i}]), .inj_ready(inj_ready[{i}]),")
        L.append(f"    .ej_flit(ej_flit[{i}]), .ej_valid(ej_valid[{i}]), .ej_ready(ej_ready[{i}]));")
        L.append("")
    for j, t in enumerate(m.targets):
        e = p["nm"] + j
        a = f"{t.name}_ax"
        L.append(f"  // ---------------- slave port {j}: {t.name} ({PROTO_NAME[t.protocol]}) ----------------")
        if t.protocol == "axi4":
            conn = {n: f"{t.name}_{n}" for n in axi_names}
        else:
            for n, w, _ in AXI4:
                L.append(f"  logic {_w(w)}{a}_{n};")
            conn = {n: f"{a}_{n}" for n in axi_names}
            s_conn = ", ".join(f".s_{n}({a}_{n})" for n in axi_names)
            if t.protocol == "axi4lite":
                L.append(f"  noc_axi2lite #(.IDW(ID_WIDTH)) u_{t.name}_lite (.clk, .rst_n,")
                L.append(f"    {s_conn},")
                L.append("    " + ", ".join(f".m_{n}({t.name}_{n})" for n, _, _ in LITE) + ");")
            elif t.protocol == "ahb":
                L.append(f"  assign {t.name}_hsel = 1'b1;")
                L.append(f"  noc_axi2ahb #(.IDW(ID_WIDTH)) u_{t.name}_ahb (.clk, .rst_n,")
                L.append(f"    {s_conn},")
                L.append("    " + ", ".join(f".{n}({t.name}_{n})" for n, _, _ in AHB_SLV if n != "hsel") + ");")
            else:   # apb
                L.append(f"  axi2apb_bridge #(.IDW(ID_WIDTH)) u_{t.name}_apb (.clk, .rst_n,")
                L.append("    " + ", ".join(f".{n}({a}_{n})" for n in axi_names) + ",")
                L.append("    " + ", ".join(f".{n}({t.name}_{n})" for n, _, _ in APB) + ");")
        # the slave NI issues ID 0 and ignores BID / RID
        L.append(f"  noc_ni_slv #(.SELF({e}), .QD({p['qd']}), .OUTS({ni.outs}), .IDW(ID_WIDTH)) u_ni_{t.name} (")
        L.append("    .clk, .rst_n,")
        L.append("    " + ", ".join(f".m_{n}({conn[n]})" for n in axi_names if n not in ("bid", "rid")) + ",")
        L.append(f"    .inj_flit(inj_flit[{e}]), .inj_valid(inj_valid[{e}]), .inj_ready(inj_ready[{e}]),")
        L.append(f"    .ej_flit(ej_flit[{e}]), .ej_valid(ej_valid[{e}]), .ej_ready(ej_ready[{e}]));")
        L.append("")
    for k, hm in enumerate(m.chi.homes if p["nhn"] else []):
        h = f"HN_EP + {k}"
        L += [f"  // ---------------- CHI home node {k} (HN-F) on router {list(hm.node)}"
              f"{f', die {hm.die}' if m.chiplet.dies > 1 else ''}: coherent {', '.join(m.chi.coherent)} ----------------",
              f"  logic hnf{k}_overflow;",
              f"  noc_hnf #(.SELF({h}), .QD({p['hq']}), .NL(CHI_LINES)) u_hnf{k} (.clk, .rst_n,",
              f"    .inj_flit(inj_flit[{h}]), .inj_valid(inj_valid[{h}]), .inj_ready(inj_ready[{h}]),",
              f"    .ej_flit(ej_flit[{h}]), .ej_valid(ej_valid[{h}]), .ej_ready(ej_ready[{h}]),",
              f"    .overflow(hnf{k}_overflow));", ""]
    L.append("endmodule")
    return "\n".join(L) + "\n"


def _chiplet(m, p):
    """one mesh per die, a gateway + UCIe adapter per die, the PHY model between them"""
    # every packet that can be in flight: the master NIs' chunks, plus CHI
    # (per RN-F a request, write data and a CompAck; per home one snoop per
    # RN-F with up to four data flits and a response each, and its CompData /
    # DMT reads)
    nrn, nhn = len(m.chi.rn), p["nhn"]
    chi = 4 * nrn + nhn * (6 * nrn + 8) if nhn else 0
    qd = 2 * p["nm"] * m.noc_ni.maxo + chi
    nd = m.chiplet.dies
    L = [f"  // ---------------- chiplet: {nd} dies, one mesh each, UCIe die-to-die link ----------------"]
    for d in range(nd):
        L += [f"  noc_flit_t ej_flit_d{d} [NEP];",
              f"  logic      ej_valid_d{d} [NEP], inj_ready_d{d} [NEP], busy_d{d};",
              f"  noc_mesh #(.NUM_VC({m.noc.num_vc}), .BUF_DEPTH({m.noc.buf_depth}), .DIE({d})) u_mesh_d{d} (",
              f"    .clk, .rst_n, .inj_flit, .inj_valid, .inj_ready(inj_ready_d{d}), .ej_flit(ej_flit_d{d}),",
              f"    .ej_valid(ej_valid_d{d}), .ej_ready, .busy(busy_d{d}));"]
    L += ["  for (genvar e = 0; e < NEP; e++) begin : g_die"]
    for d in range(nd):
        kw = "if" if d == 0 else ("end else begin" if d == nd - 1 else "end else if")
        cond = f" (EP_DIE[e] == {d}) begin : g_d{d}" if d < nd - 1 else f" : g_d{d}"
        L.append(f"    {kw}{cond}" if d < nd - 1 else f"    {kw}{cond}")
        L += [f"      assign inj_ready[e] = inj_ready_d{d}[e];",
              f"      assign ej_flit[e]   = ej_flit_d{d}[e];",
              f"      assign ej_valid[e]  = ej_valid_d{d}[e];"]
    L += ["    end", "  end", ""]
    L += [f"  logic         lt_v [{nd}], lr_v [{nd}], sbt_v [{nd}], sbr_v [{nd}], tx_v [{nd}], tx_r [{nd}], rx_v [{nd}];",
          f"  logic [543:0] lt_f [{nd}], lr_f [{nd}];",
          f"  logic [15:0]  sbt_m [{nd}], sbr_m [{nd}];",
          f"  logic [511:0] tx_d [{nd}], rx_d [{nd}];",
          f"  logic [2:0]   lstate [{nd}];",
          f"  logic         gw_ovf [{nd}], lerr [{nd}], replay [{nd}];",
          f"  logic [31:0]  n_replay;"]
    for d in range(nd):
        e = f"NM + NS + {d}"
        L += [f"  // die {d}: gateway on router {list(m.chiplet.gateways[d])}",
              f"  noc_d2d_gw #(.SELF({e}), .QD({qd})) u_gw{d} (.clk, .rst_n,",
              f"    .inj_flit(inj_flit[{e}]), .inj_valid(inj_valid[{e}]), .inj_ready(inj_ready[{e}]),",
              f"    .ej_flit(ej_flit[{e}]), .ej_valid(ej_valid[{e}]), .ej_ready(ej_ready[{e}]),",
              f"    .tx_valid(tx_v[{d}]), .tx_data(tx_d[{d}]), .tx_ready(tx_r[{d}]), .rx_valid(rx_v[{d}]), .rx_data(rx_d[{d}]),",
              f"    .overflow(gw_ovf[{d}]), .tx_level(), .rx_level());",
              f"  UCIe_top u_ucie{d} (.clk, .rst_n, .link_en(1'b1), .cfg_retry(1'b{1 if m.chiplet.retry else 0}), "
              f".cfg_stack1(1'b0), .cfg_l1_ok(1'b0), .pm_req(1'b0),",
              f"    .tx_valid(tx_v[{d}]), .tx_stack(1'b0), .tx_data(tx_d[{d}]), .tx_ready(tx_r[{d}]),",
              f"    .rx_valid(rx_v[{d}]), .rx_stack(), .rx_data(rx_d[{d}]),",
              f"    .phy_up(1'b1), .lp_retrain(), .lt_valid(lt_v[{d}]), .lt_flit(lt_f[{d}]), "
              f".lr_valid(lr_v[{d}]), .lr_flit(lr_f[{d}]),",
              f"    .sb_tx_valid(sbt_v[{d}]), .sb_tx_msg(sbt_m[{d}]), .sb_rx_valid(sbr_v[{d}]), .sb_rx_msg(sbr_m[{d}]),",
              f"    .state(lstate[{d}]), .cap(), .tx_pend(), .ev_crc(), .ev_replay(replay[{d}]), .ev_retrain(),",
              f"    .ev_pmnak(), .ev_proto(), .ev_lerr(lerr[{d}]));"]
    L += [f"  noc_d2d_phy #(.DELAY({max(1, m.chiplet.phy_cycles)})) u_phy (.clk, .rst_n,",
          "    .a_lt_valid(lt_v[0]), .a_lt_flit(lt_f[0]), .a_lr_valid(lr_v[0]), .a_lr_flit(lr_f[0]),",
          "    .a_sb_tx_valid(sbt_v[0]), .a_sb_tx_msg(sbt_m[0]), .a_sb_rx_valid(sbr_v[0]), .a_sb_rx_msg(sbr_m[0]),",
          "    .b_lt_valid(lt_v[1]), .b_lt_flit(lt_f[1]), .b_lr_valid(lr_v[1]), .b_lr_flit(lr_f[1]),",
          "    .b_sb_tx_valid(sbt_v[1]), .b_sb_tx_msg(sbt_m[1]), .b_sb_rx_valid(sbr_v[1]), .b_sb_rx_msg(sbr_m[1]),",
          "    .n_err(d2d_flits));",
          "  assign d2d_up = (lstate[0] == 3'd3) && (lstate[1] == 3'd3);   // ACTIVE",
          "  logic err_q;",
          "  always_ff @(posedge clk or negedge rst_n)",
          "    if (!rst_n) begin err_q <= 1'b0; n_replay <= '0; end",
          "    else begin",
          "      if (gw_ovf[0] || gw_ovf[1] || lerr[0] || lerr[1]) err_q <= 1'b1;",
          "      n_replay <= n_replay + 32'(replay[0]) + 32'(replay[1]);",
          "    end",
          "  assign d2d_error = err_q;",
          "  assign d2d_replays = n_replay;", ""]
    return L


def tb_hookup(m):
    """tb_top text: the <soc>_noc instance between the VIP ports m_if / s_if"""
    L = ["  // ---------------- the generated NoC (noc.model: mesh) ----------------"]
    conns = []
    for x in m.masters:
        M = f"m_if[M_{x.name.upper()}]"
        if x.protocol == "axi4":
            for n, w, _ in AXI4:
                conns.append(f".{x.name}_{n}({M}.{n}{'[ID_WIDTH-1:0]' if w == 'IDW' else ''})")
            L += [f"  assign {M}.bid[7:ID_WIDTH] = '0;", f"  assign {M}.rid[7:ID_WIDTH] = '0;"]
            continue
        # test shim: the AXI4 VIP drives the port through an AXI4 -> <protocol> converter
        sh = f"{x.name}_shim"
        sigs = MST_SIGS[x.protocol]
        for n, w, _ in sigs:
            L.append(f"  {_decl(w, f'{sh}_{n}', 'noc_cfg_pkg::')};")
        vip = ", ".join(f".s_{n}({M}.{n}{'[ID_WIDTH-1:0]' if w == 'IDW' else ''})" for n, w, _ in AXI4)
        if x.protocol == "chi":
            # RN-F: the VIP is the CPU, noc_chi_rnf its cache and CHI interface
            L.append(f"  noc_chi_rnf #(.IDW(ID_WIDTH)) u_{x.name}_shim (.clk({m.clock.name}), .rst_n(aresetn),")
            L.append(f"    {vip},")
            L.append("    " + ", ".join(f".{n}({sh}_{n})" for n, _, _ in CHI) + ");")
        elif x.protocol == "axi4lite":
            L.append(f"  noc_axi2lite #(.IDW(ID_WIDTH)) u_{x.name}_shim (.clk({m.clock.name}), .rst_n(aresetn),")
            L.append(f"    {vip},")
            L.append("    " + ", ".join(f".m_{n}({sh}_{n})" for n, _, _ in LITE) + ");")
        else:
            L.append(f"  noc_axi2ahb #(.IDW(ID_WIDTH)) u_{x.name}_shim (.clk({m.clock.name}), .rst_n(aresetn),")
            L.append(f"    {vip},")
            L.append("    " + ", ".join(f".{n}({sh}_{n})" for n, _, _ in AHB_SLV if n != "hsel") + ");")
            # the shim is the port's only AHB master: HREADY = the NoC's HREADYOUT
            L += [f"  assign {sh}_hsel = 1'b1;", f"  assign {sh}_hready = {sh}_hreadyout;"]
        L += [f"  assign {M}.bid[7:ID_WIDTH] = '0;", f"  assign {M}.rid[7:ID_WIDTH] = '0;"]
        for n, _, _ in sigs:
            conns.append(f".{x.name}_{n}({sh}_{n})")
    for t in m.targets:
        S = f"s_if[S_{t.name.upper()}]"
        if t.protocol == "axi4":
            for n, w, _ in AXI4:
                conns.append(f".{t.name}_{n}({S}.{n}{'[ID_WIDTH-1:0]' if w == 'IDW' else ''})")
            L += [f"  assign {S}.awid[7:ID_WIDTH] = '0;", f"  assign {S}.arid[7:ID_WIDTH] = '0;"]
            L += [f"  assign {S}.awlock = 1'b0;", f"  assign {S}.arlock = 1'b0;",
                  f"  assign {S}.awcache = 4'h0;", f"  assign {S}.arcache = 4'h0;"]
            continue
        sh = f"{t.name}_shim"
        sigs = SLV_SIGS[t.protocol]
        for n, w, _ in sigs:
            L.append(f"  logic {_w(w)}{sh}_{n};")
        vip = ", ".join(f".m_{n}({S}.{n}{'[ID_WIDTH-1:0]' if w == 'IDW' else ''})" for n, w, _ in AXI4)
        if t.protocol == "axi4lite":
            # AXI4-Lite master -> AXI4 slave VIP: single beats, ID 0
            for n, w, d in LITE:
                L.append(f"  assign {S}.{n} = {sh}_{n};" if d == "o" else f"  assign {sh}_{n} = {S}.{n};")
            L += [f"  assign {S}.awid = '0;", f"  assign {S}.awlen = 8'd0;", f"  assign {S}.awsize = 3'd2;",
                  f"  assign {S}.awburst = 2'b01;", f"  assign {S}.wlast = 1'b1;", f"  assign {S}.arid = '0;",
                  f"  assign {S}.arlen = 8'd0;", f"  assign {S}.arsize = 3'd2;", f"  assign {S}.arburst = 2'b01;"]
        elif t.protocol == "ahb":
            L.append(f"  noc_ahb2axi #(.IDW(ID_WIDTH)) u_{t.name}_shim (.clk({m.clock.name}), .rst_n(aresetn),")
            L.append(f"    .hsel({sh}_hsel), .haddr({sh}_haddr), .htrans({sh}_htrans), .hwrite({sh}_hwrite),"
                     f" .hsize({sh}_hsize), .hburst({sh}_hburst), .hprot({sh}_hprot), .hwdata({sh}_hwdata),")
            L.append(f"    .hready({sh}_hready), .hrdata({sh}_hrdata), .hreadyout({sh}_hready), .hresp({sh}_hresp),")
            L.append(f"    {vip});")
            L += [f"  assign {S}.awid[7:ID_WIDTH] = '0;", f"  assign {S}.arid[7:ID_WIDTH] = '0;"]
        else:   # apb
            L.append(f"  noc_apb2axi #(.IDW(ID_WIDTH)) u_{t.name}_shim (.clk({m.clock.name}), .rst_n(aresetn),")
            L.append("    " + ", ".join(f".{n}({sh}_{n})" for n, _, _ in APB) + ",")
            L.append(f"    {vip});")
            L += [f"  assign {S}.awid[7:ID_WIDTH] = '0;", f"  assign {S}.arid[7:ID_WIDTH] = '0;"]
        L += [f"  assign {S}.awlock = 1'b0;", f"  assign {S}.arlock = 1'b0;",
              f"  assign {S}.awcache = 4'h0;", f"  assign {S}.arcache = 4'h0;"]
        for n, _, _ in sigs:
            conns.append(f".{t.name}_{n}({sh}_{n})")
    if m.chiplet.dies > 1:
        conns += [".d2d_up(d2d_up)", ".d2d_error(d2d_error)", ".d2d_flits(d2d_flits)", ".d2d_replays(d2d_replays)"]
    L.append(f"  {m.name}_noc u_noc (.clk({m.clock.name}), .rst_n(aresetn),")
    L.append(",\n".join(f"    {c}" for c in conns))
    L.append("  );")
    return "\n".join(L) + "\n"
