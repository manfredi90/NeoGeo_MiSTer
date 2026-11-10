// Savestate simulation: FX68K + work RAM + ss_ctrl, the SD side is modelled in sim_main.cpp.
module tb
(
	input             clk,
	input             reset,
	input             save,
	input             load,
	input       [1:0] slot,

	output            busy,
	output            info_req,
	output      [7:0] info,

	// trace of the program
	output reg        trace_we,
	output reg [31:0] trace_d,

	// save file
	input             img_mounted,
	input      [63:0] img_size,
	output            sd_rd,
	output            sd_wr,
	output     [31:0] sd_lba,
	output      [5:0] sd_blk_cnt,
	input             sd_ack,
	input      [12:0] sd_buff_addr,
	input      [15:0] sd_buff_dout,
	output     [15:0] sd_buff_din,
	input             sd_buff_wr,

	output     [31:0] irq_count,
	output            frozen,
	output     [23:1] dbg_addr,
	output            dbg_as,
	output     [15:0] dbg_din,
	output      [3:0] dbg_fc
);
assign dbg_addr = addr;
assign dbg_as = as_n;
assign dbg_din = rw ? (ss_drive ? ss_din : din) : dout;
assign dbg_fc = {fc2,fc1,fc0, rw};

// clock enables, frozen like in the core
reg en24n, en24p;
reg ph = 0;
wire freeze;
assign frozen = freeze;
always @(posedge clk) begin
	if (freeze) {en24n, en24p} <= 0;
	else begin
		en24n <= ~ph;
		en24p <= ph;
		ph <= ~ph;
	end
end

reg c68k;
always @(posedge clk) if (en24p) c68k <= ~c68k;
wire en68p = ~c68k & en24p;
wire en68n =  c68k & en24p;

// 68000
wire [23:1] addr;
wire [15:0] dout, din;
wire as_n, uds_n, lds_n, rw, fc2, fc1, fc0;
wire irq7;
wire ss_drive;
wire [15:0] ss_din;

// level 1 timer, part of the saved state through the hooks
reg [19:0] timer;
reg        irq1;
wire [511:0] hook_do = {459'd0, irq1, timer, 32'h5AA5_0001};
wire [511:0] hook_di;
wire hook_ld;

always @(posedge clk) begin
	if (reset) begin
		timer <= 0;
		irq1  <= 0;
	end
	else if (hook_ld) begin
		timer <= hook_di[51:32];
		irq1  <= hook_di[52];
	end
	else begin
		if (en24p) begin
			timer <= timer + 1'd1;
			if (timer == 20'd99_999) begin
				timer <= 0;
				irq1  <= 1;
			end
		end
		if (~as_n & ~rw & addr == 23'h100008) irq1 <= 0;   // $200010
	end
end

cpu_68k cpu
(
	.CLK(clk),
	.CLK_EN_68K_P(en68p),
	.CLK_EN_68K_N(en68n),
	.nRESET(~reset),
	.IPL2(~irq7), .IPL1(~irq7), .IPL0(~irq7 & ~irq1),
	.nDTACK(as_n),
	.M68K_ADDR(addr),
	.FX68K_DATAIN(rw ? (ss_drive ? ss_din : din) : 16'h0000),
	.FX68K_DATAOUT(dout),
	.nLDS(lds_n), .nUDS(uds_n), .nAS(as_n), .M68K_RW(rw),
	.FC2(fc2), .FC1(fc1), .FC0(fc0),
	.nBG(),
	.nBR(1'b1), .nBGACK(1'b1),
	.SYSTEM_CDx(1'b0)
);

// program ROM
reg [15:0] rom[2048];
initial $readmemh("prog.hex", rom);

// work RAM $100000-$10FFFF, second port for the savestates
reg  [7:0] wram_l[32768];
reg  [7:0] wram_h[32768];
reg [15:0] wram_q, wram_qb;
wire       wram_cs = ~as_n && addr[23:16] == 8'h10;

wire       mem_act, mem_we;
wire [3:0] mem_sel;
wire[14:0] mem_addr;
wire[15:0] mem_d;

always @(posedge clk) begin
	if (wram_cs & ~rw & ~lds_n) wram_l[addr[15:1]] <= dout[7:0];
	if (wram_cs & ~rw & ~uds_n) wram_h[addr[15:1]] <= dout[15:8];
	wram_q <= {wram_h[addr[15:1]], wram_l[addr[15:1]]};
end

always @(posedge clk) begin
	if (mem_act & mem_we & mem_sel == 6) begin
		wram_l[mem_addr] <= mem_d[7:0];
		wram_h[mem_addr] <= mem_d[15:8];
	end
	wram_qb <= {wram_h[mem_addr], wram_l[mem_addr]};
end

assign din = (addr[23:20] == 0) ? rom[addr[11:1]] : wram_cs ? wram_q : 16'hFFFF;

// trace: long writes to $200000, taken when the data strobes are asserted
wire ds = ~as_n & (~uds_n | ~lds_n) & ~rw;
always @(posedge clk) begin
	reg old_ds;
	old_ds   <= ds;
	trace_we <= 0;
	if (ds & ~old_ds) begin
		if (addr == 23'h100000) trace_d[31:16] <= dout;
		if (addr == 23'h100001) begin
			trace_d[15:0] <= dout;
			trace_we <= 1;
		end
	end
end

wire [15:0] mem_q = (mem_sel == 6) ? wram_qb : 16'h0000;

ss_ctrl ss
(
	.clk(clk),
	.reset(reset),
	.save(save),
	.load(load),
	.slot(slot),
	.allow(1'b1),
	.cd_system(1'b0),
	.sys_flags(16'h0001),
	.info_req(info_req),
	.info(info),
	.busy(busy),

	.irq7(irq7),
	.cpu_addr(addr),
	.cpu_as_n(as_n),
	.cpu_uds_n(uds_n),
	.cpu_lds_n(lds_n),
	.cpu_rw(rw),
	.cpu_fc({fc2, fc1, fc0}),
	.cpu_dout(dout),
	.cpu_drive(ss_drive),
	.cpu_din(ss_din),

	.z80_hold(),
	.z80_boundary(1'b1),
	.z80_reg(214'd0),
	.z80_dir(),
	.z80_dirset(),
	.z80_rst(),

	.ym_cs_n(1'b1),
	.ym_wr_n(1'b1),
	.ym_addr(2'd0),
	.ym_din(8'd0),
	.ym_ovr(),
	.ym_a(),
	.ym_d(),
	.ym_wr(),

	.ptick(en24p && timer == 20'd50_000),
	.freeze(freeze),

	.hook_do(hook_do),
	.hook_di(hook_di),
	.hook_ld(hook_ld),
	.wd_clear(),

	.mem_act(mem_act),
	.mem_sel(mem_sel),
	.mem_addr(mem_addr),
	.mem_d(mem_d),
	.mem_we(mem_we),
	.mem_q(mem_q),

	.img_mounted(img_mounted),
	.img_size(img_size),
	.bk_force(),
	.bk_busy(1'b0),
	.sd_act(),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

reg [31:0] irq_cnt;
always @(posedge clk) begin
	reg old_as;
	old_as <= as_n;
	if (reset) irq_cnt <= 0;
	else if (~as_n & old_as & ~rw & addr == 23'h100008) irq_cnt <= irq_cnt + 1'd1;
end
assign irq_count = irq_cnt;

endmodule
