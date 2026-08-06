`timescale 1ns / 1ps

// Splits a binary number into three decimal digits so it can be drawn on screen,
// using the double-dabble trick: shift the number left one bit at a time, and
// before each shift add 3 to any digit that has reached 5. That add is what
// makes a digit carry at 10 instead of at 16, and it avoids ever dividing.
//
// This is all wires, no clock, so the digits are ready in the same cycle.
module bin2bcd #(
	parameter BIN_BITS = 10
) (
	input [BIN_BITS-1:0] bin,
	output reg [11:0] bcd
);

integer i;
// The number being shifted, with room for the three digits growing above it.
reg [BIN_BITS+12-1:0] shift;

always @(*) begin
	shift = 0;
	shift[BIN_BITS-1:0] = bin;

	for (i = 0; i < BIN_BITS; i = i + 1) begin
		if (shift[BIN_BITS + 3 : BIN_BITS] >= 4'd5)
			shift[BIN_BITS + 3 : BIN_BITS] =
				shift[BIN_BITS + 3 : BIN_BITS] + 4'd3;

		if (shift[BIN_BITS + 7 : BIN_BITS + 4] >= 4'd5)
			shift[BIN_BITS + 7 : BIN_BITS + 4] =
				shift[BIN_BITS + 7 : BIN_BITS + 4] + 4'd3;

		if (shift[BIN_BITS + 11 : BIN_BITS + 8] >= 4'd5)
			shift[BIN_BITS + 11 : BIN_BITS + 8] =
				shift[BIN_BITS + 11 : BIN_BITS + 8] + 4'd3;

		shift = shift << 1;
	end

	bcd = shift[BIN_BITS + 11 : BIN_BITS];
end

endmodule
