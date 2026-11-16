// sdc_model: cut by socgen from open-vip SD_Card-UVM-VIP tb/top_tb.sv
module sdc_model #(
  parameter int          NCR   = 2,
  parameter int          NAC   = 2,
  parameter int          BUSY  = 4,
  parameter int          POLLS = 1,
  parameter bit          HC    = 1'b1,
  parameter logic [15:0] RCA   = 16'h1234
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       sd_clk,
  input  logic       cmd_m,
  input  logic       cmd_m_oe,
  input  logic [3:0] dat_m,
  input  logic       dat_m_oe,
  output logic       cmd_s,
  output logic       cmd_s_oe,
  output logic [3:0] dat_s,
  output logic [3:0] dat_s_oe
);
  localparam logic [119:0] CID_BODY = 120'h1D4F565344433110123456780016A0;
  localparam logic [3:0] D_NONE = 4'd0, D_WWAIT = 4'd1, D_WDATA = 4'd2, D_WCRC = 4'd3, D_WEND = 4'd4,
                         D_TOK = 4'd5, D_RPEND = 4'd7, D_RWAIT = 4'd8, D_RDATA = 4'd9, D_RCRC = 4'd10,
                         D_REND = 4'd11, D_RREL = 4'd12;
  function automatic logic [6:0] crc7(input logic [119:0] d, input integer n);
    logic [6:0] c;
    logic fb;
    c = 7'h00;
    for (int i = 119; i >= 0; i--) if (i < n) begin
      fb = d[i] ^ c[6];
      c = {c[5:0], 1'b0};
      if (fb) c = c ^ 7'h09;
    end
    crc7 = c;
  endfunction
  function automatic logic [15:0] crc16(input logic [15:0] c, input logic b);
    crc16 = {c[14:0], 1'b0} ^ ((b ^ c[15]) ? 16'h1021 : 16'h0000);
  endfunction
  function automatic logic [47:0] rframe(input logic [5:0] i, input logic [31:0] a);
    logic [39:0] b;
    b = {2'b00, i, a};
    rframe = {b, crc7({80'h0, b}, 40), 1'b1};
  endfunction

  logic [255:0] mem [0:15];
  logic [2:0]   cst;
  logic [3:0]   polls, dm, blk;
  logic         app, crc_e, ill, ccs;
  logic [15:0]  rca;
  logic [5:0]   rxc;
  logic [47:0]  rxs;
  logic [7:0]   txn;
  logic [6:0]   txd;
  logic [135:0] txs;
  logic [255:0] buff;
  logic [15:0]  c0, c1, c2, c3, r0, r1, r2, r3;
  logic [6:0]   dcnt;
  logic [6:0]   rdd, tokd;
  logic [2:0]   tokn;
  logic [4:0]   tok;
  logic [7:0]   busyn;
  logic         n_cmd, n_cmd_oe;
  logic [3:0]   n_dat, n_dat_oe;
  wire          cl = cmd_m_oe ? cmd_m : (cmd_s_oe ? cmd_s : 1'b1);
  wire  [3:0]   dl = dat_m_oe ? dat_m : ((dat_s_oe & dat_s) | ~dat_s_oe);
  wire          _unused = &{1'b0, clk};

  // rising sd_clk: receive, run the card, decide the next outputs
  always_ff @(posedge sd_clk or negedge rst_n) begin
    if (!rst_n) begin
      cst <= '0; polls <= '0; dm <= D_NONE; blk <= '0; app <= 1'b0; crc_e <= 1'b0; ill <= 1'b0; ccs <= 1'b0;
      rca <= '0; rxc <= '0; rxs <= '0; txn <= '0; txd <= '0; txs <= '0; buff <= '0;
      c0 <= '0; c1 <= '0; c2 <= '0; c3 <= '0; r0 <= '0; r1 <= '0; r2 <= '0; r3 <= '0;
      dcnt <= '0; rdd <= '0; tokd <= '0; tokn <= '0; tok <= '0; busyn <= '0;
      n_cmd <= 1'b0; n_cmd_oe <= 1'b0; n_dat <= 4'h0; n_dat_oe <= 4'h0;
      for (int b = 0; b < 16; b++)
        for (int i = 0; i < 32; i++) mem[b][255 - 8 * i -: 8] <= 8'((16 * b + i) ^ 8'h3C);
    end else begin : step
      logic [2:0]   v_cst;
      logic [3:0]   v_polls, v_dm, v_blk;
      logic         v_app, v_crc_e, v_ill, v_ccs;
      logic [15:0]  v_rca;
      logic [5:0]   v_rxc;
      logic [47:0]  v_rxs, f;
      logic [7:0]   v_txn;
      logic [6:0]   v_txd;
      logic [135:0] v_txs;
      logic [255:0] v_buff;
      logic [15:0]  v0, v1, v2, v3;
      logic [6:0]   v_dcnt, v_rdd, v_tokd;
      logic [2:0]   v_tokn;
      logic [4:0]   v_tok;
      logic [7:0]   v_busyn;
      logic [3:0]   nib;
      logic         go, good, wa, rdy;
      logic [2:0]   st;
      logic [5:0]   i;
      logic [31:0]  a;
      logic [127:0] cid;
      v_cst = cst; v_polls = polls; v_dm = dm; v_blk = blk; v_app = app; v_crc_e = crc_e; v_ill = ill;
      v_ccs = ccs; v_rca = rca; v_rxc = rxc; v_rxs = rxs; v_txn = txn; v_txd = txd; v_txs = txs;
      v_buff = buff; v0 = c0; v1 = c1; v2 = c2; v3 = c3; v_dcnt = dcnt; v_rdd = rdd; v_tokd = tokd;
      v_tokn = tokn; v_tok = tok; v_busyn = busyn;
      go = 1'b0; f = '0;
      // command receiver
      if (v_txd == 0 && v_txn == 0) begin
        if (v_rxc == 0) begin if (!cl) begin v_rxc = 6'd1; v_rxs = '0; end end
        else begin
          v_rxs = {v_rxs[46:0], cl};
          v_rxc = v_rxc + 6'd1;
          if (v_rxc == 6'd48) begin v_rxc = '0; go = 1'b1; f = v_rxs; end
        end
      end
      if (go) begin
        i = f[45:40]; a = f[39:8]; st = v_cst; wa = v_app;
        if (crc7({80'h0, f[47:8]}, 40) != f[7:1] || !f[0] || !f[46]) v_crc_e = 1'b1;
        else begin
          v_app = 1'b0;
          if (i == 6'd0) begin v_cst = 3'd0; v_polls = '0; v_ccs = 1'b0; v_rca = '0; v_dm = D_NONE; end
          else if (i == 6'd8 && v_cst == 3'd0) begin
            if (a[11:8] == 4'h1) begin v_txs = {rframe(6'd8, {20'h0, a[11:0]}), 88'h0}; v_txn = 8'd48; v_txd = 7'(NCR - 1); end
          end else if (i == 6'd55 && v_cst != 3'd2) begin
            v_app = 1'b1;
            v_txs = {rframe(6'd55, {8'h00, v_crc_e, v_ill, 9'h000, 1'b0, st, 1'b1, 2'b00, 1'b1, 5'h00}), 88'h0};
            v_txn = 8'd48; v_txd = 7'(NCR - 1); v_crc_e = 1'b0; v_ill = 1'b0;
          end else if (i == 6'd41 && wa && (v_cst == 3'd0 || v_cst == 3'd1)) begin
            rdy = v_polls >= 4'(POLLS);
            if (v_polls != 4'd15) v_polls = v_polls + 4'd1;
            if (rdy) begin v_cst = 3'd1; v_ccs = HC && a[30]; end
            v_txs = {2'b00, 6'h3F, rdy, rdy && HC && a[30], 6'h00, 24'hFF8000, 8'hFF, 88'h0};
            v_txn = 8'd48; v_txd = 7'(NCR - 1);
          end else if (i == 6'd2 && v_cst == 3'd1) begin
            cid = {CID_BODY, crc7(CID_BODY, 120), 1'b1};
            v_cst = 3'd2; v_txs = {2'b00, 6'h3F, cid[127:1], 1'b1}; v_txn = 8'd136; v_txd = 7'(NCR - 1);
          end else if (i == 6'd3 && (v_cst == 3'd2 || v_cst == 3'd3)) begin
            v_cst = 3'd3; v_rca = RCA;
            v_txs = {rframe(6'd3, {RCA, v_crc_e, v_ill, 1'b0, 1'b0, st, 1'b1, 2'b00, 1'b0, 5'h00}), 88'h0};
            v_txn = 8'd48; v_txd = 7'(NCR - 1); v_crc_e = 1'b0; v_ill = 1'b0;
          end else if (i == 6'd7 && (v_cst == 3'd3 || v_cst == 3'd4)) begin
            if (a[31:16] == v_rca && v_rca != 16'h0) begin
              v_cst = 3'd4;
              v_txs = {rframe(6'd7, {8'h00, v_crc_e, v_ill, 9'h000, 1'b0, st, 1'b1, 2'b00, 1'b0, 5'h00}), 88'h0};
              v_txn = 8'd48; v_txd = 7'(NCR - 1); v_crc_e = 1'b0; v_ill = 1'b0;
            end else if (v_cst == 3'd4) v_cst = 3'd3;
          end else if (i == 6'd13 && (v_cst == 3'd3 || v_cst == 3'd4)) begin
            if (a[31:16] == v_rca) begin
              v_txs = {rframe(6'd13, {8'h00, v_crc_e, v_ill, 9'h000, 1'b0, st, 1'b1, 2'b00, 1'b0, 5'h00}), 88'h0};
              v_txn = 8'd48; v_txd = 7'(NCR - 1); v_crc_e = 1'b0; v_ill = 1'b0;
            end
          end else if ((i == 6'd17 || i == 6'd24) && v_cst == 3'd4) begin
            v_txs = {rframe(i, {8'h00, v_crc_e, v_ill, 9'h000, 1'b0, st, 1'b1, 2'b00, 1'b0, 5'h00}), 88'h0};
            v_txn = 8'd48; v_txd = 7'(NCR - 1); v_crc_e = 1'b0; v_ill = 1'b0;
            v_blk = v_ccs ? a[3:0] : a[8:5];
            if (i == 6'd17) begin v_dm = D_RPEND; v_buff = mem[v_blk]; end
            else v_dm = D_WWAIT;
          end else v_ill = 1'b1;
        end
      end
      // write block receiver
      case (v_dm)
        D_WWAIT: if (dl == 4'h0) begin v_dm = D_WDATA; v_dcnt = '0; v0 = '0; v1 = '0; v2 = '0; v3 = '0; end
        D_WDATA: begin
          v_buff = {v_buff[251:0], dl};
          v0 = crc16(v0, dl[0]); v1 = crc16(v1, dl[1]); v2 = crc16(v2, dl[2]); v3 = crc16(v3, dl[3]);
          v_dcnt = v_dcnt + 7'd1;
          if (v_dcnt == 7'd64) begin v_dm = D_WCRC; v_dcnt = '0; r0 <= '0; r1 <= '0; r2 <= '0; r3 <= '0; end
        end
        D_WCRC: begin
          r0 <= {r0[14:0], dl[0]}; r1 <= {r1[14:0], dl[1]}; r2 <= {r2[14:0], dl[2]}; r3 <= {r3[14:0], dl[3]};
          v_dcnt = v_dcnt + 7'd1;
          if (v_dcnt == 7'd16) v_dm = D_WEND;
        end
        D_WEND: begin
          good = dl == 4'hF && r0 == v0 && r1 == v1 && r2 == v2 && r3 == v3;
          if (good) mem[v_blk] <= v_buff;
          v_tok = good ? 5'b0_010_1 : 5'b0_101_1;
          v_dm = D_TOK; v_tokd = 7'd1; v_tokn = 3'd5; v_busyn = good ? 8'(BUSY) : 8'd0;
        end
        default: ;
      endcase
      // outputs for the next period
      if (v_txd != 0) begin v_txd = v_txd - 7'd1; n_cmd_oe <= 1'b0; end
      else if (v_txn != 0) begin
        n_cmd_oe <= 1'b1; n_cmd <= v_txs[135]; v_txs = v_txs << 1; v_txn = v_txn - 8'd1;
        if (v_txn == 0 && v_dm == D_RPEND) begin v_dm = D_RWAIT; v_rdd = 7'(NAC); end
      end else n_cmd_oe <= 1'b0;
      case (v_dm)
        D_TOK:
          if (v_tokd != 0) begin v_tokd = v_tokd - 7'd1; n_dat_oe <= 4'h0; end
          else if (v_tokn != 0) begin n_dat_oe <= 4'b0001; n_dat <= {3'b000, v_tok[4]}; v_tok = v_tok << 1; v_tokn = v_tokn - 3'd1; end
          else if (v_busyn != 0) begin n_dat_oe <= 4'b0001; n_dat <= 4'h0; v_busyn = v_busyn - 8'd1; end
          else begin n_dat_oe <= 4'h0; v_dm = D_NONE; end
        D_RWAIT:
          if (v_rdd != 0) begin v_rdd = v_rdd - 7'd1; n_dat_oe <= 4'h0; end
          else begin n_dat_oe <= 4'hF; n_dat <= 4'h0; v_dm = D_RDATA; v_dcnt = '0; v0 = '0; v1 = '0; v2 = '0; v3 = '0; end
        D_RDATA: begin
          nib = v_buff[255 - 4 * v_dcnt -: 4];
          n_dat_oe <= 4'hF; n_dat <= nib;
          v0 = crc16(v0, nib[0]); v1 = crc16(v1, nib[1]); v2 = crc16(v2, nib[2]); v3 = crc16(v3, nib[3]);
          v_dcnt = v_dcnt + 7'd1;
          if (v_dcnt == 7'd64) begin v_dm = D_RCRC; v_dcnt = '0; end
        end
        D_RCRC: begin
          n_dat_oe <= 4'hF; n_dat <= {v3[15], v2[15], v1[15], v0[15]};
          v0 = v0 << 1; v1 = v1 << 1; v2 = v2 << 1; v3 = v3 << 1;
          v_dcnt = v_dcnt + 7'd1;
          if (v_dcnt == 7'd16) v_dm = D_REND;
        end
        D_REND: begin n_dat_oe <= 4'hF; n_dat <= 4'hF; v_dm = D_RREL; end
        D_RREL: begin n_dat_oe <= 4'h0; v_dm = D_NONE; end
        default: n_dat_oe <= 4'h0;
      endcase
      cst <= v_cst; polls <= v_polls; dm <= v_dm; blk <= v_blk; app <= v_app; crc_e <= v_crc_e; ill <= v_ill;
      ccs <= v_ccs; rca <= v_rca; rxc <= v_rxc; rxs <= v_rxs; txn <= v_txn; txd <= v_txd; txs <= v_txs;
      buff <= v_buff; c0 <= v0; c1 <= v1; c2 <= v2; c3 <= v3; dcnt <= v_dcnt; rdd <= v_rdd; tokd <= v_tokd;
      tokn <= v_tokn; tok <= v_tok; busyn <= v_busyn;
    end
  end

  // falling sd_clk: the outputs change
  always_ff @(negedge sd_clk or negedge rst_n) begin
    if (!rst_n) begin
      cmd_s <= 1'b0; cmd_s_oe <= 1'b0; dat_s <= 4'h0; dat_s_oe <= 4'h0;
    end else begin
      cmd_s <= n_cmd; cmd_s_oe <= n_cmd_oe; dat_s <= n_dat; dat_s_oe <= n_dat_oe;
    end
  end
endmodule
