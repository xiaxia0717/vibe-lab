//=============================================================================
// uint_div.v - 24 位恢复余数除法器（从 color_tracker.v 拆出复用）
// W 拍迭代：start 后第 W+1 拍 done 有效一拍，quo = num/den。
//=============================================================================
`timescale 1ns / 1ps

module uint_div #(
    parameter integer W = 24
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            start,
    input  wire [W-1:0]    num,
    input  wire [W-1:0]    den,
    output reg  [W-1:0]    quo,
    output reg             done
);
    reg [W-1:0] a_q;
    reg [W-1:0] rem;
    reg [W-1:0] b;
    integer cnt;
    reg busy;

    wire [W-1:0] shifted = {rem[W-2:0], a_q[W-1]};
    wire [W:0]   sub     = {1'b0, shifted} - {1'b0, b};
    wire         ge      = ~sub[W];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; done <= 1'b0; quo <= 0; cnt <= 0;
        end else if (!busy) begin
            done <= 1'b0;
            if (start) begin
                a_q <= num; rem <= 0; b <= den; cnt <= W-1; busy <= 1'b1;
            end
        end else begin
            rem <= ge ? sub[W-1:0] : shifted;
            a_q <= {a_q[W-2:0], 1'b0};
            quo[cnt] <= ge;
            if (cnt == 0) begin busy <= 1'b0; done <= 1'b1; end
            else           cnt <= cnt - 1;
        end
    end
endmodule
