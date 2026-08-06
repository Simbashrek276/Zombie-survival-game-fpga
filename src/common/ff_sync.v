`timescale 1ns / 1ps

// Two flip-flops in a row, the standard way to bring an outside signal into our
// clock. A button can change at any moment, including exactly at a clock edge,
// which can leave the first flop briefly undecided; the second one gives that
// settling a full cycle to finish before anything else looks at the value.
module ff_sync (
	input clk,
	input resetn,
	input in,
	output reg out
);
reg in_r;

always @(posedge clk) begin
	if (!resetn) begin
		in_r <= 0;
		out  <= 0;
	end else begin
		in_r <= in;
		out  <= in_r;
	end
end
endmodule
