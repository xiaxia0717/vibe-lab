//=============================================================================
// top_air_canvas.v - 空中画板顶层（纯 PL，无 ARM 无 PS）
//---------------------------------------------------------------------------
//  数据流：
//    OV5640(640x480 RGB565) --cam_capture_ds--> 320x240 RGB565
//      ├─> frame_buf (320x240 TDP BRAM, cam写/lcd读)
//      └─> tracker_pl -> pen 坐标 -> canvas_pl 画线 -> 叠加到 LCD
//    lcd_driver 800x480 时序 -> video_out 上采样合成 -> RGB 屏
//
//  交互：
//    key_learn  = 重新学习背景 + 清屏（画面重摆后按一下）
//    key_clear  = 只清屏
//    自动触发  = 上电 3 秒学背景；目标消失 1.5s 自动清屏
//=============================================================================
`timescale 1ns / 1ps

module top_air_canvas(
    input  wire        sys_clk,       // 板载 50MHz
    input  wire        sys_rst_n,

    // ---- 摄像头（OV5640 DVP）----
    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_data,
    output wire        cam_rst_n,
    output wire        cam_pwdn,
    output wire        cam_scl,
    inout  wire        cam_sda,

    // ---- LCD（RGB 800x480, lcd_id=0x7084）----
    output wire        lcd_bl,
    output wire        lcd_clk,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire        lcd_de,
    output wire        lcd_rst,
    output wire [23:0] lcd_rgb,

    // ---- 按键（低有效）----
    input  wire        key_learn,     // 学背景 + 清屏
    input  wire        key_clear      // 清屏
);

    //-------------------------------------------------------------
    // 参数
    //-------------------------------------------------------------
    parameter CMOS_W = 640, CMOS_H = 480;
    parameter DS_W = 320,  DS_H = 240;
    parameter LCD_ID = 16'h7084;

    wire rst_n = sys_rst_n;

    //-------------------------------------------------------------
    // i2c 配置摄像头（50MHz 域）
    //-------------------------------------------------------------
    wire        i2c_dri_clk;
    wire        i2c_done;
    wire [7:0]  i2c_data_r;
    wire        i2c_exec;
    wire [23:0] i2c_data;
    wire        i2c_rh_wl;
    wire        cam_init_done;

    i2c_ov5640_rgb565_cfg u_i2c_cfg(
        .clk           (sys_clk),
        .rst_n         (rst_n),
        .i2c_done      (i2c_done),
        .i2c_data_r    (i2c_data_r),
        .cmos_h_pixel  (CMOS_W),
        .cmos_v_pixel  (CMOS_H),
        .total_h_pixel (CMOS_W + 1216),
        .total_v_pixel (CMOS_H + 504),
        .i2c_exec      (i2c_exec),
        .i2c_data      (i2c_data),
        .i2c_rh_wl     (i2c_rh_wl),
        .init_done     (cam_init_done)
    );

    i2c_dri #(
        .SLAVE_ADDR (7'h3c),
        .CLK_FREQ   (27'd50_000_000),
        .I2C_FREQ   (20'd250_000)
    ) u_i2c_dri(
        .clk        (sys_clk),
        .rst_n      (rst_n),
        .i2c_exec   (i2c_exec),
        .bit_ctrl   (1'b1),
        .i2c_rh_wl  (i2c_rh_wl),
        .i2c_addr   (i2c_data[23:8]),
        .i2c_data_w (i2c_data[7:0]),
        .i2c_data_r (i2c_data_r),
        .i2c_done   (i2c_done),
        .i2c_ack    (),
        .scl        (cam_scl),
        .sda        (cam_sda),
        .dri_clk    (i2c_dri_clk)
    );

    assign cam_pwdn = 1'b0;
    assign cam_rst_n = 1'b1;

    //-------------------------------------------------------------
    // 上电延时（cam_init 完成后再等 3s）
    //-------------------------------------------------------------
    reg [27:0] boot_cnt;
    reg        boot_done;
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin boot_cnt <= 0; boot_done <= 1'b0; end
        else if (!boot_done && cam_init_done) begin
            boot_cnt <= boot_cnt + 1;
            if (boot_cnt >= 28'd150_000_000)  // 3s @50MHz
                boot_done <= 1'b1;
        end
    end

    //-------------------------------------------------------------
    // 学习/清屏请求（sys 域电平标志，cam 域取上升沿）
    //-------------------------------------------------------------
    reg key_learn_d1, key_clear_d1, boot_done_d1;
    reg learn_req, clear_req;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            key_learn_d1 <= 1'b0; key_clear_d1 <= 1'b0; boot_done_d1 <= 1'b0;
            learn_req <= 1'b0; clear_req <= 1'b0;
        end else begin
            key_learn_d1 <= key_learn;
            key_clear_d1 <= key_clear;
            boot_done_d1 <= boot_done;
            if (boot_done_d1 == 1'b0 && boot_done == 1'b1) learn_req <= 1'b1;  // 上电自学
            if (key_learn_d1 == 1'b0 && key_learn == 1'b1) learn_req <= 1'b1;   // 松手沿
            if (key_clear_d1 == 1'b0 && key_clear == 1'b1) clear_req <= 1'b1;
        end
    end

    reg learn_s1, learn_s2, clear_s1, clear_s2;
    always @(posedge cam_pclk or negedge rst_n) begin
        if (!rst_n) begin learn_s1<=0; learn_s2<=0; clear_s1<=0; clear_s2<=0; end
        else begin
            learn_s1 <= learn_req; learn_s2 <= learn_s1;
            clear_s1 <= clear_req; clear_s2 <= clear_s1;
        end
    end
    wire learn_pulse_cam = learn_s1 & ~learn_s2;
    wire clear_pulse_cam = clear_s1 & ~clear_s2;

    //-------------------------------------------------------------
    // 摄像头采集 + 下采样（cam 域）
    //-------------------------------------------------------------
    wire [15:0] ds_data;
    wire        ds_valid;
    wire [15:0] fr_data;
    wire [14:0] fr_addr;
    wire        fr_we;

    cam_capture_ds #(
        .CMOS_W(CMOS_W), .CMOS_H(CMOS_H),
        .DS_W(DS_W), .DS_H(DS_H)
    ) u_cap (
        .cam_pclk(cam_pclk), .rst_n(rst_n),
        .cam_vsync(cam_vsync), .cam_href(cam_href), .cam_data(cam_data),
        .fr_data(fr_data), .fr_addr(fr_addr), .fr_we(fr_we),
        .ds_data(ds_data), .ds_valid(ds_valid)
    );

    //-------------------------------------------------------------
    // 帧缓冲 320x240x16b TDP（cam 写 / lcd 读）
    //-------------------------------------------------------------
    (* ram_style = "block" *)
    reg [15:0] frame_buf [0 : DS_W*DS_H-1];

    always @(posedge cam_pclk) begin
        if (fr_we) frame_buf[fr_addr] <= fr_data;
    end

    //-------------------------------------------------------------
    // LCD 25MHz 时钟（clk_div 从 50M 二分频）
    //-------------------------------------------------------------
    wire lcd_pclk;
    clk_div u_clk_div(.clk(sys_clk), .rst_n(rst_n),
                       .lcd_id(LCD_ID), .lcd_pclk(lcd_pclk));

    //-------------------------------------------------------------
    // tracker（cam 域）
    //-------------------------------------------------------------
    wire        tr_pen;
    wire [10:0] tr_pen_x, tr_pen_y;
    wire        tr_clear;

    tracker_pl #(
        .TRK_W(DS_W), .TRK_H(DS_H)
    ) u_tracker (
        .clk(cam_pclk), .rst_n(rst_n),
        .in_valid(ds_valid), .in_data(ds_data),
        .learn(learn_pulse_cam),
        .pen(tr_pen), .pen_x(tr_pen_x), .pen_y(tr_pen_y),
        .clear(tr_clear)
    );

    //-------------------------------------------------------------
    // video_out 读请求（lcd 域）
    //-------------------------------------------------------------
    wire        frame_ren, canvas_ren;
    wire [16:0] frame_raddr, canvas_raddr;

    //-------------------------------------------------------------
    // canvas（cam 写 / lcd 读）
    //-------------------------------------------------------------
    wire [7:0]  canvas_q_r;

    canvas_pl #(
        .C_W(DS_W), .C_H(DS_H)
    ) u_canvas (
        .wclk(cam_pclk), .w_rstn(rst_n),
        .pen(tr_pen), .pen_x(tr_pen_x), .pen_y(tr_pen_y),
        .clear(clear_pulse_cam | tr_clear),
        .rclk(lcd_pclk), .r_en(canvas_ren), .r_addr(canvas_raddr),
        .r_q(canvas_q_r)
    );

    wire [7:0] canvas_q = canvas_q_r;

    // 帧缓冲读口（lcd 域，一拍延时）
    reg [15:0] frame_q_r;
    always @(posedge lcd_pclk) begin
        if (frame_ren) frame_q_r <= frame_buf[frame_raddr];
    end
    wire [15:0] frame_q = frame_q_r;

    //-------------------------------------------------------------
    // lcd_driver + video_out
    //-------------------------------------------------------------
    wire [23:0] pixel_data;
    wire        data_req;
    wire [10:0] xpos, ypos;

    lcd_driver u_lcd (
        .lcd_pclk(lcd_pclk), .rst_n(rst_n), .lcd_id(LCD_ID),
        .pixel_data(pixel_data),
        .pixel_xpos(xpos), .pixel_ypos(ypos),
        .h_disp(), .v_disp(),
        .data_req(data_req),
        .lcd_de(lcd_de), .lcd_hs(lcd_hs), .lcd_vs(lcd_vs),
        .lcd_bl(lcd_bl), .lcd_clk(lcd_clk), .lcd_rst(lcd_rst),
        .lcd_rgb(lcd_rgb)
    );

    video_out #(
        .SRC_W(DS_W), .SRC_H(DS_H), .LCD_W(800), .LCD_H(480)
    ) u_vout (
        .lcd_pclk(lcd_pclk), .rst_n(rst_n),
        .xpos(xpos), .ypos(ypos), .disp_en(data_req),
        .frame_raddr(frame_raddr), .frame_ren(frame_ren), .frame_q(frame_q),
        .canvas_raddr(canvas_raddr), .canvas_ren(canvas_ren), .canvas_q(canvas_q),
        .pixel_data(pixel_data)
    );

endmodule
