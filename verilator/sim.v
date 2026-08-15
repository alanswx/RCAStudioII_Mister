`timescale 1ns/1ns
// top end ff for verilator

module top(

   input clk_48 /*verilator public_flat*/,
   input clk_24,
   input [11:0]  inputs/*verilator public_flat*/,
   input [31:0]  joystick_0/*verilator public_flat*/,
   input [31:0]  joystick_1/*verilator public_flat*/,
   input [3:0]   joy_override/*verilator public_flat*/,
   input         joy_manual/*verilator public_flat*/,
   input [1:0]   players/*verilator public_flat*/,

   output [7:0] VGA_R/*verilator public_flat*/,
   output [7:0] VGA_G/*verilator public_flat*/,
   output [7:0] VGA_B/*verilator public_flat*/,
   
   output VGA_HS,
   output VGA_VS,
   output VGA_HB,
   output VGA_VB,
   output VGA_DE,

   output [15:0] AUDIO_L,
   output [15:0] AUDIO_R,
   
   input        ioctl_download,
   input        ioctl_upload,
   input        ioctl_wr,
   input [24:0] ioctl_addr,
   input [7:0]  ioctl_dout,
   input [7:0]  ioctl_din,   
   input [7:0]  ioctl_index,
   output  reg  ioctl_wait=1'b0,

   input [10:0] ps2_key   
);
   
   // Core inputs/outputs
wire audio;   // 1-bit beeper, gated by the 1802's Q line
   wire [3:0] led/*verilator public_flat*/;

   wire VSync, HSync;
   wire VBlank, HBlank;
   wire video_de;

   assign VGA_VS = VSync;
   assign VGA_HS = HSync;
   assign VGA_VB = VBlank;
   assign VGA_HB = HBlank;
   assign VGA_DE = video_de;

   // Convert 1bpp output to 8bpp
   wire video;
   assign VGA_R = video ? 'hFF : 'h00;
   assign VGA_G = video ? 'hFF : 'h00;
   assign VGA_B = video ? 'hFF : 'h00;
    
   // MAP OUTPUTS
   assign AUDIO_L = audio ? 16'sd6000 : -16'sd6000;
   assign AUDIO_R = AUDIO_L;

// The sim keeps ce_pix tied high: one pixel per clk_48 edge. Frame content is
// identical to hardware (everything inside the core is gated on ce_pix), the
// sim just doesn't burn 4 host cycles per pixel. RCAStudioII.sv divides by 4
// for the real 1.76MHz timebase.
wire ce_pix = 1'b1;
wire reset = ioctl_download;

wire key_strobe = old_keystb ^ ps2_key[10];
reg old_keystb = 0;
always @(posedge clk_48) old_keystb <= ps2_key[10];

rcastudioii rcastudio
(
	.clk_sys(clk_48),
	.reset(reset),
	
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),

	.ps2_key(ps2_key),
	.ce_pix(ce_pix),

	.HBlank(HBlank),
	.HSync(HSync),
	.VBlank(VBlank),
	.VSync(VSync),

	.video_de(video_de),

	.video(video),
	.audio(audio),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joy_override(joy_override),
	.joy_manual(joy_manual),
	.auto_profile(),
	.players(players),
	.osk_a(10'd0),
	.osk_b(10'd0)
);

endmodule
