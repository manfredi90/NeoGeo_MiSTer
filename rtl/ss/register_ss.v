// register (rtl/io/register.v) with a savestate load port: while SS_LD is high the
// stored value is replaced by SS_D. q is the value that gets saved.

module register_ss (
	input clock,
	input s,    // set
	input r,    // reset
	input c,    // write clock
	input [WIDTH-1:0] d,    // new value
	output reg [WIDTH-1:0] q,    // value
	input SS_LD,
	input [WIDTH-1:0] SS_D
);

parameter WIDTH = 1;

reg [WIDTH-1:0] val_reg;
reg c_d;

always @(*) begin
	if (r)
		q = 0;
	else if (s)
		q = {WIDTH{1'b1}};
	else
		q = val_reg;
end

always @(posedge clock) begin
	c_d <= c;
	if (SS_LD)
		val_reg <= SS_D;
	else if (~c_d & c & ~r & ~s)
		val_reg <= d;
	else
		val_reg <= q;
end

endmodule
