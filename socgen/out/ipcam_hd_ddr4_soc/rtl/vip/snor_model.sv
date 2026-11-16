// snor_model: cut by socgen from open-vip SPI_NOR-UVM-VIP tb/top_tb.sv
module snor_model #(parameter string INIT_FILE = "") (
  input  logic       clk,
  input  logic       rst_n,
  input  logic       sclk,
  input  logic       csn,
  input  logic [3:0] io_m,
  input  logic [3:0] io_m_oe,
  output logic [3:0] fl_io,
  output logic [3:0] fl_oe
);
  logic [7:0]  mem [0:65535];
  logic        wel;
  logic [7:0]  cmd, pp;
  logic [23:0] addr;
  logic [15:0] nbit;
  wire         io0 = io_m_oe[0] ? io_m[0] : 1'b1;
  wire  [7:0]  pp_v = {pp[6:0], io0};
  wire         _unused = &{1'b0, clk, io_m[3:1], io_m_oe[3:1]};

  function automatic logic has_addr(input logic [7:0] c);
    has_addr = c == 8'h03 || c == 8'h0B || c == 8'h6B || c == 8'h02 || c == 8'h20;
  endfunction
  function automatic integer data_start(input logic [7:0] c);
    data_start = 8 + (has_addr(c) ? 24 : 0) + ((c == 8'h0B || c == 8'h6B) ? 8 : 0);
  endfunction

  initial begin
    for (int i = 0; i < 65536; i++) mem[i] = i ^ (i >> 8) ^ 8'hA5;
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
  end

  // rising sclk: command, address, program data; CS# rise ends the command
  always_ff @(posedge sclk or posedge csn or negedge rst_n) begin
    if (!rst_n) begin
      wel <= 1'b0; cmd <= '0; pp <= '0; addr <= '0; nbit <= '0;
    end else if (csn) begin
      if (nbit >= 16'd8) begin
        if (cmd == 8'h06) wel <= 1'b1;
        if (cmd == 8'h04) wel <= 1'b0;
        if (cmd == 8'h20 && nbit >= 16'd32) begin
          if (wel) for (int i = 0; i < 4096; i++) mem[{addr[15:12], 12'h000} + 16'(i)] <= 8'hFF;
          wel <= 1'b0;
        end
        if (cmd == 8'h02 && nbit > 16'd32) wel <= 1'b0;
      end
      nbit <= '0; cmd <= '0; addr <= '0;
    end else begin
      if (nbit < 16'd8) cmd <= {cmd[6:0], io0};
      else if (has_addr(cmd) && nbit < 16'd32) addr <= {addr[22:0], io0};
      else if (cmd == 8'h02) begin
        pp <= pp_v;
        if (nbit[2:0] == 3'd7) begin
          if (wel) mem[addr[15:0]] <= mem[addr[15:0]] & pp_v;
          addr[7:0] <= addr[7:0] + 8'd1;
        end
      end
      if (nbit != 16'hFFFF) nbit <= nbit + 16'd1;
    end
  end

  // falling sclk: drive the next output bit / nibble
  always_ff @(negedge sclk or posedge csn or negedge rst_n) begin
    if (!rst_n || csn) begin
      fl_oe <= 4'b0000; fl_io <= 4'b0000;
    end else if (nbit >= 16'd8) begin : drive
      integer k;
      logic [7:0] b;
      k = nbit;
      k = k - data_start(cmd);
      if (k >= 0)
        case (cmd)
          8'h03, 8'h0B: begin b = mem[addr[15:0] + 16'(k / 8)]; fl_oe <= 4'b0010; fl_io[1] <= b[7 - k % 8]; end
          8'h6B: begin
            b = mem[addr[15:0] + 16'(k / 2)];
            fl_oe <= 4'b1111; fl_io <= (k % 2 == 0) ? b[7:4] : b[3:0];
          end
          8'h05: begin fl_oe <= 4'b0010; fl_io[1] <= (k % 8 == 6) ? wel : 1'b0; end
          8'h9F: begin fl_oe <= 4'b0010; fl_io[1] <= (k < 24) ? 1'(24'hEF4018 >> (23 - k)) : 1'b0; end
          default: fl_oe <= 4'b0000;
        endcase
    end
  end
endmodule
