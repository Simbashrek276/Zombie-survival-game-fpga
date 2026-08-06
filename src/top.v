// Board level: makes the clocks, cleans up the buttons, and hands the game's
// pixels to the HDMI transmitter.
//
// The board has a 27 MHz crystal but HDMI needs two related clocks: one at the
// pixel rate and one five times faster to shift the serial data out. The PLL
// makes the fast one (126 MHz) and the divider derives the pixel clock from it,
// so the two can never drift apart. Everything except the TMDS output runs on
// the 25.2 MHz pixel clock.
module top (
	input clk,
	input resetn,
	input btn_up,
	input btn_down,
	input btn_left,
	input btn_right,
	input btn_skill,

	output tmds_clk_n,
	output tmds_clk_p,
	output [2:0] tmds_d_n,
	output [2:0] tmds_d_p
);

wire clk_p;
wire clk_p5;
wire pll_lock;
wire sys_resetn;

// Each button goes through two stages: _syn drags it into our clock domain,
// then _deb waits out the contact bounce. Only the _deb versions are used.
wire btn_up_syn, btn_up_deb;
wire btn_down_syn, btn_down_deb;
wire btn_left_syn, btn_left_deb;
wire btn_right_syn, btn_right_deb;
wire btn_skill_syn, btn_skill_deb;

wire game_tvalid;
wire game_tready;
wire [23:0] game_tdata;
wire [0:0] game_tuser;

Gowin_CLKDIV u_clkdiv (
	.clkout(clk_p),
	.hclkin(clk_p5),
	.resetn(pll_lock)
);

Gowin_PLLVR u_pll (
	.clkout(clk_p5),
	.lock(pll_lock),
	.clkin(clk)
);

reset_sync u_reset_sync (
	.clk(clk_p),
	.ext_reset(resetn & pll_lock),
	.resetn(sys_resetn)
);

ff_sync u_btn_left_syn (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_left),
	.out(btn_left_syn)
);

ff_sync u_btn_right_syn (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_right),
	.out(btn_right_syn)
);

ff_sync u_btn_up_syn (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_up),
	.out(btn_up_syn)
);

ff_sync u_btn_down_syn (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_down),
	.out(btn_down_syn)
);

ff_sync u_btn_skill_syn (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_skill),
	.out(btn_skill_syn)
);

debounce u_btn_left_deb (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_left_syn),
	.out(btn_left_deb)
);

debounce u_btn_right_deb (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_right_syn),
	.out(btn_right_deb)
);

debounce u_btn_up_deb (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_up_syn),
	.out(btn_up_deb)
);

debounce u_btn_down_deb (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_down_syn),
	.out(btn_down_deb)
);

debounce u_btn_skill_deb (
	.clk(clk_p),
	.resetn(sys_resetn),
	.in(btn_skill_syn),
	.out(btn_skill_deb)
);

game_core #(
	.SVO_MODE("640x480V")
) u_game_core (
	.clk(clk_p),
	.resetn(sys_resetn),

	.btn_up(btn_up_deb),
	.btn_down(btn_down_deb),
	.btn_left(btn_left_deb),
	.btn_right(btn_right_deb),
	.btn_skill(btn_skill_deb),

	.out_axis_tvalid(game_tvalid),
	.out_axis_tready(game_tready),
	.out_axis_tdata(game_tdata),
	.out_axis_tuser(game_tuser)
);

svo_hdmi #(
	.SVO_MODE("640x480V")
) u_svo_hdmi (
	.resetn(sys_resetn),

	.clk_pixel(clk_p),
	.clk_5x_pixel(clk_p5),
	.locked(pll_lock),

	.in_axis_tvalid(game_tvalid),
	.in_axis_tready(game_tready),
	.in_axis_tdata(game_tdata),
	.in_axis_tuser(game_tuser),

	.tmds_clk_n(tmds_clk_n),
	.tmds_clk_p(tmds_clk_p),
	.tmds_d_n(tmds_d_n),
	.tmds_d_p(tmds_d_p)
);

endmodule
