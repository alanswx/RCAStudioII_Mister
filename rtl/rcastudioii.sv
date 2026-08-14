//============================================================================
//
//  RCA Studio II core glue: CPU + CDP1861 + RAM + keypad.
//
//  Original implementation by Jason Coombes (JasonA-dev), 2022, with MiSTer
//  framework integration by Flandango. Extended 2026 by Alan Steremberg.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module rcastudioii
(
	input              clk_sys,
	input              reset,
	
	input wire         ioctl_download,
	input wire   [7:0] ioctl_index,
	input wire         ioctl_wr,
	input       [24:0] ioctl_addr,
	input        [7:0] ioctl_dout,

	input       [10:0] ps2_key,
	input       [31:0] joystick_0,
	input       [31:0] joystick_1,
	input        [2:0] joy_override,   // OSD: 0 = auto, else the profile to force
	input        [1:0] players,        // OSD: 0 = auto, 1 = one player, 2 = two players
	input        [9:0] osk_a,          // on-screen keypad presses for keypad A (bit = key)
	input        [9:0] osk_b,          // and for keypad B
	input  reg         ce_pix,

	output reg         HBlank,
	output reg         HSync,
	output reg         VBlank,
	output reg         VSync,
	output reg         video_de,
	output             video,
	output             audio
);

////////////////// VIDEO //////////////////////////////////////////////////////////////////

wire        Disp_On;
wire        Disp_Off;
// SC is driven by the CPU's output port, so it must be a net -- declaring it a reg with an
// initial value of 2'b10 meant the 1861 saw a constant "DMA" state code.
wire [1:0]  SC;

wire        INT;
wire        DMAO;
wire        EFx;
wire        Locked;


pixie_video pixie_video (
    // front end, CDP1802 bus clock domain
    .clk        (clk_sys),    // I
    .reset      (reset),      // I
    .clk_enable (ce_pix),     // I
    .cpu_ce     (cpu_ce),     // I  CPU machine-cycle enable, for sampling DMA bytes

    .SC         (SC),         // I [1:0]
    // INP 1 turns the display on, OUT 1 turns it off (the BIOS enables it via CALL $0066). These
    // were tied on/off, so the display could never be disabled and the 1861 started generating
    // interrupts from reset instead of from the moment the BIOS enabled it. The earlier commented
    // version keyed off io_n[0] alone, which cannot tell INP 1 from OUT 1.
    .disp_on    (io_inp && (io_n == 3'd1)),  // I
    .disp_off   (io_out && (io_n == 3'd1)),  // I

    .data_in    (ram_q),      // I [7:0]  byte the CPU delivers during a DMA-OUT cycle

    .DMAO       (DMAO),       // O
    .INT        (INT),        // O
    .EFx        (EFx),        // O

    // back end, video clock domain
    .video_clk  (clk_sys),    // I
    .csync      (),           // O
    .video      (video),      // O

    .VSync      (VSync),      // O
    .HSync      (HSync),      // O
    .VBlank     (VBlank),     // O
    .HBlank     (HBlank),     // O
    .video_de   (video_de)    // O    
);

////////////////// KEYPAD //////////////////////////////////////////////////////////////////

//The CPU selects the key to scan with OUT 2, latched into a CD4515. "io_n[1] && io_out" was a bit
//test, so it also latched on OUT 3, OUT 6 and OUT 7; it must be an equality test on N == 2. The
//assignment was blocking inside a clocked block, too.
reg  [3:0] keylatch = 4'h0;
always @(posedge clk_sys) if(io_out && (io_n == 3'd2)) keylatch <= cpu_dout[3:0];

wire       pressed = ps2_key[9];
wire [7:0] code    = ps2_key[7:0];
always @(posedge clk_sys) begin
	reg old_state;
	old_state <= ps2_key[10];

	if(old_state != ps2_key[10]) begin
		case(code)
			// Keypad A
			'h16: playerA[1] <= pressed; // 1 → 1
			'h1E: playerA[2] <= pressed; // 2 → 2
			'h26: playerA[3] <= pressed; // 3 → 3
			'h15: playerA[4] <= pressed; // Q → 4
			'h1D: playerA[5] <= pressed; // W → 5
			'h24: playerA[6] <= pressed; // E → 6
			'h1C: playerA[7] <= pressed; // A → 7
			'h1B: playerA[8] <= pressed; // S → 8
			'h23: playerA[9] <= pressed; // D → 9
			'h22: playerA[0] <= pressed; // X → 0
		
			// Keypad B
			'h3D: playerB[1] <= pressed; // 7 → 1
			'h3E: playerB[2] <= pressed; // 8 → 2
			'h46: playerB[3] <= pressed; // 9 → 3
			'h3C: playerB[4] <= pressed; // U → 4
			'h43: playerB[5] <= pressed; // I → 5
			'h44: playerB[6] <= pressed; // O → 6
			'h3B: playerB[7] <= pressed; // J → 7
			'h42: playerB[8] <= pressed; // K → 8
			'h4B: playerB[9] <= pressed; // L → 9
			'h41: playerB[0] <= pressed; // , → 0
		endcase
	end
end
reg  [9:0] playerA = 10'h0;
reg  [9:0] playerB = 10'h0;


////////////////// JOYSTICK -> KEYPAD ///////////////////////////////////////
//
// The Studio II has no joystick: every game is played on the 10-key pads, and
// each one picks its own keys. So a gamepad can only work if the mapping follows
// the cartridge. A CRC16 of the image is taken while it downloads and looked up
// in a table below; the result selects one of a few profiles.
//
// Key numbers come from the RCA manuals (see Readme "How to play"), not guesses.
// MiSTer joystick bits, per the CONF_STR "J1,..." list in RCAStudioII.sv:
//   [0]=right [1]=left [2]=down [3]=up   [4]=Fire   [5]=Extra   [6]=Start
//   [7]=Select(CLEAR, folded into reset by the top level)
//   [17:8]=A0..A9   [27:18]=B0..B9.
// Fire/Extra mirror the MPT-02 joystick (the Soundic/Hanimex Studio III
// machines' swappable keypad controller): fire on 5, a second button on 0.
// Extra only presses 0 in the profiles where 0 is documented and safe --
// CROSS (the MPT-02's own layout) and PADDLE (0 pauses Tennis) -- never in
// HOMEBREW, where A0 restarts Invaders.
// A0..B9 are direct per-key bindings with no default mapping: they are inert
// until the user binds them in Define Buttons, and then they always work, on
// top of whatever profile is active.

// The profile is 4 bits internally; the OSD override (joy_override) is 3, so
// only the first seven are forceable from the menu. MAP_HB2P exists solely for
// the two-player homebrews, which the CRC table selects on its own.
localparam [3:0] MAP_NONE     = 4'd0;   // keypad only
localparam [3:0] MAP_CROSS    = 4'd1;   // 2/8/4/6 + 5 fire, both pads
localparam [3:0] MAP_PADDLE   = 4'd2;   // up/down only (Tennis, Squash)
localparam [3:0] MAP_SPACEWAR = 4'd3;   // fire A2, steer B4/B6
localparam [3:0] MAP_FREEWAY  = 4'd4;   // steer B4/B6, throttle A2, brake A8
localparam [3:0] MAP_BOWLING  = 4'd5;   // roll A5, hook A2/A8
localparam [3:0] MAP_BASEBALL = 4'd6;   // bat A5; pitch B5 straight, B2/B8 curve
localparam [3:0] MAP_HOMEBREW = 4'd7;   // Paul Robson's 1P games: 8-way on pad A
                                        // (diagonals are keys 1/3/7/9), fire B0
localparam [3:0] MAP_HB2P     = 4'd8;   // 2P homebrew (Hockey, Combat): cross
                                        // plus fire-on-0, each player's own pad

reg [3:0] map_profile = MAP_NONE;

// ---- CRC16-CCITT over the cartridge image, computed during ioctl_download ----
// Seed on the first byte and hold the result after the download ends -- clearing
// it whenever ioctl_download is low would wipe the CRC before it could be used.
reg [15:0] cart_crc = 16'hFFFF;
reg        dl_d;
wire       dl_done = dl_d & ~ioctl_download;      // falling edge: download finished

always @(posedge clk_sys) begin
	integer i;
	reg [15:0] c;
	dl_d <= ioctl_download;
	if (cart_dl && ioctl_wr) begin
		c = (ioctl_addr == 0) ? 16'hFFFF : cart_crc;
		c = c ^ {ioctl_dout, 8'h00};
		for (i = 0; i < 8; i = i + 1)
			c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
		cart_crc <= c;
	end
end

// ---- CRC -> profile ---------------------------------------------------------
// Add a cartridge by printing its CRC (tools/cart-crc.sh) and adding a line.
// start_key is what the gamepad's Start button presses on keypad A -- the key
// the manual says begins the headline game (Readme "How to play"). Every
// measured cartridge starts from keypad A, so Start only ever lands there.
// Most carts start on 1, so that is both the default and the no-cart value.
reg [3:0] start_key = 4'd1;
always @(posedge clk_sys) begin
	if (dl_done) begin
		case (cart_crc)
			16'h977C: begin map_profile <= MAP_SPACEWAR; start_key <= 4'd1; end // TV Arcade I - Space War
			16'h88FB: begin map_profile <= MAP_PADDLE;   start_key <= 4'd2; end // TV Arcade III - Tennis + Squash (2 = Tennis)
			16'hF837: begin map_profile <= MAP_BASEBALL; start_key <= 4'd0; end // TV Arcade IV - Baseball
			16'hD3E2: begin map_profile <= MAP_CROSS;    start_key <= 4'd1; end // Pinball
			16'hE153: begin map_profile <= MAP_CROSS;    start_key <= 4'd1; end // Speedway + Tag (Europe)
			16'hD0DA: begin map_profile <= MAP_CROSS;    start_key <= 4'd1; end // Speedway + Tag (USA)
			16'hD13E: begin map_profile <= MAP_CROSS;    start_key <= 4'd1; end // Star Wars
			16'h3CDC: begin map_profile <= MAP_CROSS;    start_key <= 4'd1; end // Gunfighter + Moonship Battle
			// Paul Robson's homebrew (refs/studio2-games): all use 0 to fire or
			// start, so CROSS's fire-on-5 is wrong for every one of them. Both
			// the .st2 and its .bin conversion are listed -- the CRC covers the
			// file as downloaded, header and all, so the formats hash apart.
			16'hFBEF, 16'h2B4D: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd5; end // Asteroids
			16'hAEC7, 16'hE080: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd5; end // Berzerk
			16'h188E, 16'hD87F: begin map_profile <= MAP_HB2P;     start_key <= 4'd1; end // Combat (G? code, then B0)
			16'h4F55, 16'hD5DE: begin map_profile <= MAP_HB2P;     start_key <= 4'd1; end // Hockey (1 = hockey)
			16'h5AC5, 16'h2D86: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd0; end // Invaders (0 = restart)
			16'hDFCF, 16'h8551: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd0; end // Kaboom
			16'h5359, 16'hE00A: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd0; end // Pacman
			16'hE45F, 16'h1280: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd6; end // Scramble
			default:  begin map_profile <= MAP_CROSS;    start_key <= 4'd1; end // unknown cart: the common case
		endcase
	end
end

// ---- built-in games -------------------------------------------------------
// With no cartridge there is nothing to CRC, so the five BIOS games are told
// apart by the key that starts them (service manual pp.7-8): A1 Doodles,
// A2 Patterns, A3 Freeway, A4 Bowling, A5 Addition. Only the *first* such press
// after reset counts -- those keys are reused during play (A5 rolls the ball in
// Bowling, for instance). Detection reads the keyboard vector rather than the
// joystick-merged one, both because you pick the game before a profile exists
// and to keep this out of the joystick combinational path.

wire       no_cart = (cart_crc == 16'hFFFF);
reg        builtin_sel;
reg  [3:0] builtin_profile;

always @(posedge clk_sys) begin
	if (reset) begin
		builtin_sel     <= 1'b0;
		builtin_profile <= MAP_NONE;
	end
	else if (no_cart && !builtin_sel) begin
		if      (playerA[1]) begin builtin_profile <= MAP_CROSS;   builtin_sel <= 1'b1; end  // Doodles
		else if (playerA[2]) begin builtin_profile <= MAP_CROSS;   builtin_sel <= 1'b1; end  // Patterns
		else if (playerA[3]) begin builtin_profile <= MAP_FREEWAY; builtin_sel <= 1'b1; end  // Freeway
		else if (playerA[4]) begin builtin_profile <= MAP_BOWLING; builtin_sel <= 1'b1; end  // Bowling
		else if (playerA[5]) begin builtin_profile <= MAP_NONE;    builtin_sel <= 1'b1; end  // Addition: digits
	end
end

// ---- effective profile: OSD override wins over auto-detection ---------------
wire [3:0] auto_profile = no_cart ? builtin_profile : map_profile;
// OSD list is Auto, Cross, Paddle, Space War, Freeway, Bowling, Baseball,
// Homebrew -- after Auto those line up 1:1 with MAP_CROSS..MAP_HOMEBREW, so no
// adjustment is needed. MAP_HB2P is CRC-selected only.
wire [3:0] profile      = (joy_override == 3'd0) ? auto_profile : {1'b0, joy_override};

// ---- profile -> keypad presses ---------------------------------------------
// Each profile is two halves: the keys it lands on keypad A and on keypad B.
// Which stick drives the B half is the Players setting. One player runs the
// whole machine from stick 0 (Space War fires on pad A and steers on pad B);
// two players get one stick per pad. Auto keeps each profile's natural
// default, which is exactly the behaviour the joystick regression verified:
// the asymmetric single-player profiles (Space War, Freeway, Bowling) act as
// one-player, the symmetric ones (Cross, Paddle, Baseball) as two.

function automatic [9:0] map_padA(input [3:0] prof, input [31:0] j);
	reg [9:0] k;
	begin
		k = 10'd0;
		case (prof)
		MAP_CROSS: begin                     // the MPT-02 joystick layout
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;           // Extra
		end
		MAP_PADDLE: begin                    // racquet moves on 2/8 only
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[5]) k[0] = 1'b1;           // Extra: 0 pauses/resumes Tennis
		end
		MAP_SPACEWAR:                        // fire
			if (j[4]) k[2] = 1'b1;
		MAP_FREEWAY: begin                   // throttle/brake
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
		end
		MAP_BOWLING: begin                   // roll straight, or hook up/down
			if (j[4]) k[5] = 1'b1;
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
		end
		MAP_BASEBALL:                        // bat
			if (j[4]) k[5] = 1'b1;
		MAP_HOMEBREW: begin
			// 8-way: a held diagonal is its corner key (Berzerk moves on
			// 1/3/7/9), a cardinal is the cross. The corner keys are unused
			// in the 4-way homebrews, so a passing diagonal is harmless.
			case (j[3:0])
			4'b1010: k[1] = 1'b1;            // up+left
			4'b1001: k[3] = 1'b1;            // up+right
			4'b0110: k[7] = 1'b1;            // down+left
			4'b0101: k[9] = 1'b1;            // down+right
			default: begin
				if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
				if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			end
			endcase
		end
		MAP_HB2P: begin                      // own pad: cross + fire on 0
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[0] = 1'b1;
		end
		default: ;
		endcase
		map_padA = k;
	end
endfunction

function automatic [9:0] map_padB(input [3:0] prof, input [31:0] j);
	reg [9:0] k;
	begin
		k = 10'd0;
		case (prof)
		MAP_CROSS: begin                     // the MPT-02 joystick layout
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;           // Extra
		end
		MAP_PADDLE: begin
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[5]) k[0] = 1'b1;           // Extra: 0 pauses/resumes Tennis
		end
		MAP_SPACEWAR: begin                  // steering
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
		end
		MAP_FREEWAY: begin                   // steering
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
		end
		MAP_BASEBALL: begin                  // pitch
			if (j[4]) k[5] = 1'b1;
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
		end
		MAP_HOMEBREW: begin
			// Fire is 0 on the right pad -- never A0, which restarts Invaders.
			// The cross is repeated here because Pacman reads "down" on B8;
			// pad B directions are unused in the other one-player homebrews.
			if (j[4]) k[0] = 1'b1;
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
		end
		MAP_HB2P: begin                      // own pad: cross + fire on 0
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[0] = 1'b1;
		end
		default: ;                           // Bowling: keypad B unused
		endcase
		map_padB = k;
	end
endfunction

wire profile_1p = (profile == MAP_SPACEWAR) || (profile == MAP_FREEWAY) ||
                  (profile == MAP_BOWLING)  || (profile == MAP_NONE) ||
                  (profile == MAP_HOMEBREW);
wire one_player = (players == 2'd1) || ((players == 2'd0) && profile_1p);

// Direct A0..A9/B0..B9 bindings and Start work from either stick: MiSTer maps
// each input device independently, so a binding only exists where the user
// made one. Start presses the cartridge's start key on keypad A.
reg [9:0] directA, directB;
integer dk;
always @* begin
	for (dk = 0; dk < 10; dk = dk + 1) begin
		directA[dk] = joystick_0[8+dk]  | joystick_1[8+dk];
		directB[dk] = joystick_0[18+dk] | joystick_1[18+dk];
	end
end
wire       start_press = joystick_0[6] | joystick_1[6];
wire [9:0] start_keys  = start_press ? (10'd1 << start_key) : 10'd0;

wire [9:0] joyA = map_padA(profile, joystick_0) | directA | start_keys;
wire [9:0] joyB = (one_player ? map_padB(profile, joystick_0)
                              : map_padB(profile, joystick_1)) | directB;

////////////////// CPU //////////////////////////////////////////////////////////////////

// EF4=player B, EF3=player A, EF2 unused (high), EF1=1861 display status. Only keys 0-9 exist, so
// guard the index: keylatch 10-15 used to read off the end of the 10-bit playerA/playerB vectors.
wire  [3:0] EF;
wire        key_valid = (keylatch < 4'd10);
wire  [9:0] padA = playerA | joyA | osk_a;
wire  [9:0] padB = playerB | joyB | osk_b;
assign EF = {key_valid & padB[keylatch], key_valid & padA[keylatch], 1'b1, EFx};

// The Studio II has no input port that returns data -- the keypads are read through EF3/EF4,
// and INP 1 only toggles the display, discarding the byte. Tie the CPU's input bus off
// explicitly at 0 (what synthesis was silently defaulting to) rather than leave it undriven.
wire [7:0] cpu_din = 8'h00;
reg  [7:0] cpu_dout;
wire       Q;
wire       unsupported;
wire [2:0] io_n;
wire       io_inp;
wire       io_out;

reg [15:0] cpu_ram_addr;
reg  [7:0] cpu_ram_din;
reg  [7:0] cpu_ram_dout;

reg WAIT_N      = 1'b1;   // Clear=1, Wait=1 is Run. Was 0, which only worked because cdp1802.v
                          // had its run/pause test inverted; both are fixed now.

// ---- CPU machine-cycle enable -------------------------------------------------------------
// The CDP1861 shifts one pixel per CPU clock and a 1802 machine cycle is 8 clocks, so the CPU
// advances one state every 8 pixel times. Deriving this from ce_pix rather than counting clk_sys
// keeps it correct whatever clk_sys is running at. 112 pixels x 262 lines / 8 = 3668 machine
// cycles per frame, which is what a real Studio II gets.
reg  [2:0] cpu_div = 3'd0;
wire       cpu_ce  = ce_pix & (cpu_div == 3'd7);
always @(posedge clk_sys) begin
	if (reset)       cpu_div <= 3'd0;
	else if (ce_pix) cpu_div <= cpu_div + 3'd1;
end
reg dma_in_req  = 1'b0;
//reg dma_out_req = 1'b0;

//wire TPA;
//wire TPB;
wire MWR_N;
wire MRD_N;
cdp1802 cdp1802 (
  .CLOCK        (clk_sys),
  .clk_enable   (cpu_ce),
  .CLEAR_N      (~reset),

  .Q            (Q),            // O external pin Q Turns the sound off and on. When logic '1', the beeper is on.
  .EF           (EF),           // I 3:0 external flags EF1 to EF4

  .WAIT_N       (WAIT_N),       // I
  .INT_N        (~INT),         // I
  .dma_in_req   (dma_in_req),   // I
  .dma_out_req  (DMAO),         // I  TODO: check
  .SC           (SC),           // O

  .io_din       (cpu_din),      // I
  .io_dout      (cpu_dout),     // O
  .io_n         (io_n),         // O 2:0 IO control lines: N2,N1,N0  (N0 used for display on/off)
  .io_inp       (io_inp),       // O IO input signal
  .io_out       (io_out),       // O IO output signal

  .unsupported  (unsupported),  // O

  .ram_rd       (ram_rd),       // O MRD_N
  .ram_wr       (ram_wr),       // O MWR_N
  .ram_a        (ram_a),        // O cpu_ram_addr
  .ram_q        (ram_q),        // I DI
  .ram_d        (ram_d)        // O cpu_ram_dout

  //.TPA          (TPA),          // O Timing Pulse  (RAM)
  //.TPB          (TPB)           // O Timing Pulse  (IO)
);
/*
cosmac cosmac (
   .clk         (clk_sys),     // I
   .clk_enable  (1'b1),        // I
   .clear       (~reset),      // I
   .dma_in_req  (dma_in_req),  // I
   .dma_out_req (dma_out_req), // I
   .int_req     (INT_N),       // I
   .wait_req    (wait_req),    // I
   .ef          (EF),          // I [4:1]
   .data_in     (ram_q),       // I [7:0]
   .data_out    (ram_d),       // O [7:0]
   .address     (ram_a),       // O [15:0]
   .mem_read    (ram_rd),      // O
   .mem_write   (ram_wr),      // O
   .io_port     (io_n),        // O [2:0]
   .q_out       (Q),           // O
   .sc          (SC)           // O [1:0]
);
*/

////////////////// RAM //////////////////////////////////////////////////////////////////

reg          ram_cs;
reg          ram_rd; // RAM read enable
reg          ram_wr; // RAM write enable
reg   [7:0]  ram_d;  // RAM write data
reg  [15:0]  ram_a;  // RAM address
reg   [7:0]  ram_q;  // RAM read data

/*
wire  [7:0]  romDo_StudioII;
wire [11:0]  romA;

rom #(.AW(11), .FN("../rom/studio2.hex")) Rom_StudioII
(
	.clock      (clk_sys        ),
	.ce         (1'b1           ),
	.data_out   (romDo_StudioII ),
	.a          (romA[10:0]     )
);
*/////////

reg cpu_wr;
//reg clk_mem;
//assign clk_mem = ioctl_download ? clk_vid : clk_sys;
assign cpu_wr = (ram_a[11:0] >= 12'h800 && ram_a[11:0] < 12'hA00) ? ram_wr : 1'b0;


////////////////// SOUND ////////////////////////////////////////////////////
//
// The Studio II beeper is an NE555 astable gated by the 1802's Q line (SEQ/REQ).
// Per docs/sound.txt the control pin is tied to 0V through a 10uF electrolytic,
// which decays the pitch to about half over ~0.4s -- that droop is the "warpy"
// power-up sound, and it is what makes it recognisable. MAME just uses a fixed
// 300Hz beeper and flags the discrete circuit as unimplemented, so this follows
// the hardware description instead.
//
// ce_pix is the 1861 pixel rate (~1.76MHz), which is also the CPU clock, so:
//   625Hz  -> half period 1.76e6/(2*625) ~= 1408 ticks
//   312Hz  -> 2816 ticks
//   0.4s   -> ~704000 ticks, so step the half period every ~500; 512 is close
//             enough and is a free shift.

localparam [15:0] SND_HALF_MIN = 16'd1408;   // ~625 Hz, freshly gated on
localparam [15:0] SND_HALF_MAX = 16'd2816;   // ~312 Hz, fully decayed

reg [15:0] snd_half;
reg [15:0] snd_cnt;
reg  [8:0] snd_decay;
reg        snd_out;

always @(posedge clk_sys) begin
	if (reset) begin
		snd_half  <= SND_HALF_MIN;
		snd_cnt   <= 16'd0;
		snd_decay <= 9'd0;
		snd_out   <= 1'b0;
	end
	else if (ce_pix) begin
		if (!Q) begin                                  // gated off: recharge, output idle
			snd_half  <= SND_HALF_MIN;
			snd_cnt   <= 16'd0;
			snd_decay <= 9'd0;
			snd_out   <= 1'b0;
		end
		else begin
			snd_decay <= snd_decay + 1'b1;
			if (&snd_decay && (snd_half < SND_HALF_MAX)) snd_half <= snd_half + 1'b1;
			if (snd_cnt >= snd_half) begin
				snd_cnt <= 16'd0;
				snd_out <= ~snd_out;
			end
			else snd_cnt <= snd_cnt + 1'b1;
		end
	end
end

assign audio = snd_out;

////////////////// CARTRIDGE LOADER /////////////////////////////////////////
//
// Raw .bin/.rom images are a flat copy to $0400. .st2 images are paged: a
// 256-byte header followed by 256-byte blocks, each block's target page taken
// from the table at header offsets 64-127 (docs/cartridge.txt).
//
// The format is detected purely from the "RCA2" magic in the first four bytes.
// The OSD extension index (ioctl_index[7:6]) is deliberately NOT used: a valid
// .st2 always carries the magic, so the extension adds nothing, and going on the
// magic alone means a mis-named or mis-picked file still loads correctly. The
// CONF_STR entry "F1,ST2BINROM" exists so the file browser offers all three.
//
// Reference implementation, verified against 46 cartridges:
// refs/rca-studio2/studio2-games/studio2/cpu.c  CPU_LoadST2Image().

wire        bios_dl = ioctl_download && (ioctl_index[5:0] == 6'd0);
wire        cart_dl = ioctl_download && (ioctl_index[5:0] == 6'd1);

reg  [2:0]  st2_magic;                  // running match on "RCA"
reg         st2_mode;                   // "RCA2" seen: treat as paged
reg  [7:0]  st2_page [0:63];            // page table, header offsets 64..127

always @(posedge clk_sys) begin
	if (!ioctl_download) begin
		st2_magic <= 3'b000;
		st2_mode  <= 1'b0;
	end
	else if (cart_dl && ioctl_wr) begin
		case (ioctl_addr[15:0])
			16'd0: st2_magic[0] <=  (ioctl_dout == 8'h52);                    // 'R'
			16'd1: st2_magic[1] <=  (ioctl_dout == 8'h43) & st2_magic[0];     // 'C'
			16'd2: st2_magic[2] <=  (ioctl_dout == 8'h41) & st2_magic[1];     // 'A'
			16'd3: st2_mode     <=  (ioctl_dout == 8'h32) & st2_magic[2];     // '2'
			default: ;
		endcase
		if (ioctl_addr >= 16'd64 && ioctl_addr < 16'd128)
			st2_page[ioctl_addr[5:0]] <= ioctl_dout;
	end
end

// Byte at ioctl_addr belongs to block (addr>>8)-1; its page comes from the table.
wire  [5:0] st2_blk   = ioctl_addr[13:8] - 6'd1;
wire  [7:0] st2_pg    = st2_page[st2_blk];

// A page is loadable if it is cartridge space inside the 4k bank we model: not the
// system ROM ($00-$03), not RAM ($08-$09), and below $10. $0C/$0D ARE legal --
// race.st2 pages ROM over the default RAM mirror there, which is why the memory
// map calls $C00-$DFF "RAM/ROM". $00 is also the format's "unused block" marker.
wire        st2_pg_ok = (st2_pg[7:4] == 4'h0) && (st2_pg[3:0] > 4'h3)
                        && (st2_pg[3:0] != 4'h8) && (st2_pg[3:0] != 4'h9);

wire        st2_data  = ioctl_addr >= 16'd256;          // past the header
wire [11:0] cart_a    = st2_mode ? {st2_pg[3:0], ioctl_addr[7:0]}
                                 : (ioctl_addr[11:0] + 12'h400);
wire        cart_we   = cart_dl && ioctl_wr && (!st2_mode || (st2_data && st2_pg_ok));

wire [11:0] dl_a  = bios_dl ? ioctl_addr[11:0] : cart_a;
wire        dl_we = bios_dl ? ioctl_wr : cart_we;

dpram #(8, 12) dpram
(
	.clock(clk_sys),
	.ram_cs(1'b1),
	.address_a(ioctl_download ? dl_a : ram_a[11:0]),
	.wren_a(dl_we | cpu_wr),
	.data_a(ioctl_download ? ioctl_dout : ram_d),
	.q_a(ram_q),

	// Port B was only ever the 1861's RAM scraper; the real part is fed by the CPU over DMA.
	.ram_cs_b(1'b0),
	.wren_b(1'b0),
	.address_b(12'd0),
	.data_b(),
	.q_b()
);

////////////////// DMA //////////////////////////////////////////////////////////////////

//0000-02FF	ROM 	      RCA System ROM : Interpreter
//0300-03FF	ROM	        RCA System ROM : Always present
//0400-07FF	ROM	        Games Programs, built in (no cartridge)
//0400-07FF	Cartridge	  Cartridge Games (when cartridge plugged in)
//0800-08FF	RAM	        System Memory, Program Memory etc.
//0900-09FF	RAM	        Display Memory
//0A00-0BFF	Cartridge	  (MultiCart) Available for Cartridge games if required, probably isn't.
//0C00-0DFF	RAM/ROM	    Duplicate of 800-9FF - the RAM is double mapped in the default set up. 
//                      This RAM can be disabled and ROM can be put here instead, 
//                      so assume this is ROM for emulation purposes.
//0E00-0FFF	Cartridge	  (MultiCart) Available for Cartridge games if required, probably isn't.

/*
wire rom_cs   = ram_a ==? 16'b0000_00xx_xxxx_xxxx;
wire cart_cs  = ram_a ==? 16'b0000_01xx_xxxx_xxxx; 
wire pram_cs  = ram_a ==? 16'b0000_1000_xxxx_xxxx; 
wire vram_cs  = ram_a ==? 16'b0000_1001_xxxx_xxxx; 
wire mcart_cs = ram_a ==? 16'b0000_101x_xxxx_xxxx; 
*/

//wire [15:0] AB = dma_busy ? dma_addr : ram_a;
//wire  [7:0] DO = dma_busy ? dma_dout : ram_d;
//wire pram_we = pram_cs ? dma_busy ? ~dma_write : ~ram_wr : 1'b1;
//wire vram_we = vram_cs ? dma_busy ? ~dma_write : ~ram_wr : 1'b1;

/*
always @(negedge clk_sys) begin
  DI <= rom_cs   ? ram_d :
        cart_cs  ? ram_d :
        pram_cs  ? ram_d :
        vram_cs  ? ram_d :        
        mcart_cs ? ram_d : 
        8'hff;     
end
*/

//reg        portb_ce;
//reg        portb_wr;
//reg  [7:0] portb_din;
//reg  [7:0] portb_dout;
//reg [15:0] portb_addr;
//always @(posedge clk_sys) begin
//  portb_ce  <= 1'b0;
//  portb_wr  <= 1'b0;
//  if(ioctl_download) begin
//    portb_ce   <= ioctl_download;
//    portb_wr   <= ioctl_wr;
//    portb_din  <= ioctl_dout;
//    portb_addr <= ioctl_index==0 ? ioctl_addr[15:0] : (16'h0400 + ioctl_addr[15:0]);
//  end
//  else if(vram_addr >= 'h0900) begin
//    portb_ce   <= 1'b1;
//    portb_addr <= vram_addr;
//    video_din  <= portb_dout;        
//  end
//end

// internal games still there if (0x402==2'hd1 && 0x403==2'h0e && 0x404==2'hd2 && 0x405==2'h39)
// 0x40e = game 1
// 0x439 = game 2
// 0x48b = game 3
// 0x48d = game 4
// 0x48f = game 5
/*
wire        dma_rdy = DMAO;
reg         dma_ctrl = 1'b1;
reg  [15:0] dma_addr;
reg   [7:0] DI;
wire  [7:0] dma_dout;
reg   [7:0] dma_length = 8'b1;

dma dma (
  .clk      (clk_sys),      // I
  .rdy      (dma_rdy),      // I
  .ctrl     (dma_ctrl),     // I
  .src_addr (ram_a),        // I 15:0
  .dst_addr (ram_a),        // I 15:0
  .addr     (dma_addr),     // O 15:0 => to AB
  .din      (DI),           // I 7:0
  .dout     (dma_dout),     // I 7:0
  .length   (dma_length),   // I
  .busy     (dma_busy),     // O
  .sel      (dma_sel),      // O
  .write    (dma_write)     // O
);
*/
/////////////////////////////////////////////////////////////////////////////////////////

endmodule
