`timescale 1ns / 1ps

// Read-only memory filled from a .mem file at build time, holding the sprites,
// the background image and the font. It is written in this exact shape on
// purpose. Gowin's tools recognise the pattern and map it onto a real block of
// RAM, while a version that answered in the same cycle would be built out of
// logic instead and would never fit.
//
// The price is that a read arrives one cycle late, which is why every layer that
// reads a ROM carries a matching pipeline stage.
module rom #(
	parameter DATA_WIDTH = 16,
	parameter DEPTH = 1024,
	parameter ADDR_WIDTH = $clog2(DEPTH),
	// Every user of this ROM passes its own file; there is no sensible default.
	parameter INIT_FILE = ""
)(
	input clk,
	input [ADDR_WIDTH-1:0] addr,
	output reg [DATA_WIDTH-1:0] data
);
reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

initial begin
	$readmemh(INIT_FILE, mem);
end

always @(posedge clk) begin
	data <= mem[addr];
end
endmodule
