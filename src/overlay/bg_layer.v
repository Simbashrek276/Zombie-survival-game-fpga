`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"
`include "game/game_defs.vh"

// The first layer in the chain, so it has no input stream. It invents the pixels
// and the frame timing that everything downstream follows.
//
// Draws the ruined city, and the bunker standing in front of it on the left.
module bg_layer #(
	`SVO_DEFAULT_PARAMS,
	parameter BG_IMG_W = 80,
	parameter BG_IMG_H = 50,
	parameter BG_Y0 = 16,                        // top of the image band
	parameter BG_TILE_FILE = "src/assets/daylight.mem"
) (
	input clk,
	input resetn,

	output reg out_axis_tvalid,
	input out_axis_tready,
	output reg [SVO_BITS_PER_PIXEL-1:0] out_axis_tdata,
	output reg [0:0] out_axis_tuser
);
`SVO_DECLS

localparam BG_DEPTH = 4096;                      // >= BG_IMG_W * BG_IMG_H (4000)
localparam BG_ADDR_WIDTH = 12;
localparam BG_Y1 = BG_Y0 + BG_IMG_H * 8;         // band bottom (exclusive) = 16 + 400 = 416
localparam [23:0] BG_MARGIN_RGB = 24'h181818;    // dark gray outside the band (matches UI)

// The bunker you defend, on the left of the screen. Built from rectangles
// instead of a sprite so it uses no block RAM (there is only one spare block).
// Colours are concrete greys warmed slightly to match the sunset in the art.
localparam [23:0] HOUSE_WALL_RGB = 24'h8C96A0;   // BGR888: lit concrete
localparam [23:0] HOUSE_SHADE_RGB= 24'h5A6470;   // shaded concrete / roof slab
localparam [23:0] HOUSE_DARK_RGB = 24'h202832;   // doorway and window slits

localparam HOUSE_TOP  = `GROUND_BOT - `HOUSE_H;      // 416 - 120 = 296
localparam ROOF_BOT   = HOUSE_TOP + 10'd16;          // roof slab is 16 px thick
localparam WALL_L     = 10'd6;
localparam WALL_R     = `HOUSE_X - 10'd6;            // 90
localparam DOOR_L     = 10'd38;
localparam DOOR_R     = 10'd58;
localparam DOOR_TOP   = `GROUND_BOT - 10'd48;        // 368
localparam SLIT_TOP   = HOUSE_TOP + 10'd28;          // 324
localparam SLIT_BOT   = SLIT_TOP + 10'd12;           // 336

// Which part of the bunker this pixel belongs to, if any.
localparam [1:0] H_NONE = 2'd0;
localparam [1:0] H_WALL = 2'd1;
localparam [1:0] H_ROOF = 2'd2;
localparam [1:0] H_DARK = 2'd3;

reg [`SVO_XYBITS-1:0] hcursor, vcursor;
reg pipe_valid;
reg pipe_tuser;
reg pipe_in_band;
reg [1:0] pipe_house;

// A full 640x400 image would need far more memory than this chip has, so the art
// is stored at 80x50 and each stored pixel is drawn as an 8x8 block. Coarse, but
// it is a distant skyline, and dividing by 8 is just dropping three bits.
wire in_band = (vcursor >= BG_Y0) && (vcursor < BG_Y1);

// The bunker is worked out from the outside in. The roof slab overhangs the full
// width, the walls sit inset beneath it, and the doorway and window slits are cut
// back out of those walls.
reg [1:0] house_part;

always @(*) begin
	house_part = H_NONE;

	if (vcursor >= HOUSE_TOP && vcursor < `GROUND_BOT) begin
		if (vcursor < ROOF_BOT) begin
			// Roof slab, full width, slightly overhanging the walls
			if (hcursor < `HOUSE_X)
				house_part = H_ROOF;
		end else if (hcursor >= WALL_L && hcursor < WALL_R) begin
			// Wall, with the doorway and two window slits punched through
			if (hcursor >= DOOR_L && hcursor < DOOR_R && vcursor >= DOOR_TOP)
				house_part = H_DARK;
			else if (vcursor >= SLIT_TOP && vcursor < SLIT_BOT &&
					 ((hcursor >= WALL_L + 10'd6  && hcursor < WALL_L + 10'd22) ||
					  (hcursor >= WALL_R - 10'd22 && hcursor < WALL_R - 10'd6)))
				house_part = H_DARK;
			else
				house_part = H_WALL;
		end
	end
end

wire [6:0] bg_src_x = hcursor[9:3];              // hcursor / 8 -> 0..79
wire [`SVO_XYBITS-1:0] bg_rel_y = vcursor - BG_Y0;
wire [5:0] bg_src_y = bg_rel_y[8:3];             // (vcursor - 16) / 8 -> 0..49
wire [BG_ADDR_WIDTH-1:0] bg_addr = bg_src_y * BG_IMG_W + bg_src_x;
wire [15:0] bg_rgb565;

function [23:0] rgb565_to_bgr888;
	input [15:0] rgb565;
	reg [7:0] r;
	reg [7:0] g;
	reg [7:0] b;
	begin
		r = {rgb565[15:11], rgb565[15:13]};
		g = {rgb565[10: 5], rgb565[10: 9]};
		b = {rgb565[ 4: 0], rgb565[ 4: 2]};
		rgb565_to_bgr888 = {b, g, r};
	end
endfunction

always @(posedge clk) begin
	if (!resetn) begin
		hcursor <= 0;
		vcursor <= 0;
		pipe_valid <= 0;
		pipe_tuser <= 0;
		pipe_in_band <= 0;
		pipe_house <= H_NONE;
		out_axis_tvalid <= 0;
		out_axis_tdata <= 0;
		out_axis_tuser <= 0;
	end else if (!out_axis_tvalid || out_axis_tready) begin
		out_axis_tvalid   <= pipe_valid;
		// The bunker stands in front of the background image.
		out_axis_tdata    <= (pipe_house == H_ROOF) ? HOUSE_SHADE_RGB :
							 (pipe_house == H_DARK) ? HOUSE_DARK_RGB  :
							 (pipe_house == H_WALL) ? HOUSE_WALL_RGB  :
							 pipe_in_band ? rgb565_to_bgr888(bg_rgb565)
										  : BG_MARGIN_RGB;
		out_axis_tuser[0] <= pipe_tuser;

		pipe_valid <= 1;
		pipe_tuser <= hcursor == 0 && vcursor == 0;
		pipe_in_band <= in_band;
		pipe_house <= house_part;

		if (hcursor == SVO_HOR_PIXELS - 1) begin
			hcursor <= 0;
			if (vcursor == SVO_VER_PIXELS - 1)
				vcursor <= 0;
			else
				vcursor <= vcursor + 1;
		end else begin
			hcursor <= hcursor + 1;
		end
	end
end

rom #(
	.DATA_WIDTH(16),
	.ADDR_WIDTH(BG_ADDR_WIDTH),
	.DEPTH(BG_DEPTH),
	.INIT_FILE(BG_TILE_FILE)
) u_bg_rom (
	.clk(clk),
	.addr(bg_addr),
	.data(bg_rgb565)
);

endmodule
