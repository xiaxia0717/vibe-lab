//=============================================================================
// cam_capture_ds.v - OV5640 采集 + 2x2 降采样（cam_pclk 域）
//---------------------------------------------------------------------------
// 输入：640x480 RGB565 DVP 流（cam_href 内每像素 2 字节，高字节在前）
// 输出：320x240 RGB565（写帧缓冲 + 直送 tracker）
//=============================================================================
`timescale 1ns / 1ps

module cam_capture_ds #(
    parameter CMOS_W = 640,
    parameter CMOS_H = 480,
    parameter DS_W   = 320,
    parameter DS_H   = 240
)(
    input  wire        cam_pclk,
    input  wire        rst_n,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_data,

    output reg  [15:0] fr_data,      // 帧缓冲写数据（RGB565）
    output reg  [14:0] fr_addr,      // 帧缓冲写地址 0..DS_W*DS_H-1
    output reg         fr_we,        // 帧缓冲写使能
    output reg  [15:0] ds_data,      // 送 tracker 的像素
    output reg         ds_valid      // 送 tracker 的有效（含行尾一拍）
);

    // vsync 下沿=帧起始
    reg vsync_d1, vsync_d2;
    wire neg_vsync =  vsync_d1 & ~vsync_d2;
    always @(posedge cam_pclk or negedge rst_n) begin
        if (!rst_n) begin vsync_d1 <= 1'b0; vsync_d2 <= 1'b0; end
        else begin vsync_d1 <= cam_vsync; vsync_d2 <= vsync_d1; end
    end

    reg [10:0] byte_cnt;   // href 内字节计数 0..2*CMOS_W-1
    reg [10:0] row_cnt;    // 行计数 0..CMOS_H-1
    reg [7:0]  rgb_h;      // RGB565 高字节锁存
    reg        take_row;   // 本行需要采（偶行）
    reg [15:0] ds_pix;     // 已拼好的下采样像素（等待发出）

    integer ds_addr_next;
    always @(posedge cam_pclk or negedge rst_n) begin
        if (!rst_n) begin
            byte_cnt <= 11'd0; row_cnt <= 11'd0; rgb_h <= 8'd0;
            take_row <= 1'b0; ds_pix <= 16'd0;
            fr_we <= 1'b0; fr_data <= 16'd0; fr_addr <= 15'd0;
            ds_valid <= 1'b0; ds_data <= 16'd0;
        end else begin
            fr_we     <= 1'b0;
            ds_valid  <= 1'b0;

            if (neg_vsync) begin
                byte_cnt <= 11'd0;
                row_cnt  <= 11'd0;
            end else if (cam_href) begin
                if (byte_cnt[0] == 1'b0) begin
                    // 偶数字节 = RGB565 高字节
                    rgb_h <= cam_data;
                end else begin
                    // 奇数字节 = 低字节，凑齐一个像素
                    ds_pix <= {rgb_h, cam_data};
                    if (take_row && (byte_cnt[10:1] & 11'd1) == 11'd0) begin
                        // 本行要采、且是行内偶像素 → 发一拍
                        fr_addr  <= (row_cnt[10:1] * DS_W) + (byte_cnt[10:2]);
                        fr_data  <= {rgb_h, cam_data};
                        fr_we    <= 1'b1;
                        ds_data  <= {rgb_h, cam_data};
                        ds_valid <= 1'b1;
                    end
                end
                byte_cnt <= byte_cnt + 11'd1;
            end else begin
                // href 落下：行尾
                if (row_cnt != 11'd2047)
                    row_cnt <= row_cnt + 11'd1;
                byte_cnt <= 11'd0;
            end
        end
    end

    // 只采偶行（480 -> 240）
    always @(posedge cam_pclk or negedge rst_n) begin
        if (!rst_n)            take_row <= 1'b0;
        else if (neg_vsync)    take_row <= 1'b1;   // 第一行必采
        else if (!cam_href)    take_row <= ~take_row;
    end

endmodule
