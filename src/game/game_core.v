`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"

// Wires the game logic to the four drawing layers. Pixels flow through the layers
// one after another, each painting over whatever the last one produced.
//
//   bg_layer (city, rubble, bunker) -> obj_layer (zombies, bullets, player)
//     -> ui_layer (timer, LEVEL, streak) -> res_overlay (game over panel)
module game_core #(
	parameter SVO_MODE             =   "640x480V",
	parameter SVO_FRAMERATE        =   60,
	parameter SVO_BITS_PER_PIXEL   =   24,
	parameter SVO_BITS_PER_RED     =    8,
	parameter SVO_BITS_PER_GREEN   =    8,
	parameter SVO_BITS_PER_BLUE    =    8,
	parameter SVO_BITS_PER_ALPHA   =    0
) (
	input clk,
	input resetn,

	input btn_up,
	input btn_down,
	input btn_left,
	input btn_right,
	input btn_skill,

	output out_axis_tvalid,
	input out_axis_tready,
	output [SVO_BITS_PER_PIXEL-1:0] out_axis_tdata,
	output [0:0] out_axis_tuser
);
// How many zombies and bullets can be on screen at once. Every extra slot costs
// FPGA logic, so keep these small and only raise them if a build still fits.
localparam MAX_ZOMBIE = 5;
localparam MAX_BULLET = 4;
localparam POS_BITS = 10;

wire bg_tvalid;
wire bg_tready;
wire [SVO_BITS_PER_PIXEL-1:0] bg_tdata;
wire [0:0] bg_tuser;

wire obj_tvalid;
wire obj_tready;
wire [SVO_BITS_PER_PIXEL-1:0] obj_tdata;
wire [0:0] obj_tuser;

wire ui_tvalid;
wire ui_tready;
wire [SVO_BITS_PER_PIXEL-1:0] ui_tdata;
wire [0:0] ui_tuser;

wire frame_tick;
wire [9:0] player_x;
wire [9:0] player_y;

wire [MAX_ZOMBIE          -1:0] z_valid_bus;
wire [MAX_ZOMBIE*POS_BITS -1:0] z_x_bus;
wire [MAX_ZOMBIE*POS_BITS -1:0] z_y_bus;
wire [MAX_ZOMBIE*2        -1:0] z_type_bus;

wire [MAX_BULLET          -1:0] b_valid_bus;
wire [MAX_BULLET*POS_BITS -1:0] b_x_bus;
wire [MAX_BULLET*POS_BITS -1:0] b_y_bus;

wire [9:0] timer;
wire [11:0] timer_bcd;
wire [3:0] game_level;
wire [5:0] kill_streak;
wire skill_ready;
wire skill_on;
wire game_idle;
wire game_over;

// bg_layer raises tuser[0] on the first pixel it hands over each frame, so this
// pulses once every 1/60 s. It is the only clock the game rules ever see.
assign frame_tick = bg_tvalid && bg_tready && bg_tuser[0];

game_ctrl #(
	.MAX_ZOMBIE(MAX_ZOMBIE),
	.MAX_BULLET(MAX_BULLET),
	.POS_BITS(POS_BITS)
) u_game_ctrl (
	.clk(clk),
	.resetn(resetn),
	.frame_tick(frame_tick),

	.btn_up(btn_up),
	.btn_down(btn_down),
	.btn_left(btn_left),
	.btn_right(btn_right),
	.btn_skill(btn_skill),

	.player_x(player_x),
	.player_y(player_y),

	.z_valid_bus(z_valid_bus),
	.z_x_bus(z_x_bus),
	.z_y_bus(z_y_bus),
	.z_type_bus(z_type_bus),

	.b_valid_bus(b_valid_bus),
	.b_x_bus(b_x_bus),
	.b_y_bus(b_y_bus),

	.timer(timer),
	.timer_bcd(timer_bcd),
	.game_level(game_level),
	.kill_streak(kill_streak),
	.skill_ready(skill_ready),
	.skill_on(skill_on),
	.game_idle(game_idle),
	.game_over(game_over)
);

bg_layer #(
	`SVO_PASS_PARAMS,
	.BG_TILE_FILE("src/assets/daylight.mem")
) u_bg_layer (
	.clk(clk),
	.resetn(resetn),

	.out_axis_tvalid(bg_tvalid),
	.out_axis_tready(bg_tready),
	.out_axis_tdata(bg_tdata),
	.out_axis_tuser(bg_tuser)
);

obj_layer #(
	`SVO_PASS_PARAMS,
	.MAX_ZOMBIE(MAX_ZOMBIE),
	.MAX_BULLET(MAX_BULLET),
	.POS_BITS(POS_BITS)
) u_obj_layer (
	.clk(clk),
	.resetn(resetn),

	.player_x(player_x),
	.player_y(player_y),

	.z_valid_bus(z_valid_bus),
	.z_x_bus(z_x_bus),
	.z_y_bus(z_y_bus),
	.z_type_bus(z_type_bus),

	.b_valid_bus(b_valid_bus),
	.b_x_bus(b_x_bus),
	.b_y_bus(b_y_bus),

	.in_axis_tvalid(bg_tvalid),
	.in_axis_tready(bg_tready),
	.in_axis_tdata(bg_tdata),
	.in_axis_tuser(bg_tuser),

	.out_axis_tvalid(obj_tvalid),
	.out_axis_tready(obj_tready),
	.out_axis_tdata(obj_tdata),
	.out_axis_tuser(obj_tuser)
);

ui_layer #(
	`SVO_PASS_PARAMS
) u_ui_layer (
	.clk(clk),
	.resetn(resetn),

	.timer_bcd(timer_bcd),
	.game_level(game_level),
	.kill_streak(kill_streak),
	.skill_ready(skill_ready),
	.skill_on(skill_on),
	.game_idle(game_idle),
	.game_over(game_over),

	.btn_up(btn_up),
	.btn_down(btn_down),
	.btn_left(btn_left),
	.btn_right(btn_right),
	.btn_skill(btn_skill),

	.in_axis_tvalid(obj_tvalid),
	.in_axis_tready(obj_tready),
	.in_axis_tdata(obj_tdata),
	.in_axis_tuser(obj_tuser),

	.out_axis_tvalid(ui_tvalid),
	.out_axis_tready(ui_tready),
	.out_axis_tdata(ui_tdata),
	.out_axis_tuser(ui_tuser)
);

res_overlay #(
	`SVO_PASS_PARAMS
) u_res_overlay (
	.clk(clk),
	.resetn(resetn),

	.show(game_over),
	.time_bcd(timer_bcd),

	.in_axis_tvalid(ui_tvalid),
	.in_axis_tready(ui_tready),
	.in_axis_tdata(ui_tdata),
	.in_axis_tuser(ui_tuser),

	.out_axis_tvalid(out_axis_tvalid),
	.out_axis_tready(out_axis_tready),
	.out_axis_tdata(out_axis_tdata),
	.out_axis_tuser(out_axis_tuser)
);
endmodule
