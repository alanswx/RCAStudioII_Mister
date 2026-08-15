//============================================================================
//
//  RCA Studio II core glue: CPU + CDP1861 + RAM + keypad.
//
//  Original implementation by Jason Coombes (JasonA-dev), 2022, with MiSTer
//  framework integration by Flandango. Extended 2026 by Alan Steremberg and
//  Elle Ball.
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
	input        [3:0] joy_override,   // OSD "Joystick" row: the profile to use when joy_manual
	input              joy_manual,     // OSD "Mapping": 0 = auto-detect, 1 = use joy_override
	output       [3:0] auto_profile,   // the detected profile, for the top level to show in the OSD
	input        [1:0] players,        // OSD: 0 = auto, 1 = one player, 2 = two players
	input        [9:0] osk_a,          // on-screen keypad presses for keypad A (bit = key)
	input        [9:0] osk_b,          // and for keypad B
	input  reg         ce_pix,
	input              clear_key,      // CLEAR button input from top-level; keep video alive during CLEAR

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
    .reset      (reset & ~clear_key),      // I: keep pixie running while CLEAR (clear_key==1) so VSYNC doesn't lose sync

    .clk_enable (ce_pix),     // I
    .cpu_ce     (cpu_ce),     // I  CPU machine-cycle enable, for sampling DMA bytes

    .SC         (SC),         // I [1:0]
    // INP 1 turns the display on, OUT 1 turns it off (the BIOS enables it via CALL $0066). These
    // were tied on/off, so the display could never be disabled and the 1861 started generating
    // interrupts from reset instead of from the moment the BIOS enabled it. The earlier commented
    // version keyed off io_n[0] alone, which cannot tell INP 1 from OUT 1.
    .disp_on    (io_inp && (io_n == 3'd1)),  // I
    .disp_off   ((io_out && (io_n == 3'd1)) || clear_key),  // I: also blank display while CLEAR is asserted


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
// CROSS, the MPT-02's own layout -- never in HOMEBREW, where A0 restarts
// Invaders.
// A0..B9 are direct per-key bindings with no default mapping: they are inert
// until the user binds them in Define Buttons, and then they always work, on
// top of whatever profile is active.

// The profile is 4 bits internally; the OSD override (joy_override) is 4, so
// the menu can force any of the 16 encoded profiles, including Gunfighter.
// Keep the numeric values aligned with the OSD list so a user selection selects
// the correct profile. PADDLE is distinct from CROSS, which remains the default
// for the retail Tennis/Squash cartridge.
localparam [3:0] MAP_NONE       = 4'd0;   // no controller mapping; keep keypad/OSK input only
localparam [3:0] MAP_CROSS      = 4'd1;   // 2/8/4/6 + 5 fire, both pads
localparam [3:0] MAP_SPACEWAR   = 4'd2;   // fire A2, steer B4/B6
localparam [3:0] MAP_FREEWAY    = 4'd3;   // steer B4/B6, throttle A2, brake A8
localparam [3:0] MAP_BOWLING    = 4'd4;   // roll A5, hook A2/A8
localparam [3:0] MAP_BASEBALL   = 4'd5;   // bat A5; pitch B5 straight, B2/B8 curve
localparam [3:0] MAP_HOMEBREW   = 4'd6;   // Paul Robson's 1P games: 8-way on pad A
                                          // (diagonals are keys 1/3/7/9), fire B0
localparam [3:0] MAP_GUNFIGHTER = 4'd7;   // vertical cross: 2/8 + fire 5, one-player
localparam [3:0] MAP_8WAY       = 4'd8;   // CROSS plus diagonals: 1/3/7/9, fire 5 + extra 0
localparam [3:0] MAP_DOODLES    = 4'd9;   // Doodles/Patterns: B-side 8-way, fire 5, extra 0
localparam [3:0] MAP_HB2P       = 4'd10;  // 2P homebrew (Hockey, Combat): cross plus
                                          // fire-on-0, each player's own pad. Normally
                                          // chosen by CRC, but also exposed in the OSD
                                          // list as "2P Homebrew" for manual override.
localparam [3:0] MAP_CLEAR_ONLY = 4'd11;  // explicit no-controller mapping: only Clear/Select
                                          // from the pad; numstick/keyboard still work.
localparam [3:0] MAP_PADDLE     = 4'd12;  // homebrew tennis.st2: single-player, keypad B
                                          // only. Up/down map to 2/8; left/fire/right map
                                          // to the one-time racket-size choices B4/B5/B6.

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
	if (cart_dl && ioctl_download && !dl_d) begin
		cart_crc <= 16'hFFFF;
	end
	if (cart_dl && ioctl_wr) begin
		c = (ioctl_addr == 0) ? 16'hFFFF : cart_crc;
		c = c ^ {ioctl_dout, 8'h00};
		for (i = 0; i < 8; i = i + 1)
			c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
		cart_crc <= c;
	end
end

// ---- CRC → profile + Start key ------------------------------------------------
// Add a cartridge by running tools/cart-crc.sh and dropping one line into the
// matching group below.  Groups are ordered by (map_profile, start_key) so
// related dumps stay together.  Comments list the human names.
//
// start_key is the keypad-A digit that the gamepad Start button presses.
// Default / no-cart = 1 (most common).

reg [3:0] start_key = 4'd1;

always @(posedge clk_sys) begin
	if (dl_done) begin
		case (cart_crc)
			// Space War
			16'h977C, 16'h45B5: begin map_profile <= MAP_SPACEWAR; start_key <= 4'd1; end

			// Tennis/Squash
			16'h88FB: begin map_profile <= MAP_CROSS; start_key <= 4'd2; end

			// Pinball / Speedway / Star Wars
			16'hD3E2, 16'h92BA,
			16'hE153, 16'hD0DA, 16'h8404,
			16'hD13E, 16'h03E6: begin map_profile <= MAP_CROSS; start_key <= 4'd1; end

			// Baseball
			16'hF837, 16'h2526: begin map_profile <= MAP_BASEBALL; start_key <= 4'd0; end

			// Gunfighter
			16'h3CDC, 16'h043E: begin map_profile <= MAP_GUNFIGHTER; start_key <= 4'd1; end

			// Homebrew
			16'h1943, 16'hFBEF, 16'h2B4D: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd5; end // Asteroids
			16'h4F61, 16'hAEC7, 16'hE080: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd5; end // Berzerk
			16'h69AA, 16'h5AC5, 16'h2D86: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd0; end // Invaders
			16'h6793, 16'hDFCF, 16'h8551: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd0; end // Kaboom
			16'hC556, 16'h5359, 16'hE00A: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd0; end // Pacman
			16'hBA0B, 16'hE45F, 16'h1280: begin map_profile <= MAP_HOMEBREW; start_key <= 4'd6; end // Scramble

			// 2P Homebrew
			16'h4ADA, 16'h188E, 16'hD87F: begin map_profile <= MAP_HB2P; start_key <= 4'd1; end // Combat
			16'h114A, 16'h4F55, 16'hD5DE: begin map_profile <= MAP_HB2P; start_key <= 4'd1; end // Hockey

			// Other
			16'hFB76: begin map_profile <= MAP_PADDLE;     start_key <= 4'd1; end
			16'h1634, 16'hB76F: begin map_profile <= MAP_CLEAR_ONLY; start_key <= 4'd1; end
			16'hE4C4, 16'hD124, 16'h3EAF, 16'h0C03, 16'h92C7: begin
				map_profile <= MAP_8WAY; start_key <= 4'd1;
			end

			default: begin map_profile <= MAP_8WAY; start_key <= 4'd1; end
		endcase
	end
end

// ---- built-in games -------------------------------------------------------
// With no cartridge there is nothing to CRC, so the five BIOS games are told
// apart by the key that starts them (service manual pp.7-8): A1 Doodles,
// A2 Patterns, A3 Freeway, A4 Bowling, A5 Addition. Only the *first* such press
// after reset counts -- those keys are reused during play (A5 rolls the ball in
// Bowling, for instance). 

wire       no_cart = (cart_crc == 16'hFFFF);
reg        builtin_sel;
reg  [3:0] builtin_profile;

// Consider on-screen keypad (osk_a) as well as the physical keypad for
// selecting built-in games. Treat the on-screen keypad's key at
// active_start_key as a Start press so numstick users can activate by the OSK.
wire [9:0] builtin_padA = playerA | osk_a;
wire        builtin_start_press = start_press | osk_a[active_start_key];

always @(posedge clk_sys) begin
	if (reset) begin
		builtin_sel     <= 1'b0;
		builtin_profile <= MAP_NONE;
	end
	else if (no_cart && !builtin_sel) begin
		if      (builtin_padA[1] || (builtin_start_press && (active_start_key == 4'd1))) begin builtin_profile <= MAP_DOODLES; builtin_sel <= 1'b1; end  // Doodles: B-side 8-way
		else if (builtin_padA[2] || (builtin_start_press && (active_start_key == 4'd2))) begin builtin_profile <= MAP_DOODLES; builtin_sel <= 1'b1; end  // Patterns: B-side 8-way
		else if (builtin_padA[3]) begin builtin_profile <= MAP_FREEWAY; builtin_sel <= 1'b1; end  // Freeway
		else if (builtin_padA[4]) begin builtin_profile <= MAP_BOWLING; builtin_sel <= 1'b1; end  // Bowling
		else if (builtin_padA[5]) begin builtin_profile <= MAP_CLEAR_ONLY; builtin_sel <= 1'b1; end  // Addition: digits
	end
end

// ---- effective profile ------------------------------------------------------
// Two independent OSD rows now: "Mapping" chooses between auto-detection and
// the menu, and "Joystick" is the profile itself. There is no longer a magic
// "0 = auto" value inside the profile enum, so every one of the 16 encodings --
// MAP_NONE included -- is selectable, and the top level can display the
// detected profile in the same row the user would edit (see RCAStudioII.sv).
assign     auto_profile = no_cart ? builtin_profile : map_profile;
wire [3:0] profile      = joy_manual ? joy_override : auto_profile;

// ---- profile -> keypad presses ---------------------------------------------
// Each profile is two halves: the keys it lands on keypad A and on keypad B.
// Which stick drives the B half is the Players setting. One player runs the
// whole machine from stick 0 (Space War fires on pad A and steers on pad B);
// two players get one stick per pad. Auto keeps each profile's natural
// default, which is exactly the behaviour the joystick regression verified:
// the asymmetric single-player profiles (Space War, Freeway, Bowling) act as
// one-player, the symmetric ones (Cross, Baseball) as two.

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
		MAP_CLEAR_ONLY: ;                   // no controller presses: on-screen keypad
											  // and keyboard still work, but the stick stays quiet
		MAP_GUNFIGHTER: begin                // 2P behaves like CROSS; Auto/1P uses the
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;   // right-hand B-only mapping
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_8WAY: begin                      // CROSS + 8-way diagonals: 1/3/7/9 on corners
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
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_DOODLES: begin                   // Doodles/Patterns: B-side 8-way, single-player
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
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_PADDLE: ;                        // no A-side function: Start alone lives on
										  // keypad A, gameplay is entirely keypad B
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
		MAP_CLEAR_ONLY: ;                   // no controller presses: the on-screen keypad
											  // and keyboard still work, but the stick stays quiet
		MAP_GUNFIGHTER: begin                // 2P behaves like CROSS; Auto/1P uses the
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;   // right-hand B-only mapping
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_8WAY: begin                      // CROSS + 8-way diagonals: 1/3/7/9 on corners
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
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_DOODLES: begin                   // Doodles/Patterns: B-side 8-way, single-player
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
			if (j[4]) k[5] = 1'b1;
			if (j[5]) k[0] = 1'b1;
		end
		MAP_PADDLE: begin                    // vertical movement plus racket-size setup.
			if (j[3]) k[2] = 1'b1;   if (j[2]) k[8] = 1'b1;
			if (j[1]) k[4] = 1'b1;   if (j[0]) k[6] = 1'b1;
			if (j[4]) k[5] = 1'b1;
		end
		default: ;                           // Bowling: keypad B unused
		endcase
		map_padB = k;
	end
endfunction

wire profile_1p = (profile == MAP_SPACEWAR) || (profile == MAP_FREEWAY) ||
                  (profile == MAP_BOWLING)  || (profile == MAP_NONE) ||
                  (profile == MAP_HOMEBREW) || (profile == MAP_GUNFIGHTER) ||
                  (profile == MAP_8WAY)     || (profile == MAP_DOODLES) ||
                  (profile == MAP_CLEAR_ONLY) || (profile == MAP_PADDLE);
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
wire [3:0] active_start_key = ((profile == MAP_GUNFIGHTER) || (profile == MAP_DOODLES) || (profile == MAP_8WAY)) ? 4'd1 : start_key;
wire [9:0] start_keys       = ((profile != MAP_CLEAR_ONLY) && start_press) ? (10'd1 << active_start_key) : 10'd0;

// Gunfighter and 8WAY are the special cases: in Auto/1P they are B-only (2/4/6/8 +
// 5 + 0 on the right-hand pad) or 8-way on the B side, while in 2P they split exactly
// like CROSS across both pads. DOODLES and PADDLE are permanently B-only one-player
// profiles, so gamepad 0 drives them regardless of Players. The explicit Clear-only
// profile stays quiet unless the user binds a direct A/B key manually.
wire [9:0] joyA = ((profile == MAP_CLEAR_ONLY) ? 10'd0
                : ((profile == MAP_8WAY) && one_player) ? 10'd0
                : ((profile == MAP_GUNFIGHTER) && one_player) ? 10'd0
                : ((profile == MAP_DOODLES) ? 10'd0
                                          : ((profile == MAP_GUNFIGHTER) ? map_padA(MAP_CROSS, joystick_0)
                                                                        : map_padA(profile, joystick_0))));
wire [9:0] joyB = ((profile == MAP_CLEAR_ONLY) ? 10'd0
                : ((profile == MAP_8WAY) && one_player) ? map_padB(MAP_8WAY, joystick_0)
                : ((profile == MAP_GUNFIGHTER) && one_player) ? map_padB(MAP_CROSS, joystick_0)
                : (((profile == MAP_DOODLES) || (profile == MAP_PADDLE)) ? map_padB(profile, joystick_0)
                                          : ((profile == MAP_GUNFIGHTER) ? map_padB(MAP_CROSS, joystick_1)
                                                                        : (one_player ? map_padB(profile, joystick_0)
                                                                                       : map_padB(profile, joystick_1)))));
wire [9:0] joyA_active = joyA | directA | start_keys;
wire [9:0] joyB_active = joyB | directB;

////////////////// CPU //////////////////////////////////////////////////////////////////

// EF4=player B, EF3=player A, EF2 unused (high), EF1=1861 display status. Only keys 0-9 exist, so
// guard the index: keylatch 10-15 used to read off the end of the 10-bit playerA/playerB vectors.
wire  [3:0] EF;
wire        key_valid = (keylatch < 4'd10);
wire  [9:0] padA = playerA | joyA_active | osk_a;
wire  [9:0] padB = playerB | joyB_active | osk_b;
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

////////////////// MEMORY DECODE ////////////////////////////////////////////
//
// docs/memorymap.txt:
//
//   $0000-$07FF  ROM      system ROM, plus the built-in games at $0400-$07FF
//                         (a cartridge takes that half over when plugged in)
//   $0800-$09FF  RAM      512 bytes: system/program memory, then display memory
//   $0A00-$0BFF  cart     multicart window
//   $0C00-$0DFF  RAM/ROM  the RAM mirror by default; a cartridge may page ROM
//                         over it (asteroids/berzerk/pacman/scramble .st2 do)
//   $0E00-$0FFF  cart     multicart window
//
// The rule behind that table is one line: RAM answers wherever A9 = 0 and
// nothing else is decoded, which is why it also reappears at $0C00, $1000,
// $1400, $1800 and so on. A9 = 1 with no cartridge is open bus.
//
// This core previously had no decode at all -- one 4 KB array with the address
// truncated to ram_a[11:0] -- so $1000 read the system ROM, the $0C00 mirror
// did not exist, and a write at $0C00 was dropped.
//
// The ROM/cartridge image and the RAM are now separate arrays, so a cartridge
// can no longer be scribbled on and the mirror costs nothing.

wire         ram_rd; // MRD_N
wire         ram_wr; // MWR_N
wire  [7:0]  ram_d;  // CPU write data
wire [15:0]  ram_a;  // CPU address
wire  [7:0]  ram_q;  // data returned to the CPU (and to the 1861 during DMA)

// Which of pages $0A-$0F the loaded cartridge actually supplies. Only $0C/$0D
// change behaviour: with cartridge ROM paged there they are ROM, without it
// they are the RAM mirror. Cleared when a new cartridge starts downloading;
// deliberately not cleared on reset, since CLEAR does not unplug the cart.
reg  [7:0]  cart_page = 8'h00;    // indexed by address bits [10:8]: page $08..$0F

wire        bank0    = (ram_a[15:12] == 4'h0);
wire        rom_sel  = bank0 && !ram_a[11];                        // $0000-$07FF
wire        cart_sel = bank0 &&  ram_a[11] && cart_page[ram_a[10:8]];
wire        ram_sel  = !rom_sel && !cart_sel && !ram_a[9];         // the A9 = 0 mirror
wire        cpu_wr   = ram_wr && ram_sel;                          // RAM is the only writeable thing

// Both arrays have one cycle of latency, so the read mux select has to be
// delayed with the data. The CPU holds an address for a whole machine cycle
// (32 clk_sys), so a registered select is settled long before it is sampled.
wire [7:0]  rom_q;
wire [7:0]  sram_q;
reg         rom_sel_q, ram_sel_q;
always @(posedge clk_sys) begin
	rom_sel_q <= rom_sel | cart_sel;
	ram_sel_q <= ram_sel;
end
// Open bus reads back as $00. The reference emulator's PC build returns the
// zeroed byte of its flat 4 KB array for undecoded space, so this keeps the
// frame comparison in §9 honest; it is also the quiet answer for a DMA that
// wanders out of display RAM (blank scanline rather than a white one).
assign ram_q = ram_sel_q ? sram_q : (rom_sel_q ? rom_q : 8'h00);


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

// Measured from refvideo/ rather than taken from docs/sound.txt, whose component
// values do not give a sane frequency. Spectral analysis of the Star Wars direct
// capture puts the fundamental at 545-549 Hz across every beep (the obvious
// zero-crossing answer, ~1570 Hz, is the harmonics -- a 555's asymmetric duty
// cycle gives strong even harmonics, and the TV audio path thins the fundamental).
localparam [15:0] SND_HALF_MIN = 16'd1609;   // ~547 Hz, freshly gated on
localparam [15:0] SND_HALF_MAX = 16'd3218;   // ~274 Hz, fully decayed

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

// Pages $0A-$0F, the ones the decode has to be told about. Pages $08/$09 are
// RAM and can never be claimed: st2_pg_ok already rejects them, and the
// (A10|A9) term means an over-long raw .bin cannot claim them either.
wire        cart_hi   = cart_a[11] && (cart_a[10] | cart_a[9]);

always @(posedge clk_sys) begin
	if (cart_dl && ioctl_wr && (ioctl_addr == 0)) cart_page <= 8'h00;   // new cartridge
	if (cart_we && cart_hi)                       cart_page[cart_a[10:8]] <= 1'b1;
end

wire [11:0] dl_a  = bios_dl ? ioctl_addr[11:0] : cart_a;
wire        dl_we = bios_dl ? ioctl_wr : cart_we;

// The ROM/cartridge image: system ROM at $0000-$07FF, then whatever the
// cartridge pages into $0800-$0FFF. Read-only to the CPU.
dpram #(8, 12) dpram
(
	.clock(clk_sys),
	.ram_cs(1'b1),
	.address_a(ioctl_download ? dl_a : ram_a[11:0]),
	.wren_a(dl_we),
	.data_a(ioctl_dout),
	.q_a(rom_q),

	// Port B was only ever the 1861's RAM scraper; the real part is fed by the CPU over DMA.
	.ram_cs_b(1'b0),
	.wren_b(1'b0),
	.address_b(12'd0),
	.data_b(),
	.q_b()
);

// The 512 bytes of RAM: $0800-$08FF program/system, $0900-$09FF display.
// Selected by A9 = 0, so the address inside it is just A8-A0.
// Add a port-B writer used to clear VRAM on CLEAR without resetting the Pixie
reg [8:0] clear_addr_b = 9'd0;
reg       clear_active = 1'b0;
reg       ram_cs_b_sig = 1'b0;
reg       wren_b_sig = 1'b0;
reg [8:0] address_b_sig = 9'd0;
reg [7:0] data_b_sig = 8'd0;

always @(posedge clk_sys) begin
    // Default: inactive
    ram_cs_b_sig <= 1'b0;
    wren_b_sig  <= 1'b0;
    address_b_sig <= 9'd0;
    data_b_sig <= 8'd0;

    // Start a clear sequence when CLEAR is asserted (and not already active)
    if (clear_key && !clear_active) begin
        clear_active <= 1'b1;
        clear_addr_b <= 9'd256; // VRAM starts at offset 256 in the 512-byte RAM
    end
    else if (clear_active) begin
        // Write zero to current VRAM address
        ram_cs_b_sig <= 1'b1;
        wren_b_sig   <= 1'b1;
        address_b_sig <= clear_addr_b;
        data_b_sig   <= 8'd0;
        if (clear_addr_b == 9'd511) begin
            // Finished clearing VRAM; deassert clear_active on next cycle
            clear_active <= 1'b0;
        end
        else begin
            clear_addr_b <= clear_addr_b + 1'b1;
        end
    end
end

dpram #(8, 9) sram
(
	.clock(clk_sys),
	.ram_cs(1'b1),
	.address_a(ram_a[8:0]),
	.wren_a(cpu_wr),
	.data_a(ram_d),
	.q_a(sram_q),

	.ram_cs_b(ram_cs_b_sig),
	.wren_b(wren_b_sig),
	.address_b(address_b_sig),
	.data_b(data_b_sig),
	.q_b()
);


endmodule
