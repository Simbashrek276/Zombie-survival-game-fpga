// The screen is 640x480. The background image occupies the band from Y 16 to
// 416, with a dark UI bar above it and another below.
`define UI_TOP 10'd416

// Map layout, which has to match the rubble line in src/assets/daylight.mem.
//
// daylight.png is a 1536x1024 ruined city at sunset. png2mem drops its top 260
// rows, then squeezes what is left into the 80x50 tile. We measured the tile it
// generated and found that the city gives way to foreground rubble at screen
// Y = 328, which leaves an 88 px deep strip to walk on.
//
// If you change the art or CropTop, measure it again. Get this wrong and the
// characters either float above the ground or sink into it.
//
// A character stands with its feet on the rubble, so a sprite's bottom edge has
// to stay between GROUND_TOP and GROUND_BOT. The rest of the sprite is free to
// stick up into the sky, and that is what makes a side view look right.
`define GROUND_TOP 10'd328
`define GROUND_BOT `UI_TOP

// The base you defend is a concrete bunker on the left, standing on the rubble.
// Any zombie that walks past HOUSE_X has reached it and the run is over.
// bg_layer draws it from plain rectangles so it costs no block RAM.
`define HOUSE_X 10'd96
`define HOUSE_H 10'd120

// The player is 32x32 on screen and comes straight from a 32x32 sprite, one
// source pixel per screen pixel. If you want him bigger again, double these and
// change the [4:0] slices in obj_layer.v back to [5:1] as well.
`define PLAYER_W 10'd32
`define PLAYER_H 10'd32

// Zombies are also 32x32, one source pixel per screen pixel. The art is
// narrower than its square box and only fills columns 4 to 26, so touching and
// shooting both use an inset box. Without it you would die to empty air.
`define ZOMBIE_W 10'd32
`define ZOMBIE_H 10'd32
`define ZOMBIE_HIT_L 10'd4
`define ZOMBIE_HIT_R 10'd27

// The mini boss is three times the size of a normal zombie, so 96x96. We store
// it as a 24x24 sprite and blow every pixel up to 4x4, since 24 * 4 = 96.
// Scaling by 4 is free in hardware because dividing by 4 just means dropping two
// address bits. Keeping the art at 32x32 and scaling by 3 would need a real
// divide by 3, and this chip has no room for that.
`define BOSS_W 10'd96
`define BOSS_H 10'd96
// The boss art fills source columns 2..21, which at 4x is screen columns 8..87
// inside its 96 px box.
`define BOSS_HIT_L 10'd8
`define BOSS_HIT_R 10'd88
// A boss stands 64 px taller than a zombie, so it spawns that much higher up to
// keep its feet on the rubble.
`define BOSS_Y_RAISE 10'd64

// Bullets are 16x16 and come from a 16x16 sprite. The art only fills the middle
// few rows of that box and the rest is see-through.
`define BULLET_W 10'd16
`define BULLET_H 10'd16
