//=============================================================================
// video_out.v - 800x480 显示合成（lcd_pclk 域）
//---------------------------------------------------------------------------
//  从 320x240 帧缓冲 nearest 上采样（x2.5 / y2），叠加画布彩虹笔迹，
//  输出 RGB888 给 lcd_driver。
//  注意：BRAM 读延迟使整幅图水平右移 1 像素（画板应用无感）。
//=============================================================================
`timescale 1ns / 1ps

module video_out #(
    parameter integer SRC_W = 320,
    parameter integer SRC_H = 240,
    parameter integer LCD_W = 800,
    parameter integer LCD_H = 480
)(
    input  wire        lcd_pclk,
    input  wire        rst_n,
    input  wire [10:0] xpos,        // lcd_driver 当前像素坐标（有效区内 0..799）
    input  wire [10:0] ypos,        // 0..479
    input  wire        disp_en,     // 有效显示区（lcd_de）

    output reg  [16:0] frame_raddr, // 帧缓冲读地址
    output reg         frame_ren,
    input  wire [15:0] frame_q,     // 帧缓冲数据 RGB565

    output reg  [16:0] canvas_raddr,// 画布读地址
    output reg         canvas_ren,
    input  wire [7:0]  canvas_q,    // 画布索引（色相）

    output reg  [23:0] pixel_data   // 送 lcd_driver 的 RGB888
);

    //---- 源坐标：x2.5 用累加器实现，y2 用移位 -----------------------------
    // xpos 0..799 -> src_x 0..319（每 de 拍前进 0 或 1）
    reg [10:0] src_x;
    reg [10:0] xacc;
    wire [10:0] src_y = ypos[10:1];          // /2

    always @(posedge lcd_pclk or negedge rst_n) begin
        if (!rst_n) begin src_x <= 0; xacc <= 0; end
        else if (disp_en) begin
            if (xpos == 11'd0) begin                    // 行首：重置累加器
                src_x <= 11'd0;
                xacc <= 11'd0;
            end else if (xacc >= 11'd800 - 11'd320) begin
                xacc <= xacc + 11'd320 - 11'd800;       // 进位：源像素 +1
                src_x <= src_x + 11'd1;
            end else begin
                xacc <= xacc + 11'd320;
            end
        end
    end

    //---- 读请求（当前 xpos/ypos 一拍前发起，数据延迟与输出对齐）----------
    wire [16:0] src_addr = src_y * SRC_W + src_x;

    always @(*) begin
        frame_ren  = disp_en;
        frame_raddr = src_addr;
        canvas_ren  = disp_en;
        canvas_raddr = src_addr;
    end

    //---- canvas 索引 -> RGB565（硬件 HSV 三角波）-------------------------
    function [15:0] hue2rgb565;
        input [7:0] h;
        reg [8:0] d0, d1, d2;
        reg [7:0] l0, l1, l2;
        begin
            // 色相到三个通道的三角波，扇区中心 0/85/170
            d0 = (h > 8'd0)   ? (h - 8'd0)   : (8'd0 - h);
            if (d0 > 9'd128) d0 = 9'd256 - d0;
            d1 = (h > 8'd85)  ? (h - 8'd85)  : (8'd85 - h);
            if (d1 > 9'd128) d1 = 9'd256 - d1;
            d2 = (h > 8'd170) ? (h - 8'd170) : (8'd170 - h);
            if (d2 > 9'd128) d2 = 9'd256 - d2;
            l0 = (d0 < 9'd85) ? ((9'd85 - d0) * 8'd3) : 8'd0;
            l1 = (d1 < 9'd85) ? ((9'd85 - d1) * 8'd3) : 8'd0;
            l2 = (d2 < 9'd85) ? ((9'd85 - d2) * 8'd3) : 8'd0;
            hue2rgb565 = {l0[7:3], l1[7:2], l2[7:3]};   // 5/6/5
        end
    endfunction

    wire [15:0] pen_565 = hue2rgb565(canvas_q);

    //---- 叠加 + 565->888 ---------------------------------------------------
    wire pen_hit = (canvas_q != 8'd0);       // 索引 0 = 透明
    wire [15:0] mix_565 = pen_hit ? pen_565 : frame_q;
    wire [7:0] r8 = {mix_565[15:11], mix_565[15:13]};
    wire [7:0] g8 = {mix_565[10:5],  mix_565[10:9]};
    wire [7:0] b8 = {mix_565[4:0],   mix_565[4:2]};

    always @(*) pixel_data = {r8, g8, b8};

endmodule
