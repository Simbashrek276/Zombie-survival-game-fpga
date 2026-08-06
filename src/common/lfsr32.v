`timescale 1ns / 1ps

// Cheap pseudo-random numbers: a shift register fed by a xor of a few of its own
// bits. It is not random in any serious sense, but it never repeats within a
// game and costs almost nothing, which is what matters here.
//
// The seed must never be zero. An all-zero register xors to zero forever and the
// output sticks. Give each instance its own seed too, or they march in step.
module lfsr32 #(
	parameter [31:0] SEED = 32'hACE1_1234
) (
	input wire clk,
	input wire resetn,
	input wire en,
	output reg [31:0] rnd
);
// These particular four bits are the taps that give the longest possible cycle
// for a 32-bit register. They are not arbitrary; changing them shortens it.
wire feedback = rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0];

always @(posedge clk) begin
	if (!resetn)
		rnd <= SEED;
	else if (en)
		rnd <= {rnd[30:0], feedback};
end
endmodule
