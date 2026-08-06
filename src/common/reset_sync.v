`timescale 1ns / 1ps

// Turns the raw reset pin into one the rest of the design can use. Reset takes
// effect the instant the pin drops, but is only released 15 clocks after the pin
// comes back, and always on a clock edge. Letting go of reset partway through a
// cycle is the dangerous half, because different flops would wake on different
// edges and the design would start out inconsistent with itself.
module reset_sync (
	input clk,
	input ext_reset,
	output resetn
);

// Counts up while held low and stops at all-ones, which is what releases reset.
reg [3:0] reset_cnt = 0;

always @(posedge clk or negedge ext_reset) begin
	if (!ext_reset)
		reset_cnt <= 0;
	else
		reset_cnt <= reset_cnt + !resetn;
end

assign resetn = &reset_cnt;

endmodule
