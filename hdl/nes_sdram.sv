//
// SDRAM controller for the NES core.
//
// Adapted for Game Bub from NES_MiSTer rtl/sdram.sv:
//   Copyright (c) 2018 Sorgelig
//   Licensed under the GNU General Public License v3 (or later).
//
// Changes from the original:
//   * The bidirectional data bus is split into in/out/direction signals,
//     since the tristate buffer lives in the Game Bub top-level.
//   * The Altera altddio_out SDRAM clock driver is replaced by a Xilinx ODDR,
//     forwarding a separate (phase shifted) clock, clk_out.
//   * Savestate ports removed.
//   * Channel 2 (save RAM access) doesn't reuse the previously read word.
//   * Channel 0 can also do 16-bit writes (ch0_word), for fast ROM loading.
//   * An extra cycle between ACTIVE and READ/WRITE (tRCD: 23 ns instead of
//     11.6 ns), making each access 8 cycles instead of 7.
//   * Auto refresh cycles during initialization, as required by the SDRAM.
//
// The access timing is unchanged: every access (or refresh) takes a fixed
// 7 cycles at 4x the NES master clock, so that CPU and PPU accesses always
// complete within the window the NES core expects.
//

module nes_sdram
(
	// SDRAM pins
	input      [15:0] SDRAM_DQ_IN,
	output reg [15:0] SDRAM_DQ_OUT,
	output reg        SDRAM_DQ_OE,
	output reg [12:0] SDRAM_A,    // 13 bit multiplexed address bus
	output            SDRAM_DQML, // byte mask
	output            SDRAM_DQMH, // byte mask
	output reg  [1:0] SDRAM_BA,   // two banks
	output            SDRAM_nCS,  // a single chip select
	output reg        SDRAM_nWE,  // write enable
	output reg        SDRAM_nRAS, // row address select
	output reg        SDRAM_nCAS, // columns address select
	output            SDRAM_CLK,
	output            SDRAM_CKE,

	// cpu/chipset interface
	input             init,			// init signal after FPGA config to initialize RAM
	input             clk,			// sdram is accessed at up to 128MHz
	input             clk_out,		// clock forwarded to the SDRAM (clk, phase shifted)

	input      [24:0] ch0_addr,
	input             ch0_rd,
	input             ch0_wr,
	input       [7:0] ch0_din,
	input             ch0_word,     // 16-bit write of ch0_din16 (address must be even)
	input      [15:0] ch0_din16,
	output reg  [7:0] ch0_dout,
	output reg        ch0_busy,

	input      [24:0] ch1_addr,
	input             ch1_rd,
	input             ch1_wr,
	input       [7:0] ch1_din,
	output reg  [7:0] ch1_dout,
	output reg        ch1_busy,

	input      [24:0] ch2_addr,
	input             ch2_rd,
	input             ch2_wr,
	input       [7:0] ch2_din,
	output reg  [7:0] ch2_dout,
	output reg        ch2_busy,

	input             refresh
);

assign SDRAM_nCS = 0;
assign SDRAM_CKE = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

localparam RASCAS_DELAY   = 3'd2; // tRCD=20ns -> 2 cycles@85MHz
localparam BURST_LENGTH   = 3'd0; // 0=1, 1=2, 2=4, 3=8, 7=full page
localparam ACCESS_TYPE    = 1'd0; // 0=sequential, 1=interleaved
localparam CAS_LATENCY    = 3'd2; // 2/3 allowed
localparam OP_MODE        = 2'd0; // only 0 (standard operation) allowed
localparam NO_WRITE_BURST = 1'd1; // 0=write burst enabled, 1=only single access write

localparam MODE = { 3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

localparam STATE_IDLE  = 3'd0;             // state to check the requests
localparam STATE_START = STATE_IDLE+1'd1;  // state in which a new command is started
localparam STATE_NEXT  = STATE_START+1'd1; // state in which a new command is started
localparam STATE_CONT  = STATE_START+RASCAS_DELAY;
localparam STATE_READY = STATE_CONT+CAS_LATENCY+2'd2;
localparam STATE_LAST  = STATE_READY;      // last state in cycle

reg  [2:0] state = STATE_IDLE;
reg [22:0] a;
reg  [1:0] bank;
reg [15:0] data;
reg        we;
reg        word;
reg        ram_req=0;

localparam MODE_NORMAL = 2'b00;
localparam MODE_RESET  = 2'b01;
localparam MODE_LDM    = 2'b10;
localparam MODE_PRE    = 2'b11;

// initialization
reg [1:0] mode = MODE_RESET;
reg [4:0] reset=5'h1f;
reg       init_refresh = 0;

wire [2:0] rd,wr;

assign rd = {ch2_rd, ch1_rd, ch0_rd};
assign wr = {ch2_wr, ch1_wr, ch0_wr};

// access manager
reg  [2:0] old_rd = 0, old_wr = 0;
reg [24:1] last_a[3] = '{'1,'1,'1};
always @(posedge clk) begin
	old_rd <= old_rd & rd;
	old_wr <= old_wr & wr;

	if(state == STATE_IDLE && mode == MODE_NORMAL) begin
		ram_req <= 0;
		we <= 0;
		word <= 0;
		ch0_busy <= 0;
		ch1_busy <= 0;
		ch2_busy <= 0;
		if((~old_rd[0] & rd[0]) | (~old_wr[0] & wr[0])) begin
			old_rd[0] <= rd[0];
			old_wr[0] <= wr[0];
			we <= wr[0];
			word <= wr[0] & ch0_word;
			{bank,a} <= ch0_addr;
			data <= (wr[0] & ch0_word) ? ch0_din16 : {ch0_din,ch0_din};
			ram_req <= wr[0] || (last_a[0] != ch0_addr[24:1]);
			last_a[0] <= wr[0] ? '1 : ch0_addr[24:1];
			ch0_busy <= 1;
			state <= STATE_START;
		end
		else if((~old_rd[1] & rd[1]) | (~old_wr[1] & wr[1])) begin
			old_rd[1] <= rd[1];
			old_wr[1] <= wr[1];
			we <= wr[1];
			{bank,a} <= ch1_addr;
			data <= {ch1_din,ch1_din};
			ram_req <= wr[1] || (last_a[1] != ch1_addr[24:1]);
			last_a[1] <= wr[1] ? '1 : ch1_addr[24:1];
			ch1_busy <= 1;
			state <= STATE_START;
		end
		else if((~old_rd[2] & rd[2]) | (~old_wr[2] & wr[2])) begin
			old_rd[2] <= rd[2];
			old_wr[2] <= wr[2];
			we <= wr[2];
			{bank,a} <= ch2_addr;
			data <= {ch2_din,ch2_din};
			// Always access the SDRAM for channel 2 (save RAM): the NES may
			// have written the word through another channel since the last read.
			ram_req <= 1'b1;
			last_a[2] <= '1;
			ch2_busy <= 1;
			state <= STATE_START;
		end
		else if (refresh) begin
			ram_req <= 1'b0;
			we      <= 1'b0;
			state   <= STATE_START;
		end
	end

	if (state == STATE_READY) begin
		ch0_busy <= 0;
		ch1_busy <= 0;
		ch2_busy <= 0;
	end

	if(mode != MODE_NORMAL || state != STATE_IDLE || reset) begin
		state <= state + 1'd1;
		if(state == STATE_LAST) state <= STATE_IDLE;
	end
end

reg init_old=0;
always @(posedge clk) begin
	init_old <= init;

	if(init_old & ~init) reset <= 5'h1f;
	else if(state == STATE_LAST) begin
		if(reset != 0) begin
			reset <= reset - 5'd1;
			if(reset == 14)     mode <= MODE_PRE;
			else if(reset == 3) mode <= MODE_LDM;
			else                mode <= MODE_RESET;
			// Auto refresh (8 times) after precharging, before loading the mode.
			init_refresh <= (reset <= 13) && (reset >= 6);
		end
		else mode <= MODE_NORMAL;
	end
end

localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

wire [1:0] dqm = word ? 2'b00 : {we & ~a[0], we & a[0]};

// SDRAM state machines
reg [15:0] last_data[3];
reg [15:0] data_reg;
always @(posedge clk) begin
	if(state == STATE_START) SDRAM_BA <= (mode == MODE_NORMAL) ? bank : 2'b00;

	SDRAM_DQ_OE <= 1'b0;
	casex({ram_req,we,mode,state})
		{2'b1X, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_ACTIVE;
		{2'b11, MODE_NORMAL, STATE_CONT }: begin
			{SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_DQ_OUT} <= {CMD_WRITE, data};
			SDRAM_DQ_OE <= 1'b1;
		end
		{2'b10, MODE_NORMAL, STATE_CONT }: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_READ;
		{2'b0X, MODE_NORMAL, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_AUTO_REFRESH;

		// init
		{2'bXX,    MODE_LDM, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_LOAD_MODE;
		{2'bXX,    MODE_PRE, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_PRECHARGE;
		{2'bXX,  MODE_RESET, STATE_START}: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= init_refresh ? CMD_AUTO_REFRESH : CMD_NOP;

		                          default: {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} <= CMD_NOP;
	endcase

	casex({ram_req,mode,state})
		{1'b1,  MODE_NORMAL, STATE_START}: SDRAM_A <= a[13:1];
		{1'b1,  MODE_NORMAL, STATE_CONT }: SDRAM_A <= {dqm, 2'b10, a[22:14]};

		// init
		{1'bX,     MODE_LDM, STATE_START}: SDRAM_A <= MODE;
		{1'bX,     MODE_PRE, STATE_START}: SDRAM_A <= 13'b0010000000000;

		                          default: SDRAM_A <= 13'b0000000000000;
	endcase

	data_reg <= SDRAM_DQ_IN;

	if(state == STATE_READY) begin
		if(ch0_busy) begin
			if(ram_req) begin
				if(we) ch0_dout <= data[7:0];
				else begin
					ch0_dout <= a[0] ? data_reg[15:8] : data_reg[7:0];
					last_data[0] <= data_reg;
				end
			end
			else ch0_dout <= a[0] ? last_data[0][15:8] : last_data[0][7:0];
		end
		if(ch1_busy) begin
			if(ram_req) begin
				if(we) ch1_dout <= data[7:0];
				else begin
					ch1_dout <= a[0] ? data_reg[15:8] : data_reg[7:0];
					last_data[1] <= data_reg;
				end
			end
			else ch1_dout <= a[0] ? last_data[1][15:8] : last_data[1][7:0];
		end
		if(ch2_busy) begin
			if(ram_req) begin
				if(we) ch2_dout <= data[7:0];
				else begin
					ch2_dout <= a[0] ? data_reg[15:8] : data_reg[7:0];
					last_data[2] <= data_reg;
				end
			end
			else ch2_dout <= a[0] ? last_data[2][15:8] : last_data[2][7:0];
		end
	end
end

// Forward clk_out to the SDRAM. Its phase is chosen so that commands (which
// change on the rising edge of clk) are sampled in the middle of the cycle,
// and read data is captured in its valid window (see the core's XDC).
`ifdef VERILATOR
assign SDRAM_CLK = ~clk;
`else
ODDR #(
	.DDR_CLK_EDGE("SAME_EDGE"),
	.INIT(1'b0),
	.SRTYPE("SYNC")
) sdramclk_ddr (
	.Q(SDRAM_CLK),
	.C(clk_out),
	.CE(1'b1),
	.D1(1'b1),
	.D2(1'b0),
	.R(1'b0),
	.S(1'b0)
);
`endif

endmodule
