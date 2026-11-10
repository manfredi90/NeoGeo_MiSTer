//============================================================================
//  Savestates for the Neo Geo core (cartridge systems).
//
//  The states live in the game's save file (VD 0, the .sav file Main already
//  mounts for every game): 4 slots of 256 KB after the backup RAM and the
//  memory card, so no change to Main_MiSTer is needed.
//
//  Only the state that matters is saved, in a fixed layout of our own, so the
//  states do not depend on how the chips are written inside:
//   - 68000: a level 7 interrupt runs a small handler from a hidden ROM at
//     $FF0000 that stores the registers in the meta RAM ($FF0400) and waits.
//     To continue it reloads them from the restore area and does RTE.
//   - Z80: stopped at the start of an instruction, registers through the T80
//     REG/DIR interface.
//   - Chips: the registers with real state (see hook_do/hook_di in neogeo.sv).
//   - YM2610: a copy of every register the Z80 wrote, written again on load
//     (notes and samples that are playing start again).
//   - Memories: read and written while the whole system is frozen.
//  The system is always frozen at the same point of the video timing (raster
//  line $100, in the vertical blank), so the video counters and the clock
//  dividers are in step and do not need to be saved.
//
//  Slot layout (byte offsets from the slot start, 16-bit little endian words):
//   $00000  meta: header, CPU registers, chip registers (256 words)
//   $00200  YM2610 register copy: word = {valid, value}, port A then port B
//   $01000  Z80 RAM (one byte per word)       $02000  fast VRAM (2K words)
//   $04000  palette RAM (8K words)
//   $08000  extra RAM (XRAM, 4K words)        $0A000  PVC RAM (4K words)
//   $10000  68000 work RAM   $20000  slow VRAM   $30000  backup RAM
//  Slot n starts at $20000 + n * $40000 in the save file.
//
//  Meta words: 0-1 "NGSS" (written last), 2 version, 3 system flags,
//   4 YM2610 address latch, 8-41 68000 restore area (D0-D7/A0-A6, USP, SSP),
//   48-61 Z80 registers, 64-95 chip registers, 128-161 68000 save area.
//============================================================================

module ss_ctrl
(
	input             clk,            // CLK_48M
	input             reset,          // core in reset

	// requests
	input             save,           // pulse
	input             load,           // pulse
	input       [1:0] slot,
	input             allow,          // a cartridge game runs and the save file is mounted
	input             cd_system,      // Neo Geo CD: not supported
	input      [15:0] sys_flags,      // stored in the header, must match on load
	output reg        info_req,
	output reg  [7:0] info,
	output            busy,

	// 68000 bus
	output reg        irq7,
	input      [23:1] cpu_addr,
	input             cpu_as_n,
	input             cpu_uds_n,
	input             cpu_lds_n,
	input             cpu_rw,
	input       [2:0] cpu_fc,
	input      [15:0] cpu_dout,
	output            cpu_drive,      // replace the data the 68000 reads
	output reg [15:0] cpu_din,

	// Z80
	output reg        z80_hold,       // gate the Z80 clock enables
	input             z80_boundary,
	input     [213:0] z80_reg,
	output    [213:0] z80_dir,
	output reg        z80_dirset,
	output reg        z80_rst,

	// YM2610: writes from the Z80 and replay
	input             ym_cs_n,
	input             ym_wr_n,
	input       [1:0] ym_addr,
	input       [7:0] ym_din,
	output reg        ym_ovr,
	output reg  [1:0] ym_a,
	output reg  [7:0] ym_d,
	output reg        ym_wr,

	// freeze
	input             ptick,          // one clock per frame at the freeze point
	output reg        freeze,

	// chip registers
	input     [511:0] hook_do,
	output reg [511:0] hook_di,
	output reg        hook_ld,
	output reg        wd_clear,

	// memories, while frozen
	output            mem_act,
	output reg  [3:0] mem_sel,
	output reg [14:0] mem_addr,
	output     [15:0] mem_d,
	output            mem_we,
	input      [15:0] mem_q,

	// save file (VD 0)
	input             img_mounted,
	input      [63:0] img_size,
	output reg        bk_force,       // normal backup save (creates the file)
	input             bk_busy,
	output reg        sd_act,
	output reg [31:0] sd_lba,
	output reg  [5:0] sd_blk_cnt,
	output reg        sd_rd,
	output reg        sd_wr,
	input             sd_ack,
	input      [12:0] sd_buff_addr,
	input      [15:0] sd_buff_dout,
	output reg [15:0] sd_buff_din,
	input             sd_buff_wr
);

localparam [15:0] VERSION   = 16'd1;
localparam [15:0] MAGIC0    = 16'h474E; // "NG"
localparam [15:0] MAGIC1    = 16'h5353; // "SS"
localparam [31:0] SLOT_LBA0 = 32'h100;  // $20000
localparam [31:0] FILE_LBAS = 32'h900;  // 4 slots

// memory select codes
localparam [3:0] M_NONE = 0, M_Z80 = 1, M_FVRAM = 2, M_PAL = 3, M_XRAM = 4, M_PVC = 5, M_WRAM = 6, M_SVRAM = 7, M_BACKUP = 8;

// info messages (index in the "I," list of CONF_STR)
localparam [7:0] I_SAVED = 18, I_LOADED = 19, I_EMPTY = 20, I_OTHER = 21, I_NOFILE = 22, I_FAILED = 23, I_NOCD = 24;

//----------------------------------------------------------------------------
// Meta RAM (256 x 16, two byte lanes). Port A: 68000. Port B: controller/SD.

reg  [7:0] meta_lo[256];
reg  [7:0] meta_hi[256];

wire       win      = ~cpu_as_n && cpu_addr[23:12] == 12'hFF0 && cpu_fc != 3'b111;   // $FF0000-$FF0FFF, not the interrupt acknowledge
wire       win_rom  = cpu_addr[15:8] == 8'h00;
wire       win_meta = cpu_addr[15:10] == 6'b000001 && !cpu_addr[9];
wire       win_ctl  = cpu_addr[15:8] == 8'h08;

wire       ma_we_lo = win & win_meta & ~cpu_rw & ~cpu_lds_n;
wire       ma_we_hi = win & win_meta & ~cpu_rw & ~cpu_uds_n;
reg  [7:0] ma_q_lo, ma_q_hi;

always @(posedge clk) begin
	if (ma_we_lo) meta_lo[cpu_addr[8:1]] <= cpu_dout[7:0];
	ma_q_lo <= meta_lo[cpu_addr[8:1]];
end

always @(posedge clk) begin
	if (ma_we_hi) meta_hi[cpu_addr[8:1]] <= cpu_dout[15:8];
	ma_q_hi <= meta_hi[cpu_addr[8:1]];
end

reg  [7:0] mb_addr_f;
reg        mb_we_f;
reg [15:0] mb_d_f;
wire [7:0] mb_addr;
wire       mb_we;
wire[15:0] mb_d;
reg [15:0] mb_q;

always @(posedge clk) begin
	if (mb_we) meta_lo[mb_addr] <= mb_d[7:0];
	mb_q[7:0] <= meta_lo[mb_addr];
end

always @(posedge clk) begin
	if (mb_we) meta_hi[mb_addr] <= mb_d[15:8];
	mb_q[15:8] <= meta_hi[mb_addr];
end

//----------------------------------------------------------------------------
// 68000 hidden ROM, control port and vector

reg  [5:0] rom_addr;
reg [15:0] rom_q;
always @(*) rom_addr = cpu_addr[6:1];
`include "ss_handler.vh"

reg parked, go;
reg vec_arm;

wire iack7   = ~cpu_as_n && cpu_fc == 3'b111 && cpu_addr[3:1] == 3'b111;
wire vec_rd  = vec_arm && ~cpu_as_n && cpu_rw && cpu_addr[23:2] == 22'h1F; // $00007C/$00007E

assign cpu_drive = cpu_rw & ((win & (win_rom | win_meta | win_ctl)) | vec_rd);

always @(*) begin
	if (vec_rd)        cpu_din = cpu_addr[1] ? 16'h0000 : 16'h00FF;   // handler at $FF0000
	else if (win_rom)  cpu_din = rom_q;
	else if (win_meta) cpu_din = {ma_q_hi, ma_q_lo};
	else               cpu_din = {15'd0, go};
end

//----------------------------------------------------------------------------
// YM2610 register copy (512 x 9: valid + value). Port A: writes from the Z80.
// The key on register ($28) is kept per channel at port A $F0-$F7.

reg  [8:0] shd[512];
reg  [8:0] sha_addr;
reg  [8:0] sha_d;
reg        sha_we;

always @(posedge clk) if (sha_we) shd[sha_addr] <= sha_d;

wire [8:0] shb_addr;
wire       shb_we;
wire [8:0] shb_d;
reg  [8:0] shb_q;

always @(posedge clk) begin
	if (shb_we) shd[shb_addr] <= shb_d;
	shb_q <= shd[shb_addr];
end

reg  [7:0] ym_sel;
reg        ym_part;
reg  [8:0] clr_cnt = 0;
reg        clr_run = 1;

wire ym_w = ~ym_cs_n & ~ym_wr_n;

always @(posedge clk) begin
	reg old_w;

	old_w  <= ym_w;
	sha_we <= 0;

	if (reset) begin
		clr_run <= 1;
		clr_cnt <= 0;
		ym_sel  <= 0;
		ym_part <= 0;
	end
	else if (clr_run) begin
		sha_addr <= clr_cnt;
		sha_d    <= 0;
		sha_we   <= 1;
		clr_cnt  <= clr_cnt + 1'd1;
		if (&clr_cnt) clr_run <= 0;
	end
	else if (ym_w & ~old_w) begin
		if (~ym_addr[0]) {ym_part, ym_sel} <= {ym_addr[1], ym_din};
		else if (ym_addr[1] == ym_part) begin
			sha_addr <= (~ym_part && ym_sel == 8'h28) ? {6'b0_1111_0, ym_din[2:0]} : {ym_part, ym_sel};
			sha_d    <= {1'b1, ym_din};
			sha_we   <= 1;
		end
	end
end

//----------------------------------------------------------------------------
// SD transfers: request r of the slot, word o inside the request

reg  [3:0] cur_r;
reg        op_load;
reg        ext_mode;     // growing the file with zeros
reg        final_hdr;    // last write of the header with the magic
reg        sd_stream;    // data path active
reg        mem_on;       // memories taken over (frozen)

reg  [12:0] o_base;     // word offset of the request inside region 0
wire [12:0] o = sd_buff_addr + o_base;

reg        rg_meta, rg_shd;
reg  [3:0] rg_sel;
reg [14:0] rg_addr;
wire [9:0] shd_idx = o[9:0] - 10'h100;

always @(*) begin
	rg_meta = 0;
	rg_shd  = 0;
	rg_sel  = M_NONE;
	rg_addr = 0;
	case (cur_r)
		0: begin
				if (o < 13'h100)            rg_meta = 1;
				else if (o < 13'h300)       rg_shd  = 1;
				else if (o[12:11] == 2'b01) begin rg_sel = M_Z80;   rg_addr = o[10:0]; end
				else if (o[12:11] == 2'b10) begin rg_sel = M_FVRAM; rg_addr = o[10:0]; end
			end
		1: begin rg_sel = M_PAL; rg_addr = o; end
		2: begin rg_sel = o[12] ? M_PVC : M_XRAM; rg_addr = o[11:0]; end
		3,4,5,6:     begin rg_sel = M_WRAM;   rg_addr = {cur_r[1:0] - 2'd3, o}; end
		7,8,9,10:    begin rg_sel = M_SVRAM;  rg_addr = {cur_r[1:0] - 2'd3, o}; end
		11,12,13,14: begin rg_sel = M_BACKUP; rg_addr = {cur_r[1:0] - 2'd3, o}; end
		default:;
	endcase
end

function [31:0] req_lba(input [3:0] r);
	case (r)
		0:       req_lba = 0;
		1:       req_lba = 32;
		2:       req_lba = 64;
		3,4,5,6: req_lba = 128 + (r - 3) * 32;
		7,8,9,10: req_lba = 256 + (r - 7) * 32;
		default: req_lba = 384 + (r - 11) * 32;
	endcase
endfunction

wire sd_in = sd_stream & op_load & sd_buff_wr & sd_ack;

assign mb_addr = sd_stream ? o[7:0] : mb_addr_f;
assign mb_we   = (sd_in & rg_meta) | mb_we_f;
assign mb_d    = sd_stream ? sd_buff_dout : mb_d_f;

reg  [8:0] shb_addr_f;
assign shb_addr = sd_stream ? shd_idx[8:0] : shb_addr_f;
assign shb_we   = sd_in & rg_shd;
assign shb_d    = sd_buff_dout[8:0];

assign mem_act = mem_on;
assign mem_d   = sd_buff_dout;
assign mem_we  = mem_on & sd_in & (rg_sel != M_NONE);

always @(*) begin
	mem_sel  = mem_on ? rg_sel : M_NONE;
	mem_addr = rg_addr;

	sd_buff_din = 0;
	if (sd_stream & ~ext_mode) begin
		if (rg_meta) begin
			if (o == 0)      sd_buff_din = final_hdr ? MAGIC0 : 16'h0000;
			else if (o == 1) sd_buff_din = final_hdr ? MAGIC1 : 16'h0000;
			else             sd_buff_din = mb_q;
		end
		else if (rg_shd)            sd_buff_din = {7'd0, shb_q};
		else if (rg_sel == M_Z80)   sd_buff_din = {8'd0, mem_q[7:0]};
		else if (rg_sel != M_NONE)  sd_buff_din = mem_q;
	end
end

//----------------------------------------------------------------------------
// Control

typedef enum logic [5:0] {
	S_IDLE,
	S_BKSAVE, S_BKWAIT,
	S_EXT,
	S_LDHDR, S_CHK,
	S_INJ, S_PARK, S_COPY,
	S_ZHOLD,
	S_LDYM, S_YMLATCH, S_REPLAY,
	S_WAITP, S_SETTLE,
	S_CAP,
	S_STREAM,
	S_HDR,
	S_APPLY, S_ZLOAD,
	S_RESUME,
	S_ABORT,
	S_SD, S_SDWAIT
} state_t;

state_t state, ret_state;

assign busy = (state != S_IDLE);

reg  [1:0] cur_slot;
reg [31:0] slot_lba;
reg [31:0] file_lbas;
reg [27:0] tmo;
reg [15:0] cnt;
reg  [5:0] k;
reg  [1:0] rd_pend;
reg  [5:0] rd_k1, rd_k2;
state_t    copy_ret;
reg [223:0] z80_buf;
reg  [8:0] ym_latch;
reg        frozen;
reg  [7:0] result;

assign z80_dir = z80_buf[213:0];

// YM replay
reg  [9:0] rp_i;          // 0-8: silence, 16-527: registers, 528-535: key on, 536: latch
reg  [2:0] rp_st;
reg [11:0] rp_wait;
reg        rp_port;
reg  [7:0] rp_reg, rp_val;
reg        rp_do;

function [16:0] silence(input [3:0] n);   // {port, reg, value}
	case (n)
		0: silence = {1'b0, 8'h28, 8'h00};
		1: silence = {1'b0, 8'h28, 8'h01};
		2: silence = {1'b0, 8'h28, 8'h02};
		3: silence = {1'b0, 8'h28, 8'h04};
		4: silence = {1'b0, 8'h28, 8'h05};
		5: silence = {1'b0, 8'h28, 8'h06};
		6: silence = {1'b1, 8'h00, 8'hBF};   // ADPCM-A dump
		7: silence = {1'b0, 8'h10, 8'h01};   // ADPCM-B reset
		default: silence = {1'b0, 8'h07, 8'h3F}; // SSG off
	endcase
endfunction

wire [223:0] z80_reg_pad = {10'd0, z80_reg};

// data written to the meta RAM when capturing: k = 0..48
function [15:0] cap_data(input [5:0] n);
	if (n == 0)       cap_data = VERSION;
	else if (n == 1)  cap_data = sys_flags;
	else if (n == 2)  cap_data = {1'b1, 6'd0, ym_part, ym_sel};
	else if (n < 17)  cap_data = z80_reg_pad[(n - 3) * 16 +: 16];
	else              cap_data = hook_do[(n - 17) * 16 +: 16];
endfunction

function [7:0] cap_addr(input [5:0] n);
	if (n < 3)        cap_addr = 8'd2 + n;
	else if (n < 17)  cap_addr = 8'd48 + (n - 3);
	else              cap_addr = 8'd64 + (n - 17);
endfunction

always @(posedge clk) begin
	reg old_save, old_load, old_ack, old_mounted, old_bk;

	old_save    <= save;
	old_load    <= load;
	old_ack     <= sd_ack;
	old_mounted <= img_mounted;
	old_bk      <= bk_busy;

	info_req   <= 0;
	bk_force   <= 0;
	mb_we_f    <= 0;
	hook_ld    <= 0;
	wd_clear   <= 0;
	z80_dirset <= 0;
	ym_wr      <= 0;

	// size of the save file in sectors
	if (~old_mounted & img_mounted) file_lbas <= img_size[40:9];

	// interrupt handshake
	if (iack7) begin
		irq7    <= 0;
		vec_arm <= 1;
	end
	if (win) vec_arm <= 0;
	if (win & win_ctl & ~cpu_rw) parked <= 1;

	if (tmo) tmo <= tmo - 1'd1;

	case (state)
		S_IDLE: begin
				sd_act <= 0;
				ym_ovr <= 0;
				result <= 0;
				if ((~old_save & save) | (~old_load & load)) begin
					cur_slot <= slot;
					slot_lba <= SLOT_LBA0 + {slot, 9'd0};
					op_load  <= ~old_load & load;
					if (cd_system)      begin info <= I_NOCD;   info_req <= 1; end
					else if (!allow)    begin info <= I_NOFILE; info_req <= 1; end
					else if (~old_load & load) state <= S_LDHDR;
					else if (file_lbas < 32'h90) state <= S_BKSAVE;
					else state <= S_EXT;
				end
			end

		//------------------------------------------------------------------
		// save: make sure the file holds the backup area and all the slots

		S_BKSAVE: begin
				bk_force <= 1;
				tmo      <= 28'd48_000_000;
				state    <= S_BKWAIT;
			end

		S_BKWAIT:
			if (old_bk & ~bk_busy) begin
				if (file_lbas < 32'h90) file_lbas <= 32'h90;
				state <= S_EXT;
			end
			else if (!tmo) state <= S_ABORT;

		S_EXT:
			if (file_lbas >= FILE_LBAS) state <= S_INJ;
			else begin
				ext_mode   <= 1;
				sd_lba     <= file_lbas;
				sd_blk_cnt <= ((FILE_LBAS - file_lbas) > 32) ? 6'd31 : 6'(FILE_LBAS - file_lbas - 1'd1);
				file_lbas  <= ((FILE_LBAS - file_lbas) > 32) ? (file_lbas + 32) : FILE_LBAS;
				sd_wr      <= 1;
				ret_state  <= S_EXT;
				state      <= S_SD;
			end

		//------------------------------------------------------------------
		// load: header check

		S_LDHDR: begin
				cur_r      <= 0;
				sd_lba     <= slot_lba;
				sd_blk_cnt <= 0;
				sd_rd      <= 1;
				ret_state  <= S_CHK;
				k          <= 0;
				state      <= S_SD;
			end

		S_CHK: begin
				// meta words 0..3; the data of the address set at k comes at k+2
				mb_addr_f <= {6'd0, k[1:0]};
				k <= k + 1'd1;
				case (k)
					2: if (mb_q != MAGIC0)  result <= I_EMPTY;
					3: if (mb_q != MAGIC1)  result <= I_EMPTY;
					4: if (mb_q != VERSION) result <= I_EMPTY;
					5: if (mb_q != sys_flags && !result) result <= I_OTHER;
					6: begin
							if (result) begin
								info     <= result;
								info_req <= 1;
								state    <= S_IDLE;
							end
							else state <= S_INJ;
						end
					default:;
				endcase
			end

		//------------------------------------------------------------------
		// stop the 68000 in the handler

		S_INJ: begin
				parked <= 0;
				go     <= 0;
				irq7   <= 1;
				tmo    <= 28'd12_000_000;
				state  <= S_PARK;
			end

		S_PARK:
			if (parked) begin
				tmo <= 28'd24_000_000;
				if (op_load) state <= S_ZHOLD;
				else begin
					// the program goes on from the registers just saved
					k        <= 0;
					cnt      <= 0;
					copy_ret <= S_ZHOLD;
					state    <= S_COPY;
				end
			end
			else if (!tmo) begin
				irq7  <= 0;
				state <= S_ABORT;
			end

		// save area (words 128..161) -> restore area (8..41)
		S_COPY: begin
				cnt <= cnt + 1'd1;
				case (cnt[1:0])
					0: mb_addr_f <= 8'd128 + k;
					2: begin
							mb_addr_f <= 8'd8 + k;
							mb_d_f    <= mb_q;
							mb_we_f   <= 1;
						end
					3: begin
							k <= k + 1'd1;
							if (k == 33) begin
								tmo   <= 28'd24_000_000;
								state <= copy_ret;
							end
						end
					default:;
				endcase
			end

		//------------------------------------------------------------------
		// stop the Z80 at the start of an instruction

		S_ZHOLD:
			if (z80_hold) begin
				tmo   <= 28'd24_000_000;
				state <= op_load ? S_LDYM : S_WAITP;
			end
			else if (z80_boundary) z80_hold <= 1;
			else if (!tmo) state <= S_ABORT;

		//------------------------------------------------------------------
		// load: YM2610 registers, written while the system still runs

		S_LDYM: begin
				// sectors 1-2 only: sector 0 holds the 68000 save area by now
				cur_r      <= 0;
				o_base     <= 13'h100;
				sd_lba     <= slot_lba + 1'd1;
				sd_blk_cnt <= 1;
				sd_rd      <= 1;
				ret_state  <= S_YMLATCH;
				cnt        <= 0;
				state      <= S_SD;
			end

		S_YMLATCH: begin
				mb_addr_f <= 8'd4;
				cnt <= cnt + 1'd1;
				if (cnt == 2) begin
					ym_latch <= {mb_q[8], mb_q[7:0]};
					rp_do    <= mb_q[15];
					rp_i     <= 0;
					rp_st    <= 0;
					ym_ovr   <= 1;
					state    <= S_REPLAY;
				end
			end

		S_REPLAY:
			case (rp_st)
				// next write
				0:	if (rp_i < 9) begin
						{rp_port, rp_reg, rp_val} <= silence(rp_i[3:0]);
						rp_st <= 2;
					end
					else if (rp_i < 16) rp_i <= 16;
					else if (rp_i < 536) begin
						shb_addr_f <= (rp_i < 528) ? 9'(rp_i - 10'd16) : 9'(9'h0F0 + rp_i - 10'd528);
						rp_wait    <= 2;
						rp_st      <= 1;
					end
					else if (rp_i == 536 && rp_do) begin
						rp_port <= ym_latch[8];
						rp_reg  <= ym_latch[7:0];
						rp_st   <= 5;
					end
					else begin
						ym_ovr <= 0;
						tmo    <= 28'd24_000_000;
						state  <= S_WAITP;
					end

				// read the copy, skip what must not be written again
				1:	if (rp_wait) rp_wait <= rp_wait - 1'd1;
					else begin
						rp_st <= 0;
						rp_i  <= rp_i + 1'd1;
						if (rp_i < 528) begin
							rp_port <= shb_addr_f[8];
							rp_reg  <= shb_addr_f[7:0];
							rp_val  <= (shb_addr_f == 9'h010) ? (shb_q[7:0] & 8'h7E) : shb_q[7:0];  // ADPCM-B: no start
							if (shb_q[8] &&
							    !(~shb_addr_f[8] && (shb_addr_f[7:0] == 8'h28 || shb_addr_f[7:4] == 4'hF)) &&  // key on: later
							    !( shb_addr_f[8] && shb_addr_f[7:0] == 8'h00)) begin                           // ADPCM-A key on
								rp_st <= 2;
								rp_i  <= rp_i;
							end
						end
						else if (shb_q[8]) begin
							rp_port <= 0;
							rp_reg  <= 8'h28;
							rp_val  <= shb_q[7:0];
							rp_st   <= 2;
							rp_i    <= rp_i;
						end
					end

				// address write
				2: begin
						ym_a    <= {rp_port, 1'b0};
						ym_d    <= rp_reg;
						rp_wait <= 32;
						rp_st   <= 3;
					end
				3: begin
						if (rp_wait > 16) ym_wr <= 1;
						if (rp_wait) rp_wait <= rp_wait - 1'd1;
						else begin
							ym_a    <= {rp_port, 1'b1};
							ym_d    <= rp_val;
							rp_wait <= 12'd2047;
							rp_st   <= 4;
						end
					end
				// data write, then give the chip time to take it
				4: begin
						if (rp_wait > 12'd2031) ym_wr <= 1;
						if (rp_wait) rp_wait <= rp_wait - 1'd1;
						else begin
							rp_i  <= rp_i + 1'd1;
							rp_st <= 0;
						end
					end
				// the address latch the Z80 left behind
				5: begin
						ym_a    <= {rp_port, 1'b0};
						ym_d    <= rp_reg;
						rp_wait <= 32;
						rp_st   <= 6;
					end
				6: begin
						if (rp_wait > 16) ym_wr <= 1;
						if (rp_wait) rp_wait <= rp_wait - 1'd1;
						else begin
							rp_i  <= rp_i + 1'd1;
							rp_do <= 0;
							rp_st <= 0;
						end
					end
				default: rp_st <= 0;
			endcase

		//------------------------------------------------------------------
		// freeze at the fixed point of the frame

		S_WAITP:
			if (ptick) begin
				freeze <= 1;
				frozen <= 1;
				cnt    <= 0;
				state  <= S_SETTLE;
			end
			else if (!tmo) state <= S_ABORT;

		S_SETTLE: begin
				cnt <= cnt + 1'd1;
				if (cnt == 64) begin
					k     <= 0;
					cur_r <= 0;
					state <= op_load ? S_STREAM : S_CAP;
				end
			end

		// save: header, Z80 and chip registers into the meta RAM
		S_CAP: begin
				mb_addr_f <= cap_addr(k);
				mb_d_f    <= cap_data(k);
				mb_we_f   <= 1;
				k         <= k + 1'd1;
				if (k == 48) state <= S_STREAM;
			end

		// all the requests of the slot
		S_STREAM:
			if (cur_r == 15) begin
				mem_on <= 0;
				if (op_load) begin
					k       <= 0;
					rd_pend <= 0;
					state   <= S_APPLY;
				end
				else state <= S_HDR;
			end
			else begin
				mem_on     <= 1;
				sd_lba     <= slot_lba + req_lba(cur_r);
				sd_blk_cnt <= 31;
				sd_rd      <= op_load;
				sd_wr      <= ~op_load;
				ret_state  <= S_STREAM;
				state      <= S_SD;
			end

		// save: header with the magic, last
		S_HDR:
			if (final_hdr) begin
				final_hdr <= 0;
				result    <= I_SAVED;
				state     <= S_RESUME;
			end
			else begin
				final_hdr  <= 1;
				cur_r      <= 0;
				sd_lba     <= slot_lba;
				sd_blk_cnt <= 0;
				sd_wr      <= 1;
				ret_state  <= S_HDR;
				state      <= S_SD;
			end

		// load: Z80 and chip registers from the meta RAM (words 48..61 and 64..95)
		S_APPLY: begin
				if (k < 46) begin
					mb_addr_f <= (k < 14) ? (8'd48 + k) : (8'd50 + k);
					k <= k + 1'd1;
				end
				rd_pend <= {rd_pend[0], k < 46};
				rd_k1   <= k;
				rd_k2   <= rd_k1;
				if (rd_pend[1]) begin
					if (rd_k2 < 14) z80_buf[rd_k2 * 16 +: 16] <= mb_q;
					else            hook_di[(rd_k2 - 14) * 16 +: 16] <= mb_q;
				end
				if (k == 46 && !rd_pend) begin
					hook_ld  <= 1;
					wd_clear <= 1;
					z80_rst  <= 1;
					cnt      <= 0;
					state    <= S_ZLOAD;
				end
			end

		S_ZLOAD: begin
				cnt <= cnt + 1'd1;
				if (cnt < 4) wd_clear <= 1;
				if (cnt == 4) z80_rst <= 0;
				if (cnt == 5) z80_dirset <= 1;
				if (cnt == 8) begin
					result <= I_LOADED;
					state  <= S_RESUME;
				end
			end

		// let everything run again
		S_RESUME: begin
				mem_on   <= 0;
				sd_act   <= 0;
				freeze   <= 0;
				frozen   <= 0;
				z80_hold <= 0;
				z80_rst  <= 0;
				go       <= 1;
				ym_ovr   <= 0;
				ext_mode <= 0;
				if (result) begin
					info     <= result;
					info_req <= 1;
				end
				state <= S_IDLE;
			end

		// something did not answer: give the system back
		S_ABORT: begin
				mem_on    <= 0;
				ym_ovr    <= 0;
				sd_act    <= 0;
				ext_mode  <= 0;
				final_hdr <= 0;
				result    <= I_FAILED;
				if (parked & op_load & ~frozen) begin
					// the restore area holds the state from the file: put back the
					// registers the handler has just saved
					k        <= 0;
					cnt      <= 0;
					copy_ret <= S_RESUME;
					state    <= S_COPY;
				end
				else state <= S_RESUME;
			end

		//------------------------------------------------------------------
		// one SD request

		S_SD: begin
				sd_act    <= 1;
				sd_stream <= 1;
				tmo       <= 28'd96_000_000;
				state     <= S_SDWAIT;
			end

		S_SDWAIT:
			if (old_ack & ~sd_ack) begin
				sd_stream <= 0;
				ext_mode  <= 0;
				o_base    <= 0;
				if (ret_state == S_STREAM) cur_r <= cur_r + 1'd1;
				state     <= ret_state;
			end
			else if (!tmo) begin
				{sd_rd, sd_wr} <= 0;
				sd_stream <= 0;
				state     <= S_ABORT;
			end
			else if (~old_ack & sd_ack) {sd_rd, sd_wr} <= 0;

		default: state <= S_IDLE;
	endcase

	if (reset) begin
		state     <= S_IDLE;
		irq7      <= 0;
		vec_arm   <= 0;
		freeze    <= 0;
		frozen    <= 0;
		z80_hold  <= 0;
		z80_rst   <= 0;
		ym_ovr    <= 0;
		mem_on    <= 0;
		sd_act    <= 0;
		sd_stream <= 0;
		sd_rd     <= 0;
		sd_wr     <= 0;
		ext_mode  <= 0;
		final_hdr <= 0;
		result    <= 0;
		o_base    <= 0;
		go        <= 1;
	end
end

endmodule
