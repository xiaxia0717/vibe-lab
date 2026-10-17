//=============================================================================
// canvas_pl.v - 空中画板硬件画布（wclk=cam 域写 / rclk=lcd 域读，TDP BRAM）
//---------------------------------------------------------------------------
//  pen 脉冲经 FIFO(深8) -> Bresenham 引擎逐点写画布（25MHz）
//  画布 C_W x C_H x 8bpp，索引 = 色相 hue，索引 0 = 透明黑
//  clear 脉冲 -> 全屏扫描清零（PIXELS 个 wclk）
//  r_en/r_addr 读口由 LCD 域 video_out 驱动，输出索引（一拍延时）
//=============================================================================
`timescale 1ns / 1ps

module canvas_pl #(
    parameter integer C_W = 320,
    parameter integer C_H = 240
)(
    input  wire        wclk,
    input  wire        w_rstn,
    input  wire        pen,
    input  wire [10:0] pen_x,
    input  wire [10:0] pen_y,
    input  wire        clear,

    input  wire        rclk,
    input  wire        r_en,
    input  wire [16:0] r_addr,
    output wire [7:0]  r_q
);

    localparam integer PIXELS = C_W * C_H;
    // fifo 数据格式：{1'b1, x[10:0], y[10:0]} = 23 bit
    localparam integer FW = 23;

    //---------- 画笔引擎信号（先声明）--------------------------------------
    reg [1:0]  state;
    reg        draw_claim_req;
    reg [10:0] nx, ny, cx, cy;
    reg [10:0] prev_x, prev_y;
    reg        have_prev;
    reg signed [12:0] dx, dy, err;
    reg signed [12:0] step_x, step_y;
    reg [7:0]  hue;
    reg [16:0] wr_addr;
    reg [7:0]  wr_data;
    reg        wr_en;

    localparam S_IDLE = 2'd0, S_INIT = 2'd1, S_WALK = 2'd2;

    //---------- pen FIFO（wclk 域，深 8）----------------------------------
    reg [FW-1:0] fifo_mem [0:7];
    reg [2:0]    fifo_widx, fifo_ridx;
    reg [3:0]    fifo_cnt;

    wire fifo_empty = (fifo_cnt == 4'd0);
    wire fifo_full  = (fifo_cnt == 4'd8);
    wire [22:0] head = fifo_mem[fifo_ridx];   // {pen, x, y}

    always @(posedge wclk or negedge w_rstn) begin
        if (!w_rstn) begin
            fifo_widx <= 3'd0; fifo_ridx <= 3'd0; fifo_cnt <= 4'd0;
        end else begin
            if (pen && !fifo_full) begin
                fifo_mem[fifo_widx] <= {1'b1, pen_x, pen_y};
                fifo_widx <= fifo_widx + 3'd1;
                fifo_cnt <= fifo_cnt + 4'd1;
            end
            if (!fifo_empty && draw_claim_req) begin
                fifo_ridx <= fifo_ridx + 3'd1;
                fifo_cnt <= fifo_cnt - 4'd1;
            end
        end
    end

    //---------- Bresenham 引擎 --------------------------------------------
    wire e2  = err * 2;                       // signed
    wire ge_x = (e2 > -dy);                   // 决策位 1
    wire ge_y = (e2 <  dx);                   // 决策位 2
    wire signed [12:0] err_after_x = ge_x ? (err - dy) : err;
    wire signed [12:0] err_next    = ge_y ? (err_after_x + dx) : err_after_x;

    always @(posedge wclk or negedge w_rstn) begin
        if (!w_rstn) begin
            state <= S_IDLE; draw_claim_req <= 1'b0;
            nx<=0; ny<=0; cx<=0; cy<=0; prev_x<=0; prev_y<=0;
            have_prev<=0; step_x<=1; step_y<=1; dx<=0; dy<=0; err<=0; hue<=0;
            wr_en<=0; wr_addr<=0; wr_data<=0;
        end else begin
            draw_claim_req <= 1'b0;
            wr_en <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (!fifo_empty) begin
                        draw_claim_req <= 1'b1;
                        nx <= head[20:10];        // pen x
                        ny <= head[10:0];         // pen y
                        cx <= have_prev ? prev_x : head[20:10];
                        cy <= have_prev ? prev_y : head[10:0];
                        state <= S_INIT;
                    end
                end
                S_INIT: begin
                    dx     <= (nx >= cx) ? (nx - cx) : (cx - nx);
                    dy     <= (ny >= cy) ? (ny - cy) : (cy - ny);
                    step_x <= (nx >= cx) ? 13'sd1 : -13'sd1;
                    step_y <= (ny >= cy) ? 13'sd1 : -13'sd1;
                    err    <= 13'sd0;
                    state  <= S_WALK;
                end
                S_WALK: begin
                    wr_en   <= 1'b1;
                    wr_addr <= cy * C_W + cx;
                    wr_data <= hue;
                    if (cx == nx && cy == ny) begin
                        prev_x    <= nx;
                        prev_y    <= ny;
                        have_prev <= 1'b1;
                        hue       <= hue + 8'd7;
                        state     <= S_IDLE;
                    end else begin
                        cx  <= ge_x ? (cx + step_x) : cx;
                        cy  <= ge_y ? (cy + step_y) : cy;
                        err <= err_next;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    //---------- 清屏 FSM ---------------------------------------------------
    reg        clr_state;
    reg [16:0] clr_addr;
    localparam C_IDLE=1'b0, C_RUN=1'b1;

    always @(posedge wclk or negedge w_rstn) begin
        if (!w_rstn) begin clr_state <= C_IDLE; clr_addr <= 0; end
        else case (clr_state)
            C_IDLE: if (clear) begin clr_state <= C_RUN; clr_addr <= 0; end
            C_RUN: begin
                if (clr_addr == PIXELS-1) begin clr_state <= C_IDLE; clr_addr <= 0; end
                else clr_addr <= clr_addr + 1;
            end
        endcase
    end

    //---------- 写仲裁：clear 优先 -----------------------------------------
    wire [16:0] w_addr_f = (clr_state == C_RUN) ? clr_addr : wr_addr;
    wire [7:0]  w_data_f = (clr_state == C_RUN) ? 8'h00  : wr_data;
    wire        w_en_f   = (clr_state == C_RUN) ? 1'b1   : wr_en;

    //---------- 画布 RAM：TDP，wclk 写 / rclk 读 ---------------------------
    (* ram_style = "block" *)
    reg [7:0] canvas_mem [0 : PIXELS-1];

    always @(posedge wclk) begin
        if (w_en_f) canvas_mem[w_addr_f] <= w_data_f;
    end

    reg [7:0] r_q_r;
    always @(posedge rclk) begin
        if (r_en) r_q_r <= canvas_mem[r_addr];
    end
    assign r_q = r_q_r;

endmodule
