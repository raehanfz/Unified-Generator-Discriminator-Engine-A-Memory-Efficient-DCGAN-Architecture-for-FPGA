/*
 * System Top Level
 * 
 * Purpose: DCGAN inference accelerator top-level integration
 * 
 * Data Flow:
 *   Noise → FC Handler → Input Mux ─┐
 *                                   ├→ Compute Engine → Output Mux → RAM/FB
 *   Weight ROM → Weight Streamer ───┘
 */

`timescale 1ns / 1ps

// Include modules
`include "noise_generator.v"
`include "weight_rom.v"
`include "weight_streamer_cached.v"
`include "fc_layer_handler.v"
`include "layer_config_rom.v"
`include "input_mux.v"
`include "upscaler_simple.v"
`include "patch_extractor.v"
`include "patch_replay_buffer.v"
`include "compute_engine.v"
`include "output_mux.v"
`include "memory_subsystem.v"
`include "system_controller.v"

module system_top_level #(
    parameter DATA_WIDTH = 16,
    parameter ARRAY_SIZE = 4
)(
    input  wire clk,
    input  wire rst_n,
    
    // =========================================================================
    // EXTERNAL CONTROL
    // =========================================================================
    input  wire start_generator,
    input  wire start_discriminator,
    input  wire [DATA_WIDTH-1:0] seed_value,
    input  wire seed_load,
    
    // =========================================================================
    // STATUS
    // =========================================================================
    output wire busy,
    output wire inference_done,
    output wire [3:0] current_layer,
    output wire [4:0] controller_state,
    
    // =========================================================================
    // OUTPUT (from framebuffer - 32x32x3 = 3072 pixels)
    // =========================================================================
    input  wire [11:0] fb_rd_addr,           // 12-bit for 3072 entries
    output wire [DATA_WIDTH-1:0] fb_rd_data,
    output wire frame_ready,
    
    // =========================================================================
    // DISCRIMINATOR OUTPUT
    // =========================================================================
    output wire [DATA_WIDTH-1:0] disc_result,
    output wire disc_result_valid,
    
    // =========================================================================
    // DEBUG SIGNALS
    // =========================================================================
    output wire noise_valid,
    output wire fc_busy,
    output wire fc_done,
    output wire ws_stream_ready,
    output wire ws_group_done,
    output wire ws_bias_done,
    output wire pe_busy,
    output wire pe_done,
    output wire mem_active_bank,
    output wire engine_busy,
    output wire [31:0] engine_data_count,
    output wire [31:0] engine_output_count,
    output wire engine_sync_error
);

    // =========================================================================
    // INTERNAL WIRES
    // =========================================================================
    
    // Layer config ROM
    wire [14:0] cfg_weight_base;
    wire [14:0] cfg_bias_base;
    wire [15:0] cfg_num_weights;
    wire [5:0]  cfg_num_biases;
    wire [5:0]  cfg_in_channels;
    wire [5:0]  cfg_out_channels;
    wire [5:0]  cfg_in_size;
    wire [5:0]  cfg_out_size;
    wire [2:0]  cfg_kernel_size;
    wire [1:0]  cfg_stride;
    wire [1:0]  cfg_padding;
    wire [9:0]  cfg_acc_limit;
    wire        cfg_is_generator;
    wire        cfg_needs_upsample;
    wire        cfg_is_fc_layer;
    wire [1:0]  cfg_activation;
    wire [9:0]  cfg_fc_input_len;
    wire [9:0]  cfg_fc_output_len;
    
    // Controller outputs
    wire [3:0]  ctrl_layer_id;
    wire        ctrl_noise_enable;
    wire        ctrl_fc_start;
    wire [14:0] ctrl_ws_weight_base;
    wire [14:0] ctrl_ws_bias_base;
    wire [9:0]  ctrl_ws_out_channels;     // Widened for FC (512)
    wire [9:0]  ctrl_ws_num_biases;       // Actual bias count
    wire [9:0]  ctrl_ws_weights_per_filter;
    wire        ctrl_ws_start_bias;
    wire        ctrl_ws_start_cache;
    wire        ctrl_ws_start_stream;
    wire        ctrl_ws_stop_stream;
    wire        ctrl_ws_next_group;
    wire [5:0]  ctrl_pe_img_width;
    wire [5:0]  ctrl_pe_img_height;
    wire [5:0]  ctrl_pe_in_channels;
    wire [2:0]  ctrl_pe_kernel_size;
    wire [1:0]  ctrl_pe_stride;
    wire [1:0]  ctrl_pe_padding;
    wire        ctrl_pe_start;
    wire        ctrl_ups_bypass;
    wire [9:0]  ctrl_prb_patch_size;
    wire [7:0]  ctrl_prb_replay_count;
    wire [15:0] ctrl_prb_num_patches;
    wire        ctrl_prb_start;
    wire [11:0] ctrl_mem_r2s_start_addr;
    wire [11:0] ctrl_mem_r2s_length;
    wire [11:0] ctrl_mem_r2s_row_length;
    wire        ctrl_mem_r2s_row_repeat;
    wire        ctrl_mem_r2s_from_fb;
    wire        ctrl_mem_r2s_start;
    wire [10:0] ctrl_mem_s2r_start_addr;
    wire [10:0] ctrl_mem_s2r_length;
    wire        ctrl_mem_s2r_start;
    wire        ctrl_mem_layer_done;
    wire        ctrl_mem_layer_start;
    wire [1:0]  ctrl_input_mux_sel;
    wire [1:0]  ctrl_output_mux_sel;
    wire        ctrl_engine_mode_disc;
    wire [9:0]  ctrl_engine_acc_limit;
    wire [1:0]  ctrl_engine_activation;
    
    // Noise generator
    wire [DATA_WIDTH-1:0] noise_value;
    wire noise_valid_int;
    
    // FC layer handler
    wire fc_busy_int;
    wire fc_done_int;
    wire signed [DATA_WIDTH-1:0] fc_data_out;
    wire fc_valid_out;
    wire fc_ready_in;
    
    // Weight ROM
    wire [14:0] rom_addr;
    wire [DATA_WIDTH-1:0] rom_data;
    
    // Weight streamer
    wire ws_busy;
    wire ws_stream_ready_int;
    wire ws_group_done_int;
    wire ws_bias_done_int;
    wire ws_cache_done_int;
    wire signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] ws_weights_out;
    wire ws_weights_valid;
    wire signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] ws_bias_out;
    wire ws_bias_valid;
    
    // Patch extractor
    wire pe_busy_int;
    wire pe_done_int;
    wire signed [DATA_WIDTH-1:0] pe_pixel_out;
    wire pe_pixel_valid;
    wire pe_pixel_ready;
    
    // Upscaler
    wire signed [DATA_WIDTH-1:0] ups_data_out;
    wire ups_valid_out;
    wire ups_ready_in;
    
    // Patch replay buffer
    wire prb_busy;
    wire prb_done;
    wire prb_patch_done;
    wire signed [DATA_WIDTH-1:0] prb_data_out;
    wire prb_valid_out;
    wire prb_ready_in;
    
    // Input mux
    wire signed [DATA_WIDTH-1:0] mux_data_out;
    wire mux_valid_out;
    wire mux_ready_in;
    
    // Compute engine
    wire signed [DATA_WIDTH-1:0] engine_result_out;
    wire engine_result_valid;
    wire engine_result_ready;
    wire engine_busy_int;
    wire [31:0] engine_mac_count_int;
    wire [31:0] engine_output_count_int;
    
    // Output mux
    wire signed [DATA_WIDTH-1:0] omux_ram_data;
    wire omux_ram_valid;
    wire omux_ram_ready;
    wire signed [DATA_WIDTH-1:0] omux_fb_data;
    wire omux_fb_valid;
    wire omux_fb_ready;
    assign omux_fb_ready = 1'b1;  // Framebuffer always accepts
    
    // Framebuffer write address counter (for 32×32×3 = 3072 pixels)
    reg [11:0] fb_wr_addr_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fb_wr_addr_cnt <= 0;
        end else if (ctrl_output_mux_sel == 2'd1 && !busy) begin
            // Reset when starting G_L3 output
            fb_wr_addr_cnt <= 0;
        end else if (omux_fb_valid) begin
            fb_wr_addr_cnt <= fb_wr_addr_cnt + 1;
        end
    end
    
    // Memory subsystem
    wire mem_r2s_busy;
    wire mem_r2s_done;
    wire signed [DATA_WIDTH-1:0] mem_r2s_data;
    wire mem_r2s_valid;
    // mem_r2s_ready now comes from upscaler (ups_ready_in)
    wire mem_s2r_busy;
    wire mem_s2r_done;
    wire mem_s2r_ready;
    wire mem_active_bank_int;
    wire mem_bank_switch_ready;
    wire mem_frame_ready;

    // =========================================================================
    // DEBUG OUTPUT ASSIGNMENTS
    // =========================================================================
    assign noise_valid = noise_valid_int;
    assign fc_busy = fc_busy_int;
    assign fc_done = fc_done_int;
    assign ws_stream_ready = ws_stream_ready_int;
    assign ws_group_done = ws_group_done_int;
    assign ws_bias_done = ws_bias_done_int;
    assign pe_busy = pe_busy_int;
    assign pe_done = pe_done_int;
    assign mem_active_bank = mem_active_bank_int;
    assign frame_ready = mem_frame_ready;
    assign engine_busy = engine_busy_int;
    assign engine_data_count = engine_mac_count_int;
    assign engine_output_count = engine_output_count_int;
    assign engine_sync_error = 1'b0;  // Not used in real compute engine

    // =========================================================================
    // LAYER CONFIG ROM
    // =========================================================================
    layer_config_rom u_layer_config (
        .layer_id       (ctrl_layer_id),
        .weight_base    (cfg_weight_base),
        .bias_base      (cfg_bias_base),
        .num_weights    (cfg_num_weights),
        .num_biases     (cfg_num_biases),
        .in_channels    (cfg_in_channels),
        .out_channels   (cfg_out_channels),
        .in_size        (cfg_in_size),
        .out_size       (cfg_out_size),
        .kernel_size    (cfg_kernel_size),
        .stride         (cfg_stride),
        .padding        (cfg_padding),
        .acc_limit      (cfg_acc_limit),
        .is_generator   (cfg_is_generator),
        .needs_upsample (cfg_needs_upsample),
        .is_fc_layer    (cfg_is_fc_layer),
        .activation     (cfg_activation),
        .fc_input_len   (cfg_fc_input_len),
        .fc_output_len  (cfg_fc_output_len)
    );

    // =========================================================================
    // SYSTEM CONTROLLER
    // =========================================================================
    system_controller #(
        .DATA_WIDTH(DATA_WIDTH),
        .ARRAY_SIZE(ARRAY_SIZE)
    ) u_controller (
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        .start_generator        (start_generator),
        .start_discriminator    (start_discriminator),
        .busy                   (busy),
        .inference_done         (inference_done),
        .current_layer          (current_layer),
        .state_out              (controller_state),
        
        .layer_id               (ctrl_layer_id),
        .weight_base            (cfg_weight_base),
        .bias_base              (cfg_bias_base),
        .num_weights            (cfg_num_weights),
        .num_biases             (cfg_num_biases),
        .in_channels            (cfg_in_channels),
        .out_channels           (cfg_out_channels),
        .in_size                (cfg_in_size),
        .out_size               (cfg_out_size),
        .kernel_size            (cfg_kernel_size),
        .stride                 (cfg_stride),
        .padding                (cfg_padding),
        .acc_limit              (cfg_acc_limit),
        .is_generator           (cfg_is_generator),
        .needs_upsample         (cfg_needs_upsample),
        .is_fc_layer            (cfg_is_fc_layer),
        .activation             (cfg_activation),
        .fc_input_len           (cfg_fc_input_len),
        .fc_output_len          (cfg_fc_output_len),
        
        .noise_enable           (ctrl_noise_enable),
        .noise_valid            (noise_valid_int),
        
        .fc_start               (ctrl_fc_start),
        .fc_busy                (fc_busy_int),
        .fc_done                (fc_done_int),
        
        .ws_weight_base         (ctrl_ws_weight_base),
        .ws_bias_base           (ctrl_ws_bias_base),
        .ws_out_channels        (ctrl_ws_out_channels),
        .ws_num_biases          (ctrl_ws_num_biases),
        .ws_weights_per_filter  (ctrl_ws_weights_per_filter),
        .ws_start_bias          (ctrl_ws_start_bias),
        .ws_start_cache         (ctrl_ws_start_cache),
        .ws_start_stream        (ctrl_ws_start_stream),
        .ws_stop_stream         (ctrl_ws_stop_stream),
        .ws_next_group          (ctrl_ws_next_group),
        .ws_bias_done           (ws_bias_done_int),
        .ws_cache_done          (ws_cache_done_int),
        .ws_stream_ready        (ws_stream_ready_int),
        .ws_group_done          (ws_group_done_int),
        
        .pe_img_width           (ctrl_pe_img_width),
        .pe_img_height          (ctrl_pe_img_height),
        .pe_in_channels         (ctrl_pe_in_channels),
        .pe_kernel_size         (ctrl_pe_kernel_size),
        .pe_stride              (ctrl_pe_stride),
        .pe_padding             (ctrl_pe_padding),
        .pe_start               (ctrl_pe_start),
        .pe_busy                (pe_busy_int),
        .pe_done                (pe_done_int),
        
        .ups_bypass             (ctrl_ups_bypass),
        
        .prb_patch_size         (ctrl_prb_patch_size),
        .prb_replay_count       (ctrl_prb_replay_count),
        .prb_num_patches        (ctrl_prb_num_patches),
        .prb_start              (ctrl_prb_start),
        .prb_busy               (prb_busy),
        .prb_done               (prb_done),
        .prb_patch_done         (prb_patch_done),
        
        .mem_r2s_start_addr     (ctrl_mem_r2s_start_addr),
        .mem_r2s_length         (ctrl_mem_r2s_length),
        .mem_r2s_row_length     (ctrl_mem_r2s_row_length),
        .mem_r2s_row_repeat     (ctrl_mem_r2s_row_repeat),
        .mem_r2s_from_fb        (ctrl_mem_r2s_from_fb),
        .mem_r2s_start          (ctrl_mem_r2s_start),
        .mem_r2s_busy           (mem_r2s_busy),
        .mem_r2s_done           (mem_r2s_done),
        
        .mem_s2r_start_addr     (ctrl_mem_s2r_start_addr),
        .mem_s2r_length         (ctrl_mem_s2r_length),
        .mem_s2r_start          (ctrl_mem_s2r_start),
        .mem_s2r_busy           (mem_s2r_busy),
        .mem_s2r_done           (mem_s2r_done),
        
        .mem_layer_done         (ctrl_mem_layer_done),
        .mem_layer_start        (ctrl_mem_layer_start),
        .mem_active_bank        (mem_active_bank_int),
        .mem_bank_switch_ready  (mem_bank_switch_ready),
        
        .input_mux_sel          (ctrl_input_mux_sel),
        .output_mux_sel         (ctrl_output_mux_sel),
        
        .engine_mode_disc       (ctrl_engine_mode_disc),
        .engine_acc_limit       (ctrl_engine_acc_limit),
        .engine_activation      (ctrl_engine_activation)
    );

    // =========================================================================
    // NOISE GENERATOR
    // =========================================================================
    noise_generator #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_noise_gen (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (ctrl_noise_enable),
        .seed_load  (seed_load),
        .seed_value (seed_value),
        .value      (noise_value),
        .valid      (noise_valid_int)
    );

    // =========================================================================
    // WEIGHT ROM
    // =========================================================================
    weight_rom #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(32768),
        .ADDR_WIDTH(15)
    ) u_weight_rom (
        .clk    (clk),
        .rst_n  (rst_n),
        .addr   (rom_addr),
        .data   (rom_data)
    );

    // =========================================================================
    // WEIGHT STREAMER (with cache)
    // =========================================================================
    weight_streamer_cached #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(15),
        .ARRAY_SIZE(ARRAY_SIZE),
        .CACHE_DEPTH(12288)  // FC needs 512×24 = 12,288
    ) u_weight_streamer (
        .clk                    (clk),
        .rst_n                  (rst_n),
        
        .cfg_weight_base        (ctrl_ws_weight_base),
        .cfg_bias_base          (ctrl_ws_bias_base),
        .cfg_out_channels       (ctrl_ws_out_channels),
        .cfg_num_biases         (ctrl_ws_num_biases),
        .cfg_weights_per_filter (ctrl_ws_weights_per_filter),
        
        .start_bias             (ctrl_ws_start_bias),
        .start_cache            (ctrl_ws_start_cache),
        .start_stream           (ctrl_ws_start_stream),
        .stop_stream            (ctrl_ws_stop_stream),
        .next_output_group      (ctrl_ws_next_group),
        
        .data_valid             (mux_valid_out),
        .data_ready             (mux_ready_in),
        
        .rom_addr               (rom_addr),
        .rom_data               (rom_data),
        
        .weights_out            (ws_weights_out),
        .weights_valid          (ws_weights_valid),
        
        .bias_out               (ws_bias_out),
        .bias_valid             (ws_bias_valid),
        
        .busy                   (ws_busy),
        .bias_done              (ws_bias_done_int),
        .cache_done             (ws_cache_done_int),
        .stream_ready           (ws_stream_ready_int),
        .group_done             (ws_group_done_int)
    );

    // =========================================================================
    // FC LAYER HANDLER
    // =========================================================================
    fc_layer_handler #(
        .DATA_WIDTH(DATA_WIDTH),
        .INPUT_LEN(24),
        .OUTPUT_LEN(512),
        .ARRAY_SIZE(ARRAY_SIZE)
    ) u_fc_handler (
        .clk            (clk),
        .rst_n          (rst_n),
        
        .noise_data     (noise_value),
        .noise_valid    (noise_valid_int),
        .noise_ready    (),
        
        .start          (ctrl_fc_start),
        .busy           (fc_busy_int),
        .done           (fc_done_int),
        
        .fc_data_out    (fc_data_out),
        .fc_valid_out   (fc_valid_out),
        .fc_ready_in    (fc_ready_in),
        
        .fc_mode_active ()
    );

    // =========================================================================
    // UPSCALER (simple horizontal duplication)
    // =========================================================================
    
    // Wire for patch extractor ready signal to upscaler
    wire pe_pixel_ready_from_pe;
    
    upscaler_simple #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_upscaler (
        .clk          (clk),
        .rst_n        (rst_n),
        
        .bypass       (ctrl_ups_bypass),
        
        .in_data      (mem_r2s_data),
        .in_valid     (mem_r2s_valid),
        .in_ready     (ups_ready_in),
        
        .out_data     (ups_data_out),
        .out_valid    (ups_valid_out),
        .out_ready    (pe_pixel_ready_from_pe)
    );

    // =========================================================================
    // PATCH EXTRACTOR
    // =========================================================================
    patch_extractor #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_IMG_SIZE(32),
        .MAX_CHANNELS(32)
    ) u_patch_extractor (
        .clk            (clk),
        .rst_n          (rst_n),
        
        .cfg_img_width  (ctrl_pe_img_width),
        .cfg_img_height (ctrl_pe_img_height),
        .cfg_in_channels(ctrl_pe_in_channels),
        .cfg_kernel_size(ctrl_pe_kernel_size),
        .cfg_stride     (ctrl_pe_stride),
        .cfg_padding    (ctrl_pe_padding),
        
        .start          (ctrl_pe_start),
        .busy           (pe_busy_int),
        .done           (pe_done_int),
        
        .s_pixel_data   (ups_data_out),
        .s_pixel_valid  (ups_valid_out),
        .s_pixel_ready  (pe_pixel_ready_from_pe),
        
        .m_patch_data   (pe_pixel_out),
        .m_patch_valid  (pe_pixel_valid),
        .m_patch_ready  (pe_pixel_ready)
    );

    // =========================================================================
    // PATCH REPLAY BUFFER
    // =========================================================================
    patch_replay_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_PATCH_SIZE(288)  // 3×3×32
    ) u_patch_replay (
        .clk            (clk),
        .rst_n          (rst_n),
        
        .cfg_patch_size (ctrl_prb_patch_size),
        .cfg_replay_count(ctrl_prb_replay_count),
        .cfg_num_patches(ctrl_prb_num_patches),
        
        .start          (ctrl_prb_start),
        .busy           (prb_busy),
        .done           (prb_done),
        .patch_done     (prb_patch_done),
        
        .s_data         (pe_pixel_out),
        .s_valid        (pe_pixel_valid),
        .s_ready        (pe_pixel_ready),
        
        .m_data         (prb_data_out),
        .m_valid        (prb_valid_out),
        .m_ready        (prb_ready_in),
        
        .debug_patch_count(),
        .debug_replay_idx()
    );

    // =========================================================================
    // INPUT MUX
    // =========================================================================
    input_mux #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_input_mux (
        .clk            (clk),
        .rst_n          (rst_n),
        .sel            (ctrl_input_mux_sel),
        
        .fc_data        (fc_data_out),
        .fc_valid       (fc_valid_out),
        .fc_ready       (fc_ready_in),
        
        .patch_data     (prb_data_out),      // From patch replay buffer
        .patch_valid    (prb_valid_out),
        .patch_ready    (prb_ready_in),
        
        .weight_data    (16'd0),
        .weight_valid   (1'b0),
        .weight_ready   (),
        .weight_load_en (1'b0),
        
        .out_data       (mux_data_out),
        .out_valid      (mux_valid_out),
        .out_ready      (mux_ready_in),
        .out_load_en    ()
    );

    // =========================================================================
    // COMPUTE ENGINE
    // =========================================================================
    compute_engine #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(48),
        .ARRAY_SIZE(ARRAY_SIZE)
    ) u_engine (
        .clk                (clk),
        .rst_n              (rst_n),
        
        .mode_discriminator (ctrl_engine_mode_disc),
        .acc_limit          (ctrl_engine_acc_limit),
        .bias_in            (ws_bias_out),
        .activation_mode    (ctrl_engine_activation),
        
        .data_in            (mux_data_out),
        .data_valid         (mux_valid_out),
        .data_ready         (mux_ready_in),
        
        .weights_in         (ws_weights_out),
        .weights_valid      (ws_weights_valid),
        
        .result_out         (engine_result_out),
        .result_valid       (engine_result_valid),
        .result_ready       (engine_result_ready),
        
        .busy               (engine_busy_int),
        .debug_mac_count    (engine_mac_count_int),
        .debug_output_count (engine_output_count_int)
    );

    // =========================================================================
    // OUTPUT MUX
    // =========================================================================
    output_mux #(
        .DATA_WIDTH(DATA_WIDTH)
    ) u_output_mux (
        .clk            (clk),
        .rst_n          (rst_n),
        .sel            (ctrl_output_mux_sel),
        
        .s_axis_tdata   (engine_result_out),
        .s_axis_tvalid  (engine_result_valid),
        .s_axis_tready  (engine_result_ready),
        
        .m0_axis_tdata  (omux_ram_data),
        .m0_axis_tvalid (omux_ram_valid),
        .m0_axis_tready (omux_ram_ready),
        
        .m1_axis_tdata  (omux_fb_data),
        .m1_axis_tvalid (omux_fb_valid),
        .m1_axis_tready (omux_fb_ready),
        
        .disc_result    (disc_result),
        .disc_result_valid(disc_result_valid)
    );

    // =========================================================================
    // MEMORY SUBSYSTEM
    // =========================================================================
    memory_subsystem #(
        .DATA_WIDTH(DATA_WIDTH),
        .FEATURE_DEPTH(2048),
        .OUTPUT_DEPTH(1024)
    ) u_memory (
        .clk                (clk),
        .rst_n              (rst_n),
        
        .r2s_start_addr     (ctrl_mem_r2s_start_addr),
        .r2s_length         (ctrl_mem_r2s_length),
        .r2s_row_length     (ctrl_mem_r2s_row_length),
        .r2s_row_repeat     (ctrl_mem_r2s_row_repeat),
        .r2s_from_fb        (ctrl_mem_r2s_from_fb),
        .r2s_start          (ctrl_mem_r2s_start),
        .r2s_busy           (mem_r2s_busy),
        .r2s_done           (mem_r2s_done),
        .r2s_data           (mem_r2s_data),
        .r2s_valid          (mem_r2s_valid),
        .r2s_ready          (ups_ready_in),  // Connected to upscaler input
        
        .s2r_start_addr     (ctrl_mem_s2r_start_addr),
        .s2r_length         (ctrl_mem_s2r_length),
        .s2r_start          (ctrl_mem_s2r_start),
        .s2r_busy           (mem_s2r_busy),
        .s2r_done           (mem_s2r_done),
        .s2r_data           (omux_ram_data),
        .s2r_valid          (omux_ram_valid),
        .s2r_ready          (omux_ram_ready),
        
        .fb_wr_addr         (fb_wr_addr_cnt),
        .fb_wr_data         (omux_fb_data),
        .fb_wr_en           (omux_fb_valid),
        
        .fb_rd_addr         (fb_rd_addr),
        .fb_rd_data         (fb_rd_data),
        .frame_start        (1'b0),
        .frame_ready        (mem_frame_ready),
        
        .current_layer      (current_layer[2:0]),
        .layer_start        (ctrl_mem_layer_start),
        .layer_done         (ctrl_mem_layer_done),
        .active_bank        (mem_active_bank_int),
        .bank_switch_ready  (mem_bank_switch_ready),
        .bank_switched      (),
        .pingpong_status    ()
    );

endmodule