//=============================================================================
// tb_color_tracker.v - color_tracker 自校验 testbench
//---------------------------------------------------------------------------
// 合成 64x32 视频流：固定背景图案 + 一个按帧移动的 3x3 白点。
// 流程：学习背景 -> 连发 10 帧 -> 每帧比对 IP 输出的质心与真实位置。
// 预期输出：10 行 [PASS]，最后一行 ALL TESTS PASSED。
// 不依赖板子，Vivado xsim / ModelSim / iverilog 都能跑。
//=============================================================================
`timescale 1ns / 1ps

module tb_color_tracker;

  localparam integer WIDTH  = 64;
  localparam integer HEIGHT = 32;

  //===== 时钟与复位 ===========================================================
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  always #5 clk = ~clk;

  //===== DUT 信号 =============================================================
  // 视频流
  reg  [23:0] s_data = 24'd0;
  reg         s_valid = 1'b0, s_user = 1'b0, s_last = 1'b0;
  wire        s_ready;
  wire [23:0] m_data;
  wire        m_valid, m_user, m_last;
  reg         m_ready = 1'b1;
  // AXI4-Lite
  reg         awvalid = 1'b0; wire awready;
  reg  [7:0]  awaddr  = 8'd0;
  reg         wvalid  = 1'b0; wire wready;
  reg  [31:0] wdata   = 32'd0;
  wire        bvalid; reg bready = 1'b0;
  reg         arvalid = 1'b0; wire arready;
  reg  [7:0]  araddr  = 8'd0;
  wire        rvalid; reg rready = 1'b0;
  wire [31:0] rdata;

  //===== DUT ==================================================================
  color_tracker #(.WIDTH(WIDTH), .HEIGHT(HEIGHT)) dut (
    .s_axis_clk(clk), .s_axis_rst_n(rst_n),
    .s_axis_tdata(s_data), .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
    .s_axis_tuser(s_user),  .s_axis_tlast(s_last),
    .m_axis_tdata(m_data), .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
    .m_axis_tuser(m_user),  .m_axis_tlast(m_last),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata),   .s_axi_wvalid(wvalid),   .s_axi_wready(wready),
    .s_axi_bvalid(bvalid), .s_axi_bready(bready),    .s_axi_bresp(),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata),   .s_axi_rvalid(rvalid),   .s_axi_rready(rready),
    .s_axi_rresp()
  );

  //===== 背景图案 =============================================================
  function [7:0] bg_pixel(input [15:0] x, input [15:0] y);
    begin
      bg_pixel = 8'd40 + ((x*3 + y*5) % 32);   // 40..71，稳定不复位帧变化
    end
  endfunction

  //===== 目标位置 =============================================================
  integer target_x = 8;
  integer target_y = 5;

  //===== AXI 写 ===============================================================
  task axi_write(input [7:0] addr, input [31:0] data);
    begin
      @(posedge clk);
      awvalid <= 1'b1; awaddr <= addr;
      wvalid  <= 1'b1; wdata  <= data;
      @(posedge clk);
      while (!(awready && wready)) @(posedge clk);
      awvalid <= 1'b0; wvalid <= 1'b0;
      bready  <= 1'b1;
      @(posedge clk);
      while (!bvalid) @(posedge clk);
      bready <= 1'b0;
    end
  endtask

  //===== AXI 读 ===============================================================
  task axi_read(input [7:0] addr, output [31:0] data);
    begin
      @(posedge clk);
      arvalid <= 1'b1; araddr <= addr;
      @(posedge clk);
      while (!arready) @(posedge clk);
      arvalid <= 1'b0;
      rready  <= 1'b1;
      @(posedge clk);
      while (!rvalid) @(posedge clk);
      data  = rdata;
      rready <= 1'b0;
    end
  endtask

  //===== 推一个像素（等 ready）================================================
  task push_cycle(input [23:0] rgb, input u, input l);
    begin
      @(posedge clk);
      s_valid <= 1'b1; s_data <= rgb; s_user <= u; s_last <= l;
      @(posedge clk);
      while (!s_ready) @(posedge clk);
      s_valid <= 1'b0;
    end
  endtask

  //===== 发一整帧 =============================================================
  task send_frame(input want_target);
    integer xi, yi;
    reg [7:0] px;
    begin
      for (yi = 0; yi < HEIGHT; yi = yi + 1) begin
        for (xi = 0; xi < WIDTH; xi = xi + 1) begin
          px = bg_pixel(xi[15:0], yi[15:0]);
          if (want_target && xi >= target_x-1 && xi <= target_x+1
                          && yi >= target_y-1 && yi <= target_y+1)
            px = 8'hFF;
          push_cycle({px, px, px}, (xi == 0 && yi == 0), (xi == WIDTH-1));
        end
      end
      repeat (4) @(posedge clk);   // 帧间间隙
    end
  endtask

  //===== 单帧校验 =============================================================
  integer errors = 0;
  task check_pos(input integer exp_x, input integer exp_y, input integer idx);
    integer gx, gy, got;
    begin
      repeat (100) @(posedge clk);   // 等除法器算完
      axi_read(8'h08, got); gx = got[15:0];
      axi_read(8'h0C, got); gy = got[15:0];
      if (gx >= exp_x-1 && gx <= exp_x+1 && gy >= exp_y-1 && gy <= exp_y+1)
        $display("[PASS] frame %0d: cx=%0d cy=%0d (expect %0d,%0d)",
                 idx, gx, gy, exp_x, exp_y);
      else begin
        $display("[FAIL] frame %0d: cx=%0d cy=%0d (expect %0d,%0d)",
                 idx, gx, gy, exp_x, exp_y);
        errors = errors + 1;
      end
    end
  endtask

  //===== 主流程 ===============================================================
  integer k;
  integer got;
  initial begin
    rst_n = 1'b0;
    repeat (12) @(posedge clk);
    rst_n <= 1'b1;
    repeat (4)  @(posedge clk);

    // 1) 写 CTRL：enable=1, learn=1, thr=64
    axi_write(8'h00, 32'h0000_4003);

    // 2) 发一帧纯背景，帧末 bg_locked 置起
    send_frame(1'b0);

    // 3) 确认背景已学习
    axi_read(8'h04, got);
    if (got[0] === 1'b1)
      $display("[PASS] bg_locked after learning frame");
    else begin
      $display("[FAIL] bg_locked not set");
      errors = errors + 1;
    end

    // 4) 连发 10 帧带移动白点，逐帧校验质心
    for (k = 0; k < 10; k = k + 1) begin
      target_x = 8 + 4*k;
      target_y = 5 + 2*k;
      send_frame(1'b1);
      check_pos(target_x, target_y, k);
    end

    // 5) 汇总
    if (errors == 0) $display("ALL TESTS PASSED");
    else             $display("TESTS FAILED: %0d error(s)", errors);
    $finish;
  end

  // 超时保护
  initial begin
    #50000000;
    $display("SIM TIMEOUT");
    $finish;
  end

endmodule
