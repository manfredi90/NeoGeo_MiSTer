// Behavioural model of rtl/mem/dpram.v (altsyncram) for the simulation.
module dpram #(parameter ADDRWIDTH=8, DATAWIDTH=8, NUMWORDS=1<<ADDRWIDTH, MEM_INIT_FILE="")
(
	input                  clock_a,
	input  [ADDRWIDTH-1:0] address_a,
	input  [DATAWIDTH-1:0] data_a,
	input                  wren_a,
	output reg [DATAWIDTH-1:0] q_a,
	input                  clock_b,
	input  [ADDRWIDTH-1:0] address_b,
	input  [DATAWIDTH-1:0] data_b,
	input                  wren_b,
	output reg [DATAWIDTH-1:0] q_b
);
reg [DATAWIDTH-1:0] ram[NUMWORDS];
always @(posedge clock_a) begin
	if (wren_a) ram[address_a] <= data_a;
	q_a <= ram[address_a];
end
always @(posedge clock_b) begin
	if (wren_b) ram[address_b] <= data_b;
	q_b <= ram[address_b];
end
endmodule
