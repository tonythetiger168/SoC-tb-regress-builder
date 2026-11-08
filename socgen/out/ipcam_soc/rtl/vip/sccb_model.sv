// sccb_model: cut by socgen from open-vip SCCB_Sensor-UVM-VIP tb/top_tb.sv
module sccb_model #(parameter logic [6:0] ADDR = 7'h3C) (
  input  logic clk,
  input  logic rst_n,
  input  logic scl,
  input  logic sda_m_lo,
  output logic sda_s_lo
);
  localparam logic [2:0] S_IDLE = 3'd0, S_ADDR = 3'd1, S_WR = 3'd2, S_RD = 3'd3, S_IGN = 3'd4;
  logic [2:0]  st;
  logic [3:0]  p;
  logic [1:0]  wb;
  logic [7:0]  sh, txb, hi;
  logic [15:0] ptr;
  logic        ack, rw;
  logic [7:0]  regs [0:511];
  logic        scl_s, scl_d, sda_s, sda_d;
  wire         line  = !(sda_m_lo || sda_s_lo);
  wire         rise  = scl_s && !scl_d;
  wire         fall  = !scl_s && scl_d;
  wire         start = scl_s && scl_d && sda_d && !sda_s;
  wire         stop  = scl_s && scl_d && !sda_d && sda_s;
  wire  [7:0]  shn   = {sh[6:0], sda_s};
  wire  [15:0] ptr1  = ptr + 16'd1;

  function automatic logic [7:0] rd_reg(input logic [15:0] a);
    if (a == 16'h0000) rd_reg = 8'h5A;
    else if (a == 16'h0001) rd_reg = 8'h31;
    else if (a < 16'h0200) rd_reg = regs[a[8:0]];
    else rd_reg = 8'h00;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; p <= '0; wb <= '0; sh <= '0; txb <= '0; hi <= '0; ptr <= '0; ack <= 1'b0; rw <= 1'b0;
      scl_s <= 1'b1; scl_d <= 1'b1; sda_s <= 1'b1; sda_d <= 1'b1; sda_s_lo <= 1'b0;
      for (int i = 0; i < 512; i++) regs[i] <= 8'h00;
    end else begin
      scl_s <= scl; scl_d <= scl_s; sda_s <= line; sda_d <= sda_s;
      if (start) begin
        st <= S_ADDR; p <= '0; sda_s_lo <= 1'b0;
      end else if (stop) begin
        st <= S_IDLE; sda_s_lo <= 1'b0;
      end else if (fall) begin
        case (st)
          S_RD:          sda_s_lo <= (p < 4'd8) ? !txb[3'd7 - p[2:0]] : 1'b0;
          S_ADDR, S_WR:  sda_s_lo <= (p == 4'd8) && ack;
          default:       sda_s_lo <= 1'b0;
        endcase
      end else if (rise) begin
        if (p == 4'd8) begin
          p <= '0;
          if (st == S_ADDR) begin
            if (!ack) st <= S_IGN;
            else if (rw) begin st <= S_RD; txb <= rd_reg(ptr); end
            else begin st <= S_WR; wb <= '0; end
          end else if (st == S_RD) begin
            ptr <= ptr1;
            if (!sda_s) txb <= rd_reg(ptr1);
            else st <= S_IGN;
          end
        end else begin
          p <= p + 4'd1;
          if (st == S_ADDR || st == S_WR) begin
            sh <= shn;
            if (p == 4'd7) begin
              if (st == S_ADDR) begin ack <= shn[7:1] == ADDR; rw <= shn[0]; end
              else begin
                ack <= 1'b1;
                if (wb == 2'd0) hi <= shn;
                else if (wb == 2'd1) ptr <= {hi, shn};
                else begin
                  if (ptr >= 16'd2 && ptr < 16'h0200) regs[ptr[8:0]] <= shn;
                  ptr <= ptr1;
                end
                if (wb != 2'd2) wb <= wb + 2'd1;
              end
            end
          end
        end
      end
    end
  end
endmodule
