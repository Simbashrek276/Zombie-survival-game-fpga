`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"
`include "game/game_defs.vh"

// Draws the moving things on top of the background, painting zombies first,
// then bullets, then the player over everything.
//
// Every pixel of every sprite is looked up in the same clock, so all three ROMs
// are read in parallel and the results are picked between afterwards. That costs
// one cycle of delay, which is why this layer carries a pipeline stage.
module obj_layer #(
	`SVO_DEFAULT_PARAMS,
	parameter MAX_ZOMBIE = 5,
	parameter MAX_BULLET = 4,
	parameter POS_BITS   = 10
) (
	input clk,
	input resetn,

	input [9:0] player_x,
	input [9:0] player_y,

	input [MAX_ZOMBIE          -1:0] z_valid_bus,
	input [MAX_ZOMBIE*POS_BITS -1:0] z_x_bus,
	input [MAX_ZOMBIE*POS_BITS -1:0] z_y_bus,
	input [MAX_ZOMBIE*2        -1:0] z_type_bus,

	input [MAX_BULLET          -1:0] b_valid_bus,
	input [MAX_BULLET*POS_BITS -1:0] b_x_bus,
	input [MAX_BULLET*POS_BITS -1:0] b_y_bus,

	// input stream from previous layer
	input in_axis_tvalid,
	output in_axis_tready,
	input [SVO_BITS_PER_PIXEL-1:0] in_axis_tdata,
	input [0:0] in_axis_tuser,

	// output stream to next layer
	output out_axis_tvalid,
	input out_axis_tready,
	output [SVO_BITS_PER_PIXEL-1:0] out_axis_tdata,
	output [0:0] out_axis_tuser
);
`SVO_DECLS

localparam PLAYER_SRC_BITS = 5;
localparam PLAYER_ADDR_WIDTH = 10;        // {src_y(5), src_x(5)} -> one 32x32 frame
localparam BULLET_ADDR_WIDTH = 8;         // {src_y(4), src_x(4)} -> one 16x16 frame
// The zombie and the boss live in one atlas ROM addressed as {is_boss, y, x}.
// Sharing a ROM keeps them to a single block of RAM instead of two.
localparam ENEMY_ADDR_WIDTH = 11;
localparam [7:0] TRANSPARENT_VAL = 8'h00;

// Zombie kinds, kept in step with game_ctrl
localparam Z_FAST = 2'd1;
localparam Z_TANK = 2'd2;
localparam Z_BOSS = 2'd3;

reg [`SVO_XYBITS-1:0] hcursor;
reg [`SVO_XYBITS-1:0] vcursor;

wire fire = in_axis_tvalid && in_axis_tready;
wire [`SVO_XYBITS-1:0] pixel_x = in_axis_tuser[0] ? 0 : hcursor;
wire [`SVO_XYBITS-1:0] pixel_y = in_axis_tuser[0] ? 0 : vcursor;

integer zi, bi;

// Work out whether this pixel is inside a zombie, and if so which one, so we
// know which pixel of the sprite to read.
reg zombie_hit;
reg [1:0] zombie_kind;
reg [9:0] zombie_rel_x;
reg [9:0] zombie_rel_y;

reg [1:0] scan_kind;
reg [9:0] scan_size;      // both enemies are square, so one size covers it

always @(*) begin
	zombie_hit = 1'b0;
	zombie_kind = 2'd0;
	zombie_rel_x = 10'd0;
	zombie_rel_y = 10'd0;
	scan_kind = 2'd0;
	scan_size = `ZOMBIE_W;

	for (zi = 0; zi < MAX_ZOMBIE; zi = zi + 1) begin
		scan_kind = z_type_bus[zi*2 +: 2];
		scan_size = (scan_kind == Z_BOSS) ? `BOSS_W : `ZOMBIE_W;

		if (!zombie_hit && z_valid_bus[zi] &&
			pixel_x >= z_x_bus[zi*POS_BITS +: POS_BITS] &&
			pixel_x <  z_x_bus[zi*POS_BITS +: POS_BITS] + scan_size &&
			pixel_y >= z_y_bus[zi*POS_BITS +: POS_BITS] &&
			pixel_y <  z_y_bus[zi*POS_BITS +: POS_BITS] + scan_size) begin
			zombie_hit = 1'b1;
			zombie_kind = scan_kind;
			zombie_rel_x = pixel_x - z_x_bus[zi*POS_BITS +: POS_BITS];
			zombie_rel_y = pixel_y - z_y_bus[zi*POS_BITS +: POS_BITS];
		end
	end
end

wire is_boss = (zombie_kind == Z_BOSS);

// A zombie is a 32x32 sprite drawn one to one. The boss is a 24x24 sprite with
// every pixel blown up to 4x4, which gives 96x96 and makes it three times the
// size of a zombie. Dividing by 4 only means dropping the bottom two bits, so
// the scaling costs nothing at all.
wire [4:0] enemy_src_x = is_boss ? zombie_rel_x[6:2] : zombie_rel_x[4:0];
wire [4:0] enemy_src_y = is_boss ? zombie_rel_y[6:2] : zombie_rel_y[4:0];

// The top address bit picks which half of the atlas to read, 0 for the zombie
// and 1 for the boss.
wire [ENEMY_ADDR_WIDTH-1:0] zombie_addr = {is_boss, enemy_src_y, enemy_src_x};
wire [7:0] zombie_rgb;

// Same question for bullets, and again we keep the one we found so the sprite
// can be read at the right offset.
reg bullet_hit;
reg [9:0] bullet_rel_x;
reg [9:0] bullet_rel_y;

always @(*) begin
	bullet_hit = 1'b0;
	bullet_rel_x = 10'd0;
	bullet_rel_y = 10'd0;

	for (bi = 0; bi < MAX_BULLET; bi = bi + 1) begin
		if (!bullet_hit && b_valid_bus[bi] &&
			pixel_x >= b_x_bus[bi*POS_BITS +: POS_BITS] &&
			pixel_x <  b_x_bus[bi*POS_BITS +: POS_BITS] + `BULLET_W &&
			pixel_y >= b_y_bus[bi*POS_BITS +: POS_BITS] &&
			pixel_y <  b_y_bus[bi*POS_BITS +: POS_BITS] + `BULLET_H) begin
			bullet_hit = 1'b1;
			bullet_rel_x = pixel_x - b_x_bus[bi*POS_BITS +: POS_BITS];
			bullet_rel_y = pixel_y - b_y_bus[bi*POS_BITS +: POS_BITS];
		end
	end
end

// Drawn one to one from the 16x16 sprite. Bullets only ever fly right, so it is
// read straight through with no mirroring.
wire [3:0] bullet_src_x = bullet_rel_x[3:0];
wire [3:0] bullet_src_y = bullet_rel_y[3:0];
wire [BULLET_ADDR_WIDTH-1:0] bullet_addr = {bullet_src_y, bullet_src_x};
wire [7:0] bullet_rgb;

// Player sprite
wire hit_player = pixel_x >= player_x && pixel_x < player_x + `PLAYER_W &&
				  pixel_y >= player_y && pixel_y < player_y + `PLAYER_H;

// Drawn one to one from the 32x32 sprite
wire [9:0] player_rel_x = pixel_x - player_x;
wire [9:0] player_rel_y = pixel_y - player_y;
wire [PLAYER_SRC_BITS-1:0] player_src_x = player_rel_x[4:0];
wire [PLAYER_SRC_BITS-1:0] player_src_y = player_rel_y[4:0];
// The player always faces right, so the sprite is read straight through.
wire [PLAYER_ADDR_WIDTH-1:0] player_addr = {player_src_y, player_src_x};

wire [7:0] player_rgb;

function [23:0] rgb323_to_bgr888;
	input [7:0] c;                 // 3 bits red, 2 green, 3 blue, packed in a byte
	reg [7:0] r;
	reg [7:0] g;
	reg [7:0] b;
	begin
		r = {c[7:5], c[7:5], c[7:6]};
		g = {c[4:3], c[4:3], c[4:3], c[4:3]};
		b = {c[2:0], c[2:0], c[2:1]};
		rgb323_to_bgr888 = {b, g, r};
	end
endfunction

// All three ordinary kinds share one picture. Fast ones are tinted towards red
// and tanky ones towards blue, so a glance tells you what is coming at you.
function [23:0] tint_zombie;
	input [23:0] c;                // {b, g, r}
	input [1:0] kind;
	begin
		case (kind)
			Z_FAST:  tint_zombie = {1'b0, c[23:17], c[15:8], 8'hFF};
			Z_TANK:  tint_zombie = {8'hFF, 1'b0, c[15:9], c[7:0]};
			default: tint_zombie = c;
		endcase
	end
endfunction

// All three ROMs answer a cycle late, so everything decided above has to be
// held for a cycle to stay lined up with the pixel it belongs to.
reg zombie_hit_d;
reg [1:0] zombie_kind_d;
reg bullet_hit_d;
reg hit_player_d;
reg [SVO_BITS_PER_PIXEL-1:0] bg_rgb_d;
reg [0:0] tuser_d;
reg tvalid_d;

// Painting order, from the back forwards. A sprite pixel only wins if it is
// not the transparent colour, which is how the art keeps its shape.
wire [SVO_BITS_PER_PIXEL-1:0] pxl_after_zombie =
	(zombie_hit_d && zombie_rgb != TRANSPARENT_VAL) ?
	tint_zombie(rgb323_to_bgr888(zombie_rgb), zombie_kind_d) : bg_rgb_d;

wire [SVO_BITS_PER_PIXEL-1:0] pxl_after_bullet =
	(bullet_hit_d && bullet_rgb != TRANSPARENT_VAL) ?
	rgb323_to_bgr888(bullet_rgb) : pxl_after_zombie;

wire [SVO_BITS_PER_PIXEL-1:0] pxl_after_player =
	(hit_player_d && player_rgb != TRANSPARENT_VAL) ?
	rgb323_to_bgr888(player_rgb) : pxl_after_bullet;

assign in_axis_tready  = out_axis_tready;
assign out_axis_tvalid = tvalid_d;
assign out_axis_tdata  = pxl_after_player;
assign out_axis_tuser  = tuser_d;

always @(posedge clk) begin
	if (!resetn) begin
		zombie_hit_d <= 0;
		zombie_kind_d <= 0;
		bullet_hit_d <= 0;
		hit_player_d <= 0;
		bg_rgb_d <= 0;
		tuser_d <= 0;
		tvalid_d <= 0;
	end else if (out_axis_tready) begin
		tvalid_d <= in_axis_tvalid;
		if (fire) begin
			zombie_hit_d <= zombie_hit;
			zombie_kind_d <= zombie_kind;
			bullet_hit_d <= bullet_hit;
			hit_player_d <= hit_player;
			bg_rgb_d <= in_axis_tdata;
			tuser_d <= in_axis_tuser;
		end
	end
end

always @(posedge clk) begin
	if (!resetn) begin
		hcursor <= 0;
		vcursor <= 0;
	end else if (fire) begin
		if (in_axis_tuser[0]) begin
			hcursor <= 1;
			vcursor <= 0;
		end else if (hcursor == SVO_HOR_PIXELS - 1) begin
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
	.DATA_WIDTH(8),
	.ADDR_WIDTH(PLAYER_ADDR_WIDTH),
	.DEPTH(1024),
	.INIT_FILE("src/assets/survivor.mem")
) u_player_rom (
	.clk(clk),
	.addr(player_addr),
	.data(player_rgb)
);

rom #(
	.DATA_WIDTH(8),
	.ADDR_WIDTH(BULLET_ADDR_WIDTH),
	.DEPTH(256),
	.INIT_FILE("src/assets/bullet.mem")
) u_bullet_rom (
	.clk(clk),
	.addr(bullet_addr),
	.data(bullet_rgb)
);

rom #(
	.DATA_WIDTH(8),
	.ADDR_WIDTH(ENEMY_ADDR_WIDTH),
	.DEPTH(2048),
	.INIT_FILE("src/assets/obj_atlas.mem")
) u_enemy_rom (
	.clk(clk),
	.addr(zombie_addr),
	.data(zombie_rgb)
);

endmodule
