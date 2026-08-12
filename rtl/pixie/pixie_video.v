//============================================================================
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
//  51 Franklin Street, Fifth Floor, Boston, MA 0210-1301 USA.
//
//============================================================================

module pixie_video 
(
    // front end, CDP1802 bus clock domain
    input             clk,
    input             reset,  
    input             clk_enable,   // pixel enable
    input             cpu_ce,       // CPU machine-cycle enable

    input       [1:0] SC,         
    input             disp_on,
    input             disp_off,

    input       [7:0] data_in,     

    output            DMAO,     
    output            INT,     
    output            EFx,

    // back end, video clock domain
    input             video_clk,
    output            csync,     
    output            video,

    output            VSync,
    output            HSync,    
    output            VBlank,
    output            HBlank,
    output            video_de  
);

// RCA Studio II
cdp1861 cdp1861 (
    .clk        (clk),          // I  pixel-rate domain
    .ce_pix     (clk_enable),   // I
    .cpu_ce     (cpu_ce),       // I  one pulse per CPU machine cycle
    .reset      (reset),        // I

    .SC         (SC),           // I [1:0]
    .data_in    (data_in),      // I [7:0]  byte the CPU delivers during DMA-OUT
    .disp_on    (disp_on),      // I
    .disp_off   (disp_off),     // I

    .DMAO       (DMAO),         // O
    .INT        (INT),          // O
    .EFx        (EFx),          // O

    .csync      (csync),        // O
    .video      (video),        // O
    .VSync      (VSync),        // O
    .HSync      (HSync),        // O
    .VBlank     (VBlank),       // O
    .HBlank     (HBlank),       // O
    .video_de   (video_de)      // O
);

endmodule
