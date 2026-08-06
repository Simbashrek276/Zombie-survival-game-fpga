`timescale 1ns / 1ps

// A real button contact bounces for a few milliseconds when pressed, which the
// FPGA would otherwise read as a burst of presses. So only believe a new level
// once it has held still for the whole count: about 8 ms at the 25.2 MHz pixel
// clock this runs on.
module debounce #(
	parameter DEBOUNCE_CYCLES = 200000,
	parameter CNT_BITS = $clog2(DEBOUNCE_CYCLES)
) (
	input clk,
	input resetn,
	input in,
	output reg out
);

reg [CNT_BITS-1:0] cnt;

// The buttons pull the pin low when pressed, so flip it here and let everything
// downstream treat 1 as held.
wire in_active = ~in;
wire cnt_done = (cnt == DEBOUNCE_CYCLES - 1);

always @(posedge clk) begin
	if (!resetn) begin
		out <= 0;
		cnt <= 0;
	end else begin
		if (in_active == out) begin
			cnt <= 0;
		end else if (cnt_done) begin
			out <= in_active;
			cnt <= 0;
		end else begin
			cnt <= cnt + 1;
		end
	end
end

endmodule