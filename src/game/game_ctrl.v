`timescale 1ns / 1ps
`include "game/game_defs.vh"

// All of the game rules live here.
//
// You move around the ground with WASD and shoot to the right constantly,
// without pressing anything. Zombies come in from the right edge and walk
// straight left. They never chase you, which keeps them cheap and means the
// difficulty comes from how many arrive rather than how clever they are.
//
// Killing zombies builds a streak, and at 20 the skill is ready. Pressing the
// skill button makes you shoot much faster for 10 seconds and spends the whole
// streak, so you have to earn it again.
//
// You lose the moment a zombie touches you or reaches the house. The timer
// counts up rather than down, because how long you survive is the score.
module game_ctrl #(
	parameter MAX_ZOMBIE = 5,
	parameter MAX_BULLET = 4,
	parameter POS_BITS = 10,

	parameter PLAYER_SPEED = 4,
	parameter BULLET_SPEED = 8,

	// Frames between shots, normally slow and much faster while the skill is on.
	parameter FIRE_PERIOD_NORMAL = 24,   // 2.5 shots a second
	parameter FIRE_PERIOD_SKILL  = 8,    // about 7 shots a second

	parameter KILLS_FOR_SKILL = 20,
	parameter SKILL_SECONDS = 10,
	parameter FPS = 60
)(
	input clk,
	input resetn,
	input frame_tick,

	input btn_up,
	input btn_down,
	input btn_left,
	input btn_right,
	input btn_skill,

	output reg [9:0] player_x,
	output reg [9:0] player_y,

	output reg [MAX_ZOMBIE          -1:0] z_valid_bus,
	output reg [MAX_ZOMBIE*POS_BITS -1:0] z_x_bus,
	output reg [MAX_ZOMBIE*POS_BITS -1:0] z_y_bus,
	output reg [MAX_ZOMBIE*2        -1:0] z_type_bus,

	output reg [MAX_BULLET          -1:0] b_valid_bus,
	output reg [MAX_BULLET*POS_BITS -1:0] b_x_bus,
	output reg [MAX_BULLET*POS_BITS -1:0] b_y_bus,

	output reg [9:0] timer,
	output [11:0] timer_bcd,
	output [3:0] game_level,          // shown on screen, counts from 1
	output reg [5:0] kill_streak,     // zombies killed since the last skill use
	output skill_ready,
	output skill_on,
	output game_idle,
	output game_over
);

// The game waits in S_IDLE with the timer showing 0 until the first button
// press, so you always see it start from zero.
localparam [1:0] S_IDLE = 2'd0;
localparam [1:0] S_PLAY = 2'd1;
localparam [1:0] S_OVER = 2'd2;

// Zombie kinds
localparam Z_NORMAL = 2'd0;
localparam Z_FAST   = 2'd1;
localparam Z_TANK   = 2'd2;
localparam Z_BOSS   = 2'd3;

// The mini boss only turns up once you have survived BOSS_FROM_LEVEL, and even
// then it stays rare. The random pick runs 0 to 127, so 124 and above lands
// roughly 3% of the time.
localparam BOSS_FROM_LEVEL = 3'd4;      // level 4 starts at 40 seconds
localparam [3:0] BOSS_HP   = 4'd13;
localparam [2:0] BOSS_SLOT = 3'd0;      // the one zombie slot kept for the boss

localparam [9:0] SCREEN_W = 10'd640;

// Where the player is allowed to be. His FEET must stay on the rubble, so his
// top-left Y runs from (rubble top - his height) to (ground bottom - his height).
localparam [9:0] PLAYER_MIN_X = `HOUSE_X;
localparam [9:0] PLAYER_MAX_X = SCREEN_W - `PLAYER_W;
localparam [9:0] PLAYER_MIN_Y = `GROUND_TOP - `PLAYER_H;
localparam [9:0] PLAYER_MAX_Y = `GROUND_BOT - `PLAYER_H;

// Same idea for zombies, whose sprite is a different height.
localparam [9:0] ZOMBIE_MIN_Y = `GROUND_TOP - `ZOMBIE_H;

reg [1:0] state;
reg [7:0] frame_cnt;
reg [7:0] spawn_cnt;
reg [7:0] fire_cnt;
reg [4:0] skill_secs_left;
reg btn_skill_q;

// Each zombie slot is either empty, meaning z_valid is 0, or holds one zombie.
// Keeping fixed slots is far simpler than shuffling a list every time one dies.
reg                z_valid [0:MAX_ZOMBIE-1];
reg [POS_BITS-1:0] z_x     [0:MAX_ZOMBIE-1];
reg [POS_BITS-1:0] z_y     [0:MAX_ZOMBIE-1];
reg [1:0]          z_type  [0:MAX_ZOMBIE-1];
reg [3:0]          z_hp    [0:MAX_ZOMBIE-1];   // 4 bits, sized for the boss's 13

// Bullet slots work the same way. Bullets only ever fly right, so there is no
// direction to store.
reg                b_valid [0:MAX_BULLET-1];
reg [POS_BITS-1:0] b_x     [0:MAX_BULLET-1];
reg [POS_BITS-1:0] b_y     [0:MAX_BULLET-1];

integer i, j;

assign game_idle = (state == S_IDLE);
assign game_over = (state == S_OVER);
assign skill_on  = (skill_secs_left != 0);
assign skill_ready = (kill_streak >= KILLS_FOR_SKILL) && !skill_on;

wire any_button = btn_up || btn_down || btn_left || btn_right || btn_skill;
wire game_step = frame_tick && (state == S_PLAY);
wire sec_tick = game_step && (frame_cnt == FPS - 1);

// Shots come much closer together while the skill is running.
wire [7:0] fire_period = skill_on ? FIRE_PERIOD_SKILL[7:0] : FIRE_PERIOD_NORMAL[7:0];

// Difficulty climbs one step every 10 seconds, then stops at the hardest step
// after 60 seconds and stays there. The game gets hard without ever becoming
// impossible, which is what keeps a run worth restarting.
reg [2:0] level;
always @(*) begin
	     if (timer >= 10'd60) level = 3'd6;    // hardest, from here on
	else if (timer >= 10'd50) level = 3'd5;
	else if (timer >= 10'd40) level = 3'd4;
	else if (timer >= 10'd30) level = 3'd3;
	else if (timer >= 10'd20) level = 3'd2;
	else if (timer >= 10'd10) level = 3'd1;
	else                      level = 3'd0;
end

// On screen the first level reads as 1, not 0.
assign game_level = {1'b0, level} + 4'd1;

// Frames between spawns at 60 frames per second. 90 works out to one zombie
// every 1.5 s at the start, and 30 to one every half second at the end.
reg [7:0] spawn_period;
always @(*) begin
	case (level)
		3'd0:    spawn_period = 8'd90;
		3'd1:    spawn_period = 8'd78;
		3'd2:    spawn_period = 8'd66;
		3'd3:    spawn_period = 8'd54;
		3'd4:    spawn_period = 8'd45;
		3'd5:    spawn_period = 8'd38;
		default: spawn_period = 8'd30;   // fastest rate, held from 60 s on
	endcase
end

// Which kind of zombie to spawn. The random number runs 0 to 127, so a threshold
// of 96 means roughly 75% of the time. Fast and tanky ones only start showing up
// once you have survived a while.
reg [7:0] norm_thr;
reg [7:0] fast_thr;
always @(*) begin
	case (level)                                                  // normal/fast/tanky
		3'd0:    begin norm_thr = 8'd128; fast_thr = 8'd128; end  // 100 /  0 /  0
		3'd1:    begin norm_thr = 8'd108; fast_thr = 8'd128; end  //  84 / 16 /  0
		3'd2:    begin norm_thr = 8'd96;  fast_thr = 8'd120; end  //  75 / 19 /  6
		3'd3:    begin norm_thr = 8'd83;  fast_thr = 8'd111; end  //  65 / 22 / 13
		3'd4:    begin norm_thr = 8'd70;  fast_thr = 8'd102; end  //  55 / 25 / 20
		3'd5:    begin norm_thr = 8'd60;  fast_thr = 8'd96;  end  //  47 / 28 / 25
		default: begin norm_thr = 8'd51;  fast_thr = 8'd90;  end  //  40 / 30 / 30
	endcase
end

// Randomness
wire [31:0] rnd_type;
wire [31:0] rnd_row;

lfsr32 #(.SEED(32'hACE1_1234)) u_rnd_type (
	.clk(clk), .resetn(resetn), .en(1'b1), .rnd(rnd_type)
);

lfsr32 #(.SEED(32'h1D2C_3B4A)) u_rnd_row (
	.clk(clk), .resetn(resetn), .en(1'b1), .rnd(rnd_row)
);

wire [7:0] type_pick = {1'b0, rnd_type[6:0]};
// A boss needs its reserved slot to be empty, so the one on screen has to die
// before the next can turn up.
wire boss_allowed = (level >= BOSS_FROM_LEVEL) && !z_valid[BOSS_SLOT];

// How likely a spawn is the mini boss. A threshold of T leaves 128 minus T
// winning numbers out of 128, and the boss gets steadily less rare the longer
// you survive. This reads the clock directly rather than the difficulty level,
// because the level stops climbing at 60 seconds and the boss should not.
reg [7:0] boss_thr;
always @(*) begin
	     if (timer >= 10'd120) boss_thr = 8'd113;   // 15 of 128 = about 12%
	else if (timer >= 10'd100) boss_thr = 8'd118;   // 10 of 128 = about  8%
	else                       boss_thr = 8'd124;   //  4 of 128 = about  3%
end

reg [1:0] spawn_type;
always @(*) begin
	// The boss is checked first because it is the rarest case.
	if (boss_allowed && type_pick >= boss_thr) spawn_type = Z_BOSS;
	else if (type_pick < norm_thr)             spawn_type = Z_NORMAL;
	else if (type_pick < fast_thr)             spawn_type = Z_FAST;
	else                                       spawn_type = Z_TANK;
end

// Zombies arrive in one of 8 lanes spaced 12 px apart, which makes them look
// like they are at different depths instead of marching in a single line.
// 8 lanes across 12 px spans 84 px and fits inside the 88 px walkable band.
wire [2:0] spawn_lane = rnd_row[2:0];
wire [9:0] spawn_row_base = ZOMBIE_MIN_Y +
						{3'd0, spawn_lane, 3'd0} +      // lane * 8
						{4'd0, spawn_lane, 2'd0};       // lane * 4  => lane * 12

// The boss is taller, so it starts higher up and its feet still land on the
// rubble instead of hanging below the play field.
wire [9:0] spawn_row = (spawn_type == Z_BOSS) ? (spawn_row_base - `BOSS_Y_RAISE)
											  : spawn_row_base;

// The boss is bigger than the other enemies, so its box and its hit insets are
// different. Everything that touches or shoots an enemy asks these three.
function [9:0] enemy_size;
	input [1:0] kind;
	begin enemy_size = (kind == Z_BOSS) ? `BOSS_H : `ZOMBIE_H; end
endfunction

function [9:0] enemy_hit_l;
	input [1:0] kind;
	begin enemy_hit_l = (kind == Z_BOSS) ? `BOSS_HIT_L : `ZOMBIE_HIT_L; end
endfunction

function [9:0] enemy_hit_r;
	input [1:0] kind;
	begin enemy_hit_r = (kind == Z_BOSS) ? `BOSS_HIT_R : `ZOMBIE_HIT_R; end
endfunction

// The boss is huge and heavy, so it only takes a step on every other frame.
// That works out to half a pixel a frame, which no counter can do directly.
wire boss_step = ~frame_cnt[0];

// How fast each kind walks, in pixels this frame.
function [9:0] zombie_speed;
	input [1:0] kind;
	input step;                    // pass boss_step here
	begin
		case (kind)
			Z_FAST:  zombie_speed = 10'd3;
			Z_TANK:  zombie_speed = 10'd1;
			// 1 pixel on half the frames, 0 on the rest = 0.5 pixels a frame.
			Z_BOSS:  zombie_speed = step ? 10'd1 : 10'd0;
			default: zombie_speed = 10'd2;
		endcase
	end
endfunction

// How many bullets each kind takes to kill.
function [3:0] zombie_hp;
	input [1:0] kind;
	begin
		case (kind)
			Z_TANK:  zombie_hp = 4'd3;
			Z_BOSS:  zombie_hp = BOSS_HP;
			default: zombie_hp = 4'd1;
		endcase
	end
endfunction

// Find an empty slot to spawn into
// Slot 0 belongs to the mini boss and nothing else, so this search starts at 1.
// Reserving it means only one boss can be alive at a time, and the four ordinary
// slots can never all be clogged with slow bosses. That last part matters more
// than it looks, because ordinary kills are what build the streak, the streak is
// what charges the skill, and the skill is what actually kills a boss.
reg free_z_found;
reg [2:0] free_z_idx;
always @(*) begin
	free_z_found = 1'b0;
	free_z_idx = 3'd1;
	for (i = MAX_ZOMBIE - 1; i >= 1; i = i - 1) begin
		if (!z_valid[i]) begin
			free_z_found = 1'b1;
			free_z_idx = i[2:0];
		end
	end
end

// Where the next spawn goes, and whether there is anywhere to put it.
wire [2:0] spawn_idx = (spawn_type == Z_BOSS) ? BOSS_SLOT : free_z_idx;
wire spawn_ok       = (spawn_type == Z_BOSS) ? 1'b1       : free_z_found;

reg free_b_found;
reg [2:0] free_b_idx;
always @(*) begin
	free_b_found = 1'b0;
	free_b_idx = 3'd0;
	for (i = MAX_BULLET - 1; i >= 0; i = i - 1) begin
		if (!b_valid[i]) begin
			free_b_found = 1'b1;
			free_b_idx = i[2:0];
		end
	end
end

// Bullets hitting zombies
// A bullet counts as a single point at its middle. That is accurate enough for
// something this small and costs far less logic than a full box against box test.
reg [MAX_BULLET-1:0] b_hit;
reg [MAX_ZOMBIE-1:0] z_hit;
reg [POS_BITS-1:0] bullet_cx;
reg [POS_BITS-1:0] bullet_cy;

always @(*) begin
	b_hit = 0;
	z_hit = 0;

	for (i = 0; i < MAX_BULLET; i = i + 1) begin
		bullet_cx = b_x[i] + (`BULLET_W >> 1);
		bullet_cy = b_y[i] + (`BULLET_H >> 1);

		for (j = 0; j < MAX_ZOMBIE; j = j + 1) begin
			if (b_valid[i] && z_valid[j] && !b_hit[i] &&
				bullet_cx >= z_x[j] + enemy_hit_l(z_type[j]) &&
				bullet_cx <  z_x[j] + enemy_hit_r(z_type[j]) &&
				bullet_cy >= z_y[j] &&
				bullet_cy <  z_y[j] + enemy_size(z_type[j])) begin
				b_hit[i] = 1'b1;
				z_hit[j] = 1'b1;
			end
		end
	end
end

// Did anything actually die this frame? Two zombies dying on the same frame only
// count once, which almost never happens and keeps this cheap.
reg killed_now;
always @(*) begin
	killed_now = 1'b0;
	for (i = 0; i < MAX_ZOMBIE; i = i + 1) begin
		if (z_valid[i] && z_hit[i] && z_hp[i] <= 4'd1)
			killed_now = 1'b1;
	end
end

// Losing the game
reg lose_now;
always @(*) begin
	lose_now = 1'b0;

	for (i = 0; i < MAX_ZOMBIE; i = i + 1) begin
		if (z_valid[i]) begin
			// Reached the house. The enemy's own left edge is what counts.
			if (z_x[i] + enemy_hit_l(z_type[i]) <= `HOUSE_X)
				lose_now = 1'b1;

			// Touched the player (box vs box).
			if (player_x             < z_x[i] + enemy_hit_r(z_type[i]) &&
				player_x + `PLAYER_W > z_x[i] + enemy_hit_l(z_type[i]) &&
				player_y             < z_y[i] + enemy_size(z_type[i]) &&
				player_y + `PLAYER_H > z_y[i])
				lose_now = 1'b1;
		end
	end
end

// The skill fires on the press, not while held, and only when it is charged.
wire skill_pressed = btn_skill && !btn_skill_q;
wire skill_fire = skill_pressed && skill_ready;

bin2bcd #(.BIN_BITS(10)) u_timer_bcd (
	.bin(timer),
	.bcd(timer_bcd)
);

// Pack the slot arrays into flat buses for the drawing layer
always @(*) begin
	z_valid_bus = 0;
	z_x_bus = 0;
	z_y_bus = 0;
	z_type_bus = 0;

	for (i = 0; i < MAX_ZOMBIE; i = i + 1) begin
		z_valid_bus[i] = z_valid[i];
		z_x_bus[i*POS_BITS +: POS_BITS] = z_x[i];
		z_y_bus[i*POS_BITS +: POS_BITS] = z_y[i];
		z_type_bus[i*2 +: 2] = z_type[i];
	end

	b_valid_bus = 0;
	b_x_bus = 0;
	b_y_bus = 0;

	for (i = 0; i < MAX_BULLET; i = i + 1) begin
		b_valid_bus[i] = b_valid[i];
		b_x_bus[i*POS_BITS +: POS_BITS] = b_x[i];
		b_y_bus[i*POS_BITS +: POS_BITS] = b_y[i];
	end
end

// The game itself
always @(posedge clk) begin
	if (!resetn) begin
		state <= S_IDLE;
		player_x <= PLAYER_MIN_X + 10'd64;
		player_y <= PLAYER_MAX_Y;
		timer <= 0;
		frame_cnt <= 0;
		spawn_cnt <= 8'd60;
		fire_cnt <= 0;
		kill_streak <= 0;
		skill_secs_left <= 0;
		btn_skill_q <= 0;

		for (i = 0; i < MAX_ZOMBIE; i = i + 1) begin
			z_valid[i] <= 1'b0;
			z_x[i] <= 0;
			z_y[i] <= 0;
			z_type[i] <= 2'd0;
			z_hp[i] <= 4'd0;
		end

		for (i = 0; i < MAX_BULLET; i = i + 1) begin
			b_valid[i] <= 1'b0;
			b_x[i] <= 0;
			b_y[i] <= 0;
		end
	end else if (frame_tick && state == S_IDLE) begin
		// Nothing moves and the timer stays at 0 until the first button press.
		btn_skill_q <= btn_skill;

		if (any_button)
			state <= S_PLAY;
	end else if (game_step) begin
		// Restarting after a game over is done with the board's reset button,
		// so the block above is the only place a new game is set up.
		btn_skill_q <= btn_skill;

		// Player
		if (btn_left && !btn_right)
			player_x <= (player_x > PLAYER_MIN_X + PLAYER_SPEED) ?
						player_x - PLAYER_SPEED : PLAYER_MIN_X;
		else if (btn_right && !btn_left)
			player_x <= (player_x + PLAYER_SPEED < PLAYER_MAX_X) ?
						player_x + PLAYER_SPEED : PLAYER_MAX_X;

		if (btn_up && !btn_down)
			player_y <= (player_y > PLAYER_MIN_Y + PLAYER_SPEED) ?
						player_y - PLAYER_SPEED : PLAYER_MIN_Y;
		else if (btn_down && !btn_up)
			player_y <= (player_y + PLAYER_SPEED < PLAYER_MAX_Y) ?
						player_y + PLAYER_SPEED : PLAYER_MAX_Y;

		// Skill
		// Pressing the button when the streak is full starts the fast-shooting
		// window and spends the streak.
		if (skill_fire) begin
			skill_secs_left <= SKILL_SECONDS[4:0];
			kill_streak <= 0;
		end else if (killed_now && kill_streak < KILLS_FOR_SKILL) begin
			kill_streak <= kill_streak + 6'd1;
		end

		// Zombies walk left, take damage and die
		for (i = 0; i < MAX_ZOMBIE; i = i + 1) begin
			if (z_valid[i]) begin
				z_x[i] <= z_x[i] - zombie_speed(z_type[i], boss_step);

				if (z_hit[i]) begin
					if (z_hp[i] <= 4'd1)
						z_valid[i] <= 1'b0;
					else
						z_hp[i] <= z_hp[i] - 4'd1;
				end
			end
		end

		// Spawn a new zombie at the right edge
		// A boss always goes in its reserved slot; spawn_type can only come out
		// as Z_BOSS when that slot is empty, so there is nothing to check here.
		if (spawn_cnt == 0 && spawn_ok) begin
			z_valid[spawn_idx] <= 1'b1;
			z_x[spawn_idx] <= SCREEN_W;
			z_y[spawn_idx] <= spawn_row;
			z_type[spawn_idx] <= spawn_type;
			z_hp[spawn_idx] <= zombie_hp(spawn_type);
			spawn_cnt <= spawn_period;
		end else if (spawn_cnt != 0) begin
			spawn_cnt <= spawn_cnt - 8'd1;
		end

		// Bullets fly right until they hit something or leave the screen
		for (i = 0; i < MAX_BULLET; i = i + 1) begin
			if (b_valid[i]) begin
				b_x[i] <= b_x[i] + BULLET_SPEED;
				if (b_hit[i] || b_x[i] + BULLET_SPEED >= SCREEN_W)
					b_valid[i] <= 1'b0;
			end
		end

		// The player shoots on his own, over and over
		if (fire_cnt == 0 && free_b_found) begin
			b_valid[free_b_idx] <= 1'b1;
			b_x[free_b_idx] <= player_x + `PLAYER_W;
			// The bullet art sits in the middle of its 16px box, so this puts
			// the bullet itself at about gun height on the 32px tall player.
			b_y[free_b_idx] <= player_y + 10'd7;
			fire_cnt <= fire_period;
		end else if (fire_cnt != 0) begin
			fire_cnt <= fire_cnt - 8'd1;
		end

		// Survival timer counts up, skill window counts down
		if (frame_cnt == FPS - 1) begin
			frame_cnt <= 0;
			if (timer < 10'd999)
				timer <= timer + 10'd1;
			if (skill_secs_left != 0)
				skill_secs_left <= skill_secs_left - 5'd1;
		end else begin
			frame_cnt <= frame_cnt + 8'd1;
		end

		// Did we just lose?
		if (lose_now)
			state <= S_OVER;
	end
end
endmodule
