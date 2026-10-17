//=============================================================================
// tracker_pl.v - 空中画板笔尖追踪器（cam_pclk 域，无 AXI 裸接口版）
//---------------------------------------------------------------------------
// 输入 320x240 RGB565 流，硬件完成：
//   背景学习 -> 灰度差分 -> 目标质心 -> pen 输出
//   目标丢失超过 LOST_FRAMES 帧 -> clear 脉冲（清画布）
// 每帧结束输出 pen/pen_x/pen_y（+ 一整拍），由 canvas 画线。
//=============================================================================
`timescale 1ns / 1ps

module tracker_pl #(
    parameter integer TRK_W      = 320,
    parameter integer TRK_H      = 240,
    parameter integer THR        = 64,     // 差分阈值
    parameter integer MIN_AREA   = 3,      // 有效目标最小面积（3x3 笔帽降采样后剩 2x2=4，故取 3）
    parameter integer LOST_FRAMES = 45     // 丢失这么多帧 = 清屏手势（~1.5s）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,       // 下采样像素有效
    input  wire [15:0] in_data,        // RGB565

    input  wire        learn,          // 学习脉冲：冻结当前帧为背景（自动清）

    output reg         pen,            // 帧末笔尖有效（一拍）
    output reg  [10:0] pen_x,          // 质心 X（0..TRK_W-1）
    output reg  [10:0] pen_y,          // 质心 Y
    output reg         clear           // 丢失超时：清画布（一拍）
);

    //---- 灰度化：RGB565 先扩 8bit 再按 BT.601 加权 ------------------------
    wire [4:0] r5 = in_data[15:11];
    wire [5:0] g6 = in_data[10:5];
    wire [4:0] b5 = in_data[4:0];
    wire [7:0] r8 = {r5, r5[4:2]};
    wire [7:0] g8 = {g6, g6[5:4]};
    wire [7:0] b8 = {b5, b5[4:2]};
    wire [17:0] luma_sum = r8 * 18'd76 + g8 * 18'd150 + b8 * 18'd29;
    wire [7:0] gray = luma_sum[17:8];

    //---- 像素坐标（stream 自带）---------------------------------------------
    wire in_fire = in_valid;
    reg [15:0] x_cnt, y_cnt;

    //---- 背景学习 -----------------------------------------------------------
    reg learn_req, learn_armed, learning, bg_locked;
    wire frame_start = in_fire && (x_cnt == 0) && (y_cnt == 0);
    wire frame_end   = in_fire && (x_cnt == TRK_W-1) && (y_cnt == TRK_H-1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            learn_req <= 0; learn_armed <= 0; learning <= 0; bg_locked <= 0;
        end else begin
            if (learn) learn_req <= 1'b1;
            if (learn_req && frame_start) begin learn_armed <= 1'b1; learning <= 1'b1; end
            if (learn_armed && frame_end) begin
                learn_req <= 1'b0; learn_armed <= 1'b0;
                learning <= 1'b0; bg_locked <= 1'b1;
            end
        end
    end

    //---- 背景 RAM（read-first，一拍延迟与 d 级像素对齐）---------------------
    reg [7:0] bg_mem [0 : TRK_W*TRK_H-1];
    reg [7:0] bg_q;
    wire [31:0] bg_addr = y_cnt * TRK_W + x_cnt;   // 当前级地址

    always @(posedge clk) begin
        if (in_fire) begin
            bg_q <= bg_mem[bg_addr];
            if (learning) bg_mem[bg_addr] <= gray;
        end
    end

    //---- 延迟一级流水线 ------------------------------------------------------
    reg [15:0] x_d, y_d;
    reg [7:0]  gray_d;
    reg        in_fire_d;

    always @(posedge clk) begin
        if (in_fire) begin
            x_d <= x_cnt; y_d <= y_cnt; gray_d <= gray; in_fire_d <= 1'b1;
        end else begin
            in_fire_d <= 1'b0;
        end
    end

    //---- 差分掩码 -----------------------------------------------------------
    wire [8:0] diff = (gray_d >= bg_q) ? ({1'b0, gray_d} - {1'b0, bg_q})
                                       : ({1'b0, bg_q} - {1'b0, gray_d});
    wire hit = bg_locked && !learning && (diff > THR[8:0]) && in_fire_d;

    //---- 行内/全帧累加 -------------------------------------------------------
    reg  [31:0] row_x, row_a;
    reg  [31:0] acc_x, acc_y, acc_a;
    wire [31:0] row_x_next = row_x + (hit ? {16'd0, x_d} : 32'd0);
    wire [31:0] row_a_next = row_a + (hit ? 32'd1 : 32'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_x<=0; row_a<=0; acc_x<=0; acc_y<=0; acc_a<=0;
        end else if (in_fire_d && bg_locked) begin
            if (x_d == 0 && y_d == 0) begin
                row_x<=0; row_a<=0; acc_x<=0; acc_y<=0; acc_a<=0;
            end else if (y_d == TRK_H-1 && x_d == TRK_W-1) begin
                acc_x <= acc_x + row_x_next;
                acc_y <= acc_y + y_d * row_a_next;
                acc_a <= acc_a + row_a_next;
                row_x <= 0; row_a <= 0;
            end else if (x_d == TRK_W-1) begin
                acc_x <= acc_x + row_x_next;
                acc_y <= acc_y + y_d * row_a_next;
                acc_a <= acc_a + row_a_next;
                row_x <= 0; row_a <= 0;
            end else begin
                row_x <= row_x_next;
                row_a <= row_a_next;
            end
        end
    end

    //---- 帧末锁存 + 除法 -----------------------------------------------------
    reg div_start;
    reg [31:0] snap_x, snap_y, snap_a;
    wire frame_end_d = in_fire_d && (x_d == TRK_W-1) && (y_d == TRK_H-1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            snap_x<=0; snap_y<=0; snap_a<=0; div_start<=0;
        end else if (in_fire_d && y_d == TRK_H-1 && x_d == TRK_W-1) begin
            snap_x <= acc_x + row_x_next;
            snap_y <= acc_y + y_d * row_a_next;
            snap_a <= acc_a + row_a_next;
            div_start <= 1'b1;
        end else begin
            div_start <= 1'b0;
        end
    end

    wire [23:0] q_x, q_y;
    wire d_x, d_y;

    uint_div #(.W(24)) div_x (.clk(clk), .rst_n(rst_n), .start(div_start),
        .num(snap_x[23:0]), .den(snap_a[23:0]), .quo(q_x), .done(d_x));
    uint_div #(.W(24)) div_y (.clk(clk), .rst_n(rst_n), .start(div_start),
        .num(snap_y[23:0]), .den(snap_a[23:0]), .quo(q_y), .done(d_y));

    //---- pen 输出 + 丢失清屏 ---------------------------------------------------
    reg [15:0] lost_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pen<=0; pen_x<=0; pen_y<=0; clear<=0; lost_cnt<=0;
        end else begin
            pen   <= 1'b0;
            clear <= 1'b0;
            if (d_x) begin
                if (snap_a >= MIN_AREA[31:0]) begin
                    pen   <= 1'b1;
                    pen_x <= q_x[10:0];
                    pen_y <= q_y[10:0];
                    lost_cnt <= 0;
                end else begin
                    lost_cnt <= lost_cnt + 1;
                    if (lost_cnt >= LOST_FRAMES[15:0]) begin
                        clear   <= 1'b1;      // 清屏手势
                        lost_cnt <= 0;
                    end
                end
            end
        end
    end

    //---- 坐标计数 -------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin x_cnt <= 0; y_cnt <= 0; end
        else if (in_fire) begin
            if (x_cnt == TRK_W-1) begin
                x_cnt <= 0;
                y_cnt <= (y_cnt == TRK_H-1) ? 0 : y_cnt + 1;
            end else begin
                x_cnt <= x_cnt + 1;
            end
        end
    end

endmodule
