//=============================================================================
// color_tracker.v - 空中画板核心 IP
//---------------------------------------------------------------------------
// 功能：AXI4-Stream 24bit RGB 视频流透传，并行做
//   1) 背景学习（一键冻结当前帧为背景）
//   2) 逐像素灰度差分，得到目标掩码
//   3) 硬件质心计算 (cx, cy) 与目标面积，经 AXI4-Lite 报告给 PS(ARM)
//
// 用法：插在摄像头采集 IP 与 VDMA 之间。视频流原样穿过，坐标旁路输出。
// 分辨率由参数 WIDTH/HEIGHT 决定（需与送进来的流一致）。
//=============================================================================
`timescale 1ns / 1ps

//-----------------------------------------------------------------------------
// 无符号除法器（恢复余数，W 拍迭代，单文件零 IP 依赖）
//-----------------------------------------------------------------------------
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
  reg  [W-1:0] a_q;
  reg  [W-1:0] rem;
  reg  [W-1:0] b;
  reg  [4:0]  cnt;      // 支持 W<=32
  reg          busy;

  wire [W-1:0] shifted = {rem[W-2:0], a_q[W-1]};
  wire [W:0]   sub     = {1'b0, shifted} - {1'b0, b};
  wire         ge      = ~sub[W];      // shifted >= b ?

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; done <= 1'b0; quo <= {W{1'b0}};
    end else if (!busy) begin
      done <= 1'b0;
      if (start) begin
        a_q <= num; rem <= {W{1'b0}}; b <= den;
        cnt <= W-1; busy <= 1'b1;
      end
    end else begin
      rem    <= ge ? sub[W-1:0] : shifted;
      a_q    <= {a_q[W-2:0], 1'b0};
      quo[cnt] <= ge;
      if (cnt == 5'd0) begin busy <= 1'b0; done <= 1'b1; end
      else cnt <= cnt - 5'd1;
    end
  end
endmodule

//-----------------------------------------------------------------------------
// 主 IP
//-----------------------------------------------------------------------------
module color_tracker #(
  parameter integer WIDTH  = 320,
  parameter integer HEIGHT = 240
)(
  //---- 视频流（AXI4-Stream，24bit RGB）--------------------------------------
  input  wire        s_axis_clk,
  input  wire        s_axis_rst_n,
  input  wire [23:0] s_axis_tdata,
  input  wire        s_axis_tvalid,
  output wire        s_axis_tready,
  input  wire        s_axis_tuser,     // 帧起始 SOF
  input  wire        s_axis_tlast,     // 行结束 EOL
  output wire [23:0] m_axis_tdata,
  output wire        m_axis_tvalid,
  input  wire        m_axis_tready,
  output wire        m_axis_tuser,
  output wire        m_axis_tlast,

  //---- AXI4-Lite 从接口 ------------------------------------------------------
  input  wire [7:0]  s_axi_awaddr,
  input  wire        s_axi_awvalid,
  output wire        s_axi_awready,
  input  wire [31:0] s_axi_wdata,
  input  wire        s_axi_wvalid,
  output wire        s_axi_wready,
  output wire [1:0]  s_axi_bresp,
  output wire        s_axi_bvalid,
  input  wire        s_axi_bready,
  input  wire [7:0]  s_axi_araddr,
  input  wire        s_axi_arvalid,
  output wire        s_axi_arready,
  output wire [31:0] s_axi_rdata,
  output wire [1:0]  s_axi_rresp,
  output wire        s_axi_rvalid,
  input  wire        s_axi_rready
);

  //================== 寄存器定义 ==============================================
  localparam [7:0] A_CTRL    = 8'h00; // [0]enable [1]learn(自清) [15:8]thr
  localparam [7:0] A_STAT    = 8'h04; // [0]bg_locked [1]target_valid
  localparam [7:0] A_X       = 8'h08; // 质心 X
  localparam [7:0] A_Y       = 8'h0C; // 质心 Y
  localparam [7:0] A_AREA    = 8'h10; // 目标像素数
  localparam [7:0] A_FRAME   = 8'h14; // 帧计数
  localparam [7:0] A_MINAREA = 8'h18; // 有效目标最小面积

  reg [31:0] r_ctrl, r_stat;
  reg [15:0] r_x, r_y, r_area, r_fcnt, r_minarea;
  reg        learn_req;
  reg        s_axi_wr_ctrl_learn;   // AXI 写 CTRL[1] 的单拍脉冲

  wire       en        = r_ctrl[0];
  wire [7:0] diff_thr  = r_ctrl[15:8];

  //================== 视频透传 + 一级输出寄存（支持反压）====================
  reg        out_valid;
  reg [23:0] out_data;
  reg        out_user, out_last;

  assign m_axis_tvalid = out_valid;
  assign m_axis_tdata  = out_data;
  assign m_axis_tuser  = out_user;
  assign m_axis_tlast  = out_last;
  assign s_axis_tready = m_axis_tready || !out_valid;

  always @(posedge s_axis_clk) begin
    if (!s_axis_rst_n) out_valid <= 1'b0;
    else if (s_axis_tready) begin
      out_valid <= s_axis_tvalid;
      out_data  <= s_axis_tdata;
      out_user  <= s_axis_tuser;
      out_last  <= s_axis_tlast;
    end
  end

  //================== 像素坐标计数（当前级）===================================
  reg [15:0] x_cnt, y_cnt;
  wire in_fire = s_axis_tvalid && s_axis_tready;

  always @(posedge s_axis_clk) begin
    if (!s_axis_rst_n) begin x_cnt <= 16'd0; y_cnt <= 16'd0; end
    else if (in_fire) begin
      if (s_axis_tuser)            begin x_cnt <= 16'd1; y_cnt <= 16'd0; end
      else if (s_axis_tlast)       begin x_cnt <= 16'd0; y_cnt <= y_cnt + 16'd1; end
      else                         begin x_cnt <= x_cnt + 16'd1; end
    end
  end

  //================== 灰度 + 一级像素延迟（与 bg_q 对齐）=====================
  wire [17:0] luma_sum = s_axis_tdata[23:16] * 18'd76
                       + s_axis_tdata[15:8] * 18'd150
                       + s_axis_tdata[7:0]  * 18'd29;
  wire [7:0] gray = luma_sum[17:8];

  reg [15:0] x_d, y_d;
  reg [7:0]  gray_d;
  reg        user_d, last_d, in_fire_d;

  always @(posedge s_axis_clk) begin
    if (!s_axis_rst_n) begin
      in_fire_d <= 1'b0; user_d <= 1'b0; last_d <= 1'b0;
    end else if (in_fire) begin
      in_fire_d <= 1'b1;
      user_d    <= s_axis_tuser;
      last_d    <= s_axis_tlast;
      x_d       <= x_cnt;
      y_d       <= y_cnt;
      gray_d    <= gray;
    end else begin
      in_fire_d <= 1'b0;
    end
  end

  //================== 背景帧存储（BRAM，read-first）==========================
  reg  [7:0]  bg_mem [0 : WIDTH*HEIGHT-1];
  reg  [7:0]  bg_q;
  wire [31:0] bg_rd_addr = y_cnt * WIDTH + x_cnt;

  // 背景学习状态机：写 CTRL[1] -> 等下一个 SOF -> 学完整一帧 -> bg_locked
  reg learning, learn_armed, bg_locked;
  wire frame_start = in_fire && s_axis_tuser;
  wire frame_end   = in_fire && s_axis_tlast && (x_cnt == WIDTH-1)
                                              && (y_cnt == HEIGHT-1);

  always @(posedge s_axis_clk) begin
    if (!s_axis_rst_n) begin
      learn_req <= 1'b0; learn_armed <= 1'b0; learning <= 1'b0; bg_locked <= 1'b0;
    end else begin
      if (s_axi_wr_ctrl_learn) learn_req <= 1'b1;      // AXI 写 CTRL[1]
      if (learn_req && frame_start) begin learn_armed <= 1'b1; learning <= 1'b1; end
      if (learn_armed && frame_end) begin
        learn_req <= 1'b0; learn_armed <= 1'b0; learning <= 1'b0; bg_locked <= 1'b1;
      end
    end
  end

  always @(posedge s_axis_clk) begin
    if (in_fire) begin
      bg_q <= bg_mem[bg_rd_addr];
      if (learning) bg_mem[bg_rd_addr] <= gray;
    end
  end

  //================== 差分掩码 =================================================
  wire [8:0] diff = (gray_d >= bg_q) ? ({1'b0, gray_d} - {1'b0, bg_q})
                                     : ({1'b0, bg_q} - {1'b0, gray_d});
  wire hit = bg_locked && !learning && en && (diff > {1'b0, diff_thr});

  //================== 质心累加 =================================================
  reg [31:0] row_x, row_a;         // 行内累加
  reg [31:0] acc_x, acc_y, acc_a;  // 全帧累加
  reg [31:0] snap_x, snap_y, snap_a;// 帧末锁存（送除法器）

  wire [31:0] row_x_next = row_x + ((hit && in_fire_d) ? {16'd0, x_d} : 32'd0);
  wire [31:0] row_a_next = row_a + ((hit && in_fire_d) ? 32'd1        : 32'd0);
  wire        eol_d      = in_fire_d && last_d && bg_locked;

  always @(posedge s_axis_clk) begin
    if (!s_axis_rst_n) begin
      row_x<=0; row_a<=0; acc_x<=0; acc_y<=0; acc_a<=0;
    end else if (eol_d) begin
      acc_x <= acc_x + row_x_next;
      acc_y <= acc_y + y_d * row_a_next;
      acc_a <= acc_a + row_a_next;
      if (y_d == HEIGHT-1) begin
        snap_x <= acc_x + row_x_next;
        snap_y <= acc_y + y_d * row_a_next;
        snap_a <= acc_a + row_a_next;
        r_fcnt <= r_fcnt + 16'd1;
      end
      row_x <= 32'd0; row_a <= 32'd0;
    end else if (in_fire_d) begin
      if (!bg_locked || user_d) begin      // 未锁背景 / 帧首 -> 清零
        row_x<=0; row_a<=0; acc_x<=0; acc_y<=0; acc_a<=0;
      end else begin
        row_x <= row_x_next;
        row_a <= row_a_next;
      end
    end
  end

  //================== 除法：质心 ===============================================
  reg div_start;
  wire frame_end_d = in_fire_d && last_d && (x_d == WIDTH-1) && (y_d == HEIGHT-1);
  always @(posedge s_axis_clk) div_start <= frame_end_d;

  wire [23:0] q_x, q_y;
  wire        d_x, d_y;

  uint_div #(.W(24)) div_x (
    .clk(s_axis_clk), .rst_n(s_axis_rst_n), .start(div_start),
    .num(snap_x[23:0]), .den(snap_a[23:0]), .quo(q_x), .done(d_x));
  uint_div #(.W(24)) div_y (
    .clk(s_axis_clk), .rst_n(s_axis_rst_n), .start(div_start),
    .num(snap_y[23:0]), .den(snap_a[23:0]), .quo(q_y), .done(d_y));

  reg target_valid;
  always @(posedge s_axis_clk) begin
    if (!s_axis_rst_n) begin r_x<=0; r_y<=0; r_area<=0; target_valid<=0; end
    else if (d_x) begin
      r_x <= q_x[15:0]; r_y <= q_y[15:0]; r_area <= snap_a[15:0];
      target_valid <= bg_locked && (snap_a >= {16'd0, r_minarea});
    end
  end

  //================== AXI4-Lite：写 ============================================
  reg awready_r, wready_r, bvalid_r;

  assign s_axi_awready = awready_r;
  assign s_axi_wready  = wready_r;
  assign s_axi_bvalid  = bvalid_r;
  assign s_axi_bresp   = 2'b00;

  always @(posedge s_axis_clk) begin
    if (!s_axis_rst_n) begin
      awready_r<=0; wready_r<=0; bvalid_r<=0; s_axi_wr_ctrl_learn<=0;
      r_ctrl<=0; r_stat<=0; r_minarea<=16'd9; learn_req<=0;
    end else begin
      s_axi_wr_ctrl_learn <= 1'b0;
      if (bvalid_r && s_axi_bready) bvalid_r <= 1'b0;
      if (!awready_r && s_axi_awvalid) awready_r <= 1'b1;
      if (!wready_r  && s_axi_wvalid)  wready_r  <= 1'b1;
      if (awready_r && s_axi_awvalid && wready_r && s_axi_wvalid) begin
        case (s_axi_awaddr[5:2])
          4'h0: begin r_ctrl <= s_axi_wdata;
                      if (s_axi_wdata[1]) s_axi_wr_ctrl_learn <= 1'b1; end
          4'h6: r_minarea <= s_axi_wdata[15:0];
          default: ;
        endcase
        bvalid_r  <= 1'b1;
        awready_r <= 1'b0;
        wready_r  <= 1'b0;
      end
    end
  end

  //================== AXI4-Lite：读 ============================================
  reg arready_r, rvalid_r;
  reg [31:0] rdata_r;

  assign s_axi_arready = arready_r;
  assign s_axi_rvalid  = rvalid_r;
  assign s_axi_rresp   = 2'b00;
  assign s_axi_rdata   = rdata_r;

  always @(posedge s_axis_clk) begin
    if (!s_axis_rst_n) begin
      arready_r<=0; rvalid_r<=0; rdata_r<=0;
    end else begin
      if (rvalid_r && s_axi_rready) rvalid_r <= 1'b0;
      if (!arready_r && s_axi_arvalid) begin
        arready_r <= 1'b1;
        case (s_axi_araddr[5:2])
          4'h0:    rdata_r <= r_ctrl;
          4'h1:    rdata_r <= {30'd0, target_valid, bg_locked};
          4'h2:    rdata_r <= {16'd0, r_x};
          4'h3:    rdata_r <= {16'd0, r_y};
          4'h4:    rdata_r <= {16'd0, r_area};
          4'h5:    rdata_r <= {16'd0, r_fcnt};
          4'h6:    rdata_r <= {16'd0, r_minarea};
          default: rdata_r <= 32'hDEADBEEF;
        endcase
      end else if (arready_r && s_axi_arvalid) begin
        rvalid_r  <= 1'b1;
        arready_r <= 1'b0;
      end
    end
  end

  wire _unused = &{1'b0, s_axi_rresp, s_axi_bresp, 1'b0};

endmodule
