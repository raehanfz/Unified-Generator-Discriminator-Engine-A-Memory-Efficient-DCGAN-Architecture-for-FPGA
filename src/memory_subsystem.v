/*
 * Memory Subsystem (Updated)
 * 
 * Components:
 *   - pingpong_ram: Double-buffered feature map storage
 *   - ram_to_stream: Sequential read → AXI-Stream
 *   - stream_to_ram: AXI-Stream → Sequential write
 *   - output_framebuffer: Final image storage
 *   - bank_controller: Bank switching FSM
 */

`timescale 1ns / 1ps

`include "pingpong_ram.v"
`include "ram_to_stream.v"
`include "stream_to_ram.v"
`include "output_framebuffer.v"
`include "bank_controller.v"

module memory_subsystem #(
    parameter DATA_WIDTH    = 16,
    parameter FEATURE_DEPTH = 2048,
    parameter OUTPUT_DEPTH  = 1024
)(
    input  wire clk,
    input  wire rst_n,
    
    // =========================================================================
    // RAM-TO-STREAM INTERFACE (Read feature maps)
    // =========================================================================
    input  wire [11:0] r2s_start_addr,
    input  wire [11:0] r2s_length,
    input  wire [11:0] r2s_row_length,   // Row length for vertical repeat
    input  wire        r2s_row_repeat,   // Enable vertical repeat (2×)
    input  wire        r2s_from_fb,      // Read from framebuffer instead of RAM
    input  wire        r2s_start,
    output wire        r2s_busy,
    output wire        r2s_done,
    output wire signed [DATA_WIDTH-1:0] r2s_data,
    output wire        r2s_valid,
    input  wire        r2s_ready,
    
    // =========================================================================
    // STREAM-TO-RAM INTERFACE (Write feature maps)
    // =========================================================================
    input  wire [10:0] s2r_start_addr,
    input  wire [10:0] s2r_length,
    input  wire        s2r_start,
    output wire        s2r_busy,
    output wire        s2r_done,
    input  wire signed [DATA_WIDTH-1:0] s2r_data,
    input  wire        s2r_valid,
    output wire        s2r_ready,
    
    // =========================================================================
    // OUTPUT FRAMEBUFFER INTERFACE
    // =========================================================================
    input  wire [11:0] fb_wr_addr,
    input  wire [DATA_WIDTH-1:0] fb_wr_data,
    input  wire        fb_wr_en,
    input  wire [11:0] fb_rd_addr,
    output wire [DATA_WIDTH-1:0] fb_rd_data,
    input  wire        frame_start,
    output wire        frame_ready,
    
    // =========================================================================
    // BANK CONTROLLER INTERFACE
    // =========================================================================
    input  wire [2:0]  current_layer,
    input  wire        layer_start,
    input  wire        layer_done,
    output wire        active_bank,
    output wire        bank_switch_ready,
    output wire        bank_switched,
    
    // =========================================================================
    // STATUS
    // =========================================================================
    output wire [1:0]  pingpong_status
);

    // =========================================================================
    // INTERNAL SIGNALS
    // =========================================================================
    
    // Pingpong RAM internal connections
    wire [10:0] pp_rd_addr;
    wire [DATA_WIDTH-1:0] pp_rd_data;
    wire [10:0] pp_wr_addr;
    wire [DATA_WIDTH-1:0] pp_wr_data;
    wire pp_wr_en;
    
    // Bank controller output
    wire active_bank_internal;
    
    // Framebuffer read for discriminator
    wire [11:0] fb_stream_rd_addr;
    wire [DATA_WIDTH-1:0] fb_stream_rd_data;
    
    // Muxed read data (select between pingpong and framebuffer)
    wire [DATA_WIDTH-1:0] muxed_rd_data;
    assign muxed_rd_data = r2s_from_fb ? fb_stream_rd_data : pp_rd_data;

    // =========================================================================
    // PINGPONG RAM
    // =========================================================================
    pingpong_ram #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(FEATURE_DEPTH),
        .ADDR_WIDTH(11)
    ) u_pingpong_ram (
        .clk(clk),
        .rst_n(rst_n),
        .active_bank(active_bank_internal),
        .wr_addr(pp_wr_addr),
        .wr_data(pp_wr_data),
        .wr_en(pp_wr_en),
        .rd_addr(pp_rd_addr),
        .rd_data(pp_rd_data),
        .bank_status(pingpong_status)
    );

    // =========================================================================
    // RAM TO STREAM (Read from pingpong RAM or framebuffer)
    // =========================================================================
    wire [11:0] r2s_rd_addr_wide;  // 12-bit for framebuffer
    
    ram_to_stream #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(12)  // Wider for framebuffer (3072 entries)
    ) u_ram_to_stream (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_start_addr(r2s_start_addr),
        .cfg_length(r2s_length),
        .cfg_row_length(r2s_row_length),
        .cfg_row_repeat(r2s_row_repeat),
        .start(r2s_start),
        .busy(r2s_busy),
        .done(r2s_done),
        .ram_rd_addr(r2s_rd_addr_wide),
        .ram_rd_data(muxed_rd_data),
        .m_axis_tdata(r2s_data),
        .m_axis_tvalid(r2s_valid),
        .m_axis_tready(r2s_ready)
    );
    
    // Connect addresses to appropriate memories
    assign pp_rd_addr = r2s_rd_addr_wide[10:0];
    assign fb_stream_rd_addr = r2s_rd_addr_wide;

    // =========================================================================
    // STREAM TO RAM (Write to pingpong RAM)
    // =========================================================================
    stream_to_ram #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(11)
    ) u_stream_to_ram (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_start_addr(s2r_start_addr),
        .cfg_length(s2r_length),
        .start(s2r_start),
        .busy(s2r_busy),
        .done(s2r_done),
        .s_axis_tdata(s2r_data),
        .s_axis_tvalid(s2r_valid),
        .s_axis_tready(s2r_ready),
        .ram_wr_addr(pp_wr_addr),
        .ram_wr_data(pp_wr_data),
        .ram_wr_en(pp_wr_en)
    );

    // =========================================================================
    // OUTPUT FRAMEBUFFER (for discriminator input)
    // =========================================================================
    output_framebuffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .IMG_SIZE(32),
        .CHANNELS(3),
        .DEPTH(3072),       // 32×32×3 RGB
        .ADDR_WIDTH(12)
    ) u_output_framebuffer (
        .clk(clk),
        .rst_n(rst_n),
        .wr_addr(fb_wr_addr[11:0]),
        .wr_data(fb_wr_data),
        .wr_en(fb_wr_en),
        .rd_addr(r2s_from_fb ? fb_stream_rd_addr : fb_rd_addr),
        .rd_data(fb_stream_rd_data),
        .frame_start(frame_start),
        .frame_ready(frame_ready)
    );
    
    // External read data comes from framebuffer
    assign fb_rd_data = fb_stream_rd_data;

    // =========================================================================
    // BANK CONTROLLER
    // =========================================================================
    bank_controller #(
        .NUM_LAYERS(4)
    ) u_bank_controller (
        .clk(clk),
        .rst_n(rst_n),
        .current_layer(current_layer),
        .layer_start(layer_start),
        .layer_done(layer_done),
        .active_bank(active_bank_internal),
        .bank_switch_ready(bank_switch_ready),
        .bank_switched(bank_switched),
        .layer_sequence()
    );

    assign active_bank = active_bank_internal;

endmodule