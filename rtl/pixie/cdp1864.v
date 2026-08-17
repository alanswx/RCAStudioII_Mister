//============================================================================
//
//  CDP1864 "PAL Compatible Color TV Interface".
//
//  Written 2026 by Alan Steremberg. Structure, and all of the DMA/INT/EFx
//  timing detail, is derived from this repo's rtl/pixie/cdp1861.v -- the two
//  parts have the same architecture (no frame buffer, the 1802 DMAs display
//  bytes out through R(0)) and the same CPU-side contract, so the hard-won
//  behaviour there applies here unchanged. Geometry and colour follow the RCA
//  datasheet (refs/rca-studio2/Documents/cdp1864.pdf, distilled in
//  docs/succession-plan.md §6), MAME's cdp1864 device by Curt Coder
//  (BSD-3-Clause), and Emma 02's machine XML.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//============================================================================
//
//  Deliberately a separate module rather than a parameterised cdp1861. The 1861
//  is delicately tuned -- see the INT_LEAD / EFX_LEAD / DMA_ADAPT commentary
//  there, every value of which was swept against real software -- and making its
//  geometry runtime-selectable would put the working Studio II at risk for no
//  gain. Both parts are tiny, so the top level instantiates each and selects.
//  If a timing fix lands in one, port it to the other by hand.
//
//  Differences from the 1861:
//
//      1861 (NTSC, mono)            1864 (PAL, colour)
//      262 lines/frame              312 lines/frame
//      display 80..207 (128)        display 76..267 (192)
//      rows shown 4x                rows shown 6x  (32 x 6 = 192)
//      1 bit of video               3 bits, {R,G,B}
//      -                           1-of-4 background colour, stepped by OUT 1
//      -                           tone generator (not here; see below)
//
//  Both run 14 machine cycles per line, so the whole horizontal structure --
//  DMA phase, the tolerant read window, HSync placement -- carries over
//  untouched. 1.75MHz / 50Hz / 312 lines = 14.02 cycles a line, against the
//  Studio II's 1.76MHz / 60Hz / 262 = 14.0.
//
//  Not implemented here: the tone generator (256 tones, 107Hz-13672Hz, loaded
//  by OUT 4). The Studio II's beeper lives in rcastudioii.sv and the same
//  applies to this; audio is verified separately by Q-edge measurement rather
//  than through the frame comparison.
//
//============================================================================

`default_nettype none

module cdp1864
(
    input             clk,          // pixel-rate domain
    input             ce_pix,       // one pulse per pixel time
    input             cpu_ce,       // one pulse per CPU machine cycle (8 pixel times)
    input             reset,

    // ---- CPU side -------------------------------------------------------
    input       [1:0] SC,           // 1802 state code: 2'b10 == DMA cycle
    input       [7:0] data_in,      // luminance byte the CPU put on the bus this DMA cycle
    input       [2:0] colour_in,    // {R,G,B} from colour RAM for that same byte
    input             disp_on,      // INP 1
    input             disp_off,     // INP 4 on this machine, not OUT 1
    input             bg_step,      // OUT 1: step the background colour

    output            DMAO,         // DMA-OUT request, active high
    output reg        INT,          // interrupt request, active high
    output reg        EFx,          // display status -> EF1, active high

    // ---- video side -----------------------------------------------------
    output            csync,
    output      [2:0] video,        // {R,G,B}
    output reg        VSync,
    output reg        HSync,
    output reg        VBlank,
    output reg        HBlank,
    output            video_de
);

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------
localparam PIXELS_PER_LINE   = 112;                   // 14 machine cycles, as the 1861
localparam LINES_PER_FRAME   = 312;                   // PAL. INLACE low = 312 non-interlaced.

// Display window. Emma 02's soundic_victory_mpt-02.xml gives display lines 76 to
// 267 inclusive, which is exactly 192 -- the "max 192 vertical" the datasheet
// advertises, and 32 logical rows shown 6x. Preferred over MAME's
// SCANLINE_DISPLAY_START, which carries a "// ???" from MAME itself.
localparam DISPLAY_START     = 76;
localparam DISPLAY_END       = 268;                   // one past the last (192 lines)
localparam INT_START         = DISPLAY_START - 2;     // 74
localparam EFX_TOP_START     = DISPLAY_START - 4;     // 72
localparam EFX_BOT_START     = DISPLAY_END   - 4;     // 264

// Carried over from the 1861 verbatim: same line length, same CPU, same ISR
// structure, so the same leads and the same parity resync apply. See the long
// commentary in cdp1861.v for why each is what it is.
localparam INT_LEAD          = 8;
localparam EFX_LEAD          = 8;
localparam DMA_ADAPT         = 1;

localparam DMA_START         = 16;
localparam ACTIVE_START      = DMA_START + 24;        // 40
localparam ACTIVE_END        = ACTIVE_START + 64;     // 104
localparam DE_START          = ACTIVE_START;
localparam DE_END            = DE_START + 64;

localparam HSYNC_START       = 105;
localparam HSYNC_END         = 112;
// PAL vertical sync, from MAME's cdp1864: VBLANK starts 4 lines before the end
// of the frame and VSync occupies lines 0..3.
localparam VSYNC_START       = 0;
localparam VSYNC_END         = 4;

// ---------------------------------------------------------------------------
// Counters
// ---------------------------------------------------------------------------
reg [7:0] hcount;
reg [8:0] vcount;

always @(posedge clk) begin
    if (reset) begin
        hcount <= 8'd0;
        vcount <= 9'd0;
    end
    else if (ce_pix) begin
        if (hcount == PIXELS_PER_LINE - 1) begin
            hcount <= 8'd0;
            vcount <= (vcount == LINES_PER_FRAME - 1) ? 9'd0 : vcount + 9'd1;
        end
        else hcount <= hcount + 8'd1;
    end
end

// ---------------------------------------------------------------------------
// Display enable. INP 1 on, INP 4 off -- the 1864 moves display-off off OUT 1,
// which it needs for the background colour step. Datasheet: N0 with TPB enables
// interrupt and DMA ("a 61 or 69 instruction"), N2 with MRD and TPB disables
// them ("a 6C instruction").
// ---------------------------------------------------------------------------
reg display_enabled;
always @(posedge clk) begin
    if (reset)         display_enabled <= 1'b0;
    else if (disp_off) display_enabled <= 1'b0;
    else if (disp_on)  display_enabled <= 1'b1;
end

// ---------------------------------------------------------------------------
// Background colour: 1-of-4, stepped by OUT 1. Order and values follow Emma 02's
// palette list for this machine -- back_blue, back_black, back_green, back_red.
// The datasheet's BCKGND pin, which lowers background luminance so one colour can
// serve as both background and data, is not modelled: we have one bit a channel.
// ---------------------------------------------------------------------------
reg [1:0] bg_index;
always @(posedge clk) begin
    if (reset)        bg_index <= 2'd0;
    else if (bg_step) bg_index <= bg_index + 2'd1;
end

reg [2:0] bg_colour;
always @(*) begin
    case (bg_index)
        2'd0:    bg_colour = 3'b001;   // blue
        2'd1:    bg_colour = 3'b000;   // black
        2'd2:    bg_colour = 3'b010;   // green
        default: bg_colour = 3'b100;   // red
    endcase
end

wire line_displayed = (vcount >= DISPLAY_START) && (vcount < DISPLAY_END);

// ---------------------------------------------------------------------------
// DMA request and byte capture. Identical to the 1861 except that the colour
// bits are latched alongside each luminance byte -- the datasheet has RDATA,
// GDATA and BDATA "latched concurrent with the latching of the luminance
// information from the data bus during the display interval".
// ---------------------------------------------------------------------------
reg dma_early;
always @(posedge clk) begin
    if (reset) dma_early <= 1'b0;
    else if (ce_pix && hcount == 4)
        dma_early <= (DMA_ADAPT != 0) && (vcount > DISPLAY_START) && (vcount < DISPLAY_END) && (SC == 2'b00);
end

assign DMAO = display_enabled && line_displayed &&
              (hcount >= (dma_early ? DMA_START - 8 : DMA_START)) && (dma_cnt < 4'd7);

reg  [7:0] linebuf [0:7];
reg  [2:0] colbuf  [0:7];
reg  [3:0] dma_cnt;

always @(posedge clk) begin
    if (reset) begin
        dma_cnt <= 4'd0;
    end
    else begin
        if (ce_pix && (hcount == PIXELS_PER_LINE - 1)) begin
            dma_cnt <= 4'd0;
        end
        if (cpu_ce && (SC == 2'b10) && (dma_cnt < 4'd8)) begin
            linebuf[dma_cnt[2:0]] <= data_in;
            colbuf [dma_cnt[2:0]] <= colour_in;
            dma_cnt <= dma_cnt + 4'd1;
        end
    end
end

// ---------------------------------------------------------------------------
// Pixel shifter. The luminance byte shifts as on the 1861; the colour for the
// byte being shifted is held alongside it, so a lit pixel takes the dot colour
// and an unlit one the background.
// ---------------------------------------------------------------------------
reg [7:0] shift_reg;
reg [2:0] shift_col;
wire in_active = line_displayed && (hcount >= ACTIVE_START) && (hcount < ACTIVE_END);

always @(posedge clk) begin
    if (reset) begin
        shift_reg <= 8'd0;
        shift_col <= 3'd0;
    end
    else if (ce_pix) begin
        if (in_active) begin
            if (hcount[2:0] == 3'd0) begin
                shift_reg <= linebuf[hcount[5:3] - 3'd5];   // ACTIVE_START/8 == 5
                shift_col <= colbuf [hcount[5:3] - 3'd5];
            end
            else shift_reg <= {shift_reg[6:0], 1'b0};
        end
        else shift_reg <= 8'd0;
    end
end

reg in_active_d;
always @(posedge clk) begin
    if (reset)       in_active_d <= 1'b0;
    else if (ce_pix) in_active_d <= in_active;
end

// Outside the display window the screen is black, not the background colour:
// the background only applies within the displayed picture.
assign video = (display_enabled && in_active_d) ? (shift_reg[7] ? shift_col : bg_colour)
                                                : 3'b000;

// ---------------------------------------------------------------------------
// Sync, blanking and the CPU-visible status flags. The EF shape is the same as
// the 1861's, which the datasheet confirms for this part too: "Two pulses per
// field are generated on this line, each of which is four horizontal lines wide.
// The first pulse begins four horizontal lines before the display, and the
// second pulse begins four horizontal lines prior to the end of the display."
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (reset) begin
        HSync <= 1'b0; VSync <= 1'b0;
        HBlank <= 1'b1; VBlank <= 1'b1;
        INT <= 1'b0;   EFx <= 1'b0;
    end
    else if (ce_pix) begin
        HSync  <= (hcount >= HSYNC_START) && (hcount < HSYNC_END);
        // VSYNC_START is line 0, so the lower bound is implicit: spelling it out
        // as (vcount >= VSYNC_START) is an always-true unsigned comparison, which
        // the linter rightly flags. The 1861 needs both terms because its VSync
        // sits at 254..257 instead.
        VSync  <= (vcount < VSYNC_END);
        HBlank <= !((hcount >= DE_START) && (hcount < DE_END));
        VBlank <= !line_displayed;

        INT <= display_enabled &&
               (((vcount == INT_START - 1)     && (hcount >= 112 - INT_LEAD)) ||
                ((vcount >= INT_START) && (vcount < DISPLAY_START) &&
                 !((vcount == DISPLAY_START - 1) && (hcount >= 112 - INT_LEAD))));

        EFx <= display_enabled &&
               ((((vcount == EFX_TOP_START - 1) && (hcount >= 112 - EFX_LEAD)) ||
                 ((vcount >= EFX_TOP_START) && (vcount < DISPLAY_START) &&
                  !((vcount == DISPLAY_START - 1) && (hcount >= 112 - EFX_LEAD)))) ||
                (((vcount == EFX_BOT_START - 1) && (hcount >= 112 - EFX_LEAD)) ||
                 ((vcount >= EFX_BOT_START) && (vcount < DISPLAY_END) &&
                  !((vcount == DISPLAY_END - 1) && (hcount >= 112 - EFX_LEAD)))));
    end
end

assign csync    = ~(HSync ^ VSync);
assign video_de = ~(VBlank | HBlank);

endmodule

`default_nettype wire
