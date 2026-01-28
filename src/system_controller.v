/*
 * System Controller
 * 
 * Purpose: Orchestrate DCGAN inference through all layers
 * 
 * State Flow:
 *   IDLE → GEN_START → LOAD_BIAS → FC_PROCESS → CONV_PROCESS (×4) → DONE
 */

`timescale 1ns / 1ps

module system_controller #(
    parameter DATA_WIDTH = 16,
    parameter ARRAY_SIZE = 4
)(
    input  wire clk,
    input  wire rst_n,
    
    // =========================================================================
    // EXTERNAL CONTROL
    // =========================================================================
    input  wire start_generator,
    input  wire start_discriminator,  // Not implemented yet
    output reg  busy,
    output reg  inference_done,
    output reg  [3:0] current_layer,
    output reg  [4:0] state_out,
    
    // =========================================================================
    // LAYER CONFIG ROM INTERFACE
    // =========================================================================
    output reg  [3:0] layer_id,
    input  wire [14:0] weight_base,
    input  wire [14:0] bias_base,
    input  wire [15:0] num_weights,
    input  wire [5:0]  num_biases,
    input  wire [5:0]  in_channels,
    input  wire [5:0]  out_channels,
    input  wire [5:0]  in_size,
    input  wire [5:0]  out_size,
    input  wire [2:0]  kernel_size,
    input  wire [1:0]  stride,
    input  wire [1:0]  padding,
    input  wire [9:0]  acc_limit,
    input  wire        is_generator,
    input  wire        needs_upsample,
    input  wire        is_fc_layer,
    input  wire [1:0]  activation,
    input  wire [9:0]  fc_input_len,
    input  wire [9:0]  fc_output_len,
    
    // =========================================================================
    // NOISE GENERATOR CONTROL
    // =========================================================================
    output reg  noise_enable,
    input  wire noise_valid,
    
    // =========================================================================
    // FC LAYER HANDLER CONTROL
    // =========================================================================
    output reg  fc_start,
    input  wire fc_busy,
    input  wire fc_done,
    
    // =========================================================================
    // WEIGHT STREAMER CONTROL
    // =========================================================================
    output reg  [14:0] ws_weight_base,
    output reg  [14:0] ws_bias_base,
    output reg  [9:0]  ws_out_channels,       // Widened for FC (512)
    output reg  [9:0]  ws_num_biases,         // Actual bias count
    output reg  [9:0]  ws_weights_per_filter,
    output reg  ws_start_bias,
    output reg  ws_start_cache,        // NEW: Start cache loading
    output reg  ws_start_stream,
    output reg  ws_stop_stream,
    output reg  ws_next_group,
    input  wire ws_bias_done,
    input  wire ws_cache_done,         // NEW: Cache load complete
    input  wire ws_stream_ready,
    input  wire ws_group_done,
    
    // =========================================================================
    // PATCH EXTRACTOR CONTROL
    // =========================================================================
    output reg  [5:0]  pe_img_width,
    output reg  [5:0]  pe_img_height,
    output reg  [5:0]  pe_in_channels,
    output reg  [2:0]  pe_kernel_size,
    output reg  [1:0]  pe_stride,
    output reg  [1:0]  pe_padding,
    output reg  pe_start,
    input  wire pe_busy,
    input  wire pe_done,
    
    // =========================================================================
    // UPSCALER CONTROL
    // =========================================================================
    output reg         ups_bypass,
    
    // =========================================================================
    // PATCH REPLAY BUFFER CONTROL
    // =========================================================================
    output reg  [9:0]  prb_patch_size,
    output reg  [7:0]  prb_replay_count,
    output reg  [15:0] prb_num_patches,
    output reg         prb_start,
    input  wire        prb_busy,
    input  wire        prb_done,
    input  wire        prb_patch_done,
    
    // =========================================================================
    // MEMORY SUBSYSTEM CONTROL
    // =========================================================================
    output reg  [11:0] mem_r2s_start_addr,
    output reg  [11:0] mem_r2s_length,
    output reg  [11:0] mem_r2s_row_length,
    output reg         mem_r2s_row_repeat,
    output reg         mem_r2s_from_fb,   // Read from framebuffer (disc L0)
    output reg  mem_r2s_start,
    input  wire mem_r2s_busy,
    input  wire mem_r2s_done,
    
    output reg  [10:0] mem_s2r_start_addr,
    output reg  [10:0] mem_s2r_length,
    output reg  mem_s2r_start,
    input  wire mem_s2r_busy,
    input  wire mem_s2r_done,
    
    output reg  mem_layer_done,
    output reg  mem_layer_start,
    input  wire mem_active_bank,
    input  wire mem_bank_switch_ready,
    
    // =========================================================================
    // MUX CONTROL
    // =========================================================================
    output reg  [1:0] input_mux_sel,
    output reg  [1:0] output_mux_sel,
    
    // =========================================================================
    // ENGINE CONFIG
    // =========================================================================
    output reg  engine_mode_disc,
    output reg  [9:0] engine_acc_limit,
    output reg  [1:0] engine_activation
);

    // =========================================================================
    // STATE MACHINE
    // =========================================================================
    localparam S_IDLE           = 5'd0;
    localparam S_GEN_START      = 5'd1;
    localparam S_LOAD_BIAS      = 5'd2;
    localparam S_WAIT_BIAS      = 5'd3;
    localparam S_FC_CACHE       = 5'd27;  // NEW: Load FC weights to cache
    localparam S_FC_WAIT_CACHE  = 5'd28;  // NEW: Wait for FC cache load
    localparam S_FC_START       = 5'd4;
    localparam S_FC_PROCESS     = 5'd5;
    localparam S_FC_WAIT_DONE   = 5'd6;
    localparam S_FC_DRAIN       = 5'd7;
    localparam S_CONV_SETUP     = 5'd8;
    localparam S_CONV_BIAS      = 5'd9;
    localparam S_CONV_WAIT_BIAS = 5'd10;
    localparam S_CONV_CACHE     = 5'd25;  // NEW: Load weights to cache
    localparam S_CONV_WAIT_CACHE = 5'd26; // NEW: Wait for cache load
    localparam S_CONV_START     = 5'd11;
    localparam S_CONV_PROCESS   = 5'd12;
    localparam S_CONV_WAIT_DONE = 5'd13;
    localparam S_CONV_DRAIN     = 5'd14;
    localparam S_BANK_SWITCH    = 5'd15;
    localparam S_NEXT_LAYER     = 5'd16;
    localparam S_LAYER_WAIT     = 5'd19;
    localparam S_LAYER_WAIT2    = 5'd20;
    localparam S_OUTPUT         = 5'd17;
    localparam S_DONE           = 5'd18;
    // Discriminator states
    localparam S_DISC_START     = 5'd21;
    localparam S_DISC_SETUP     = 5'd22;
    localparam S_DISC_LAYER_WAIT = 5'd23;
    localparam S_DISC_DONE      = 5'd24;
    
    reg [4:0] state;
    reg [3:0] gen_layer_count;
    reg [3:0] disc_layer_count;  // Discriminator layer counter (0-3)
    reg [7:0] output_group_count;
    reg [7:0] total_output_groups;
    reg [3:0] drain_count;
    
    // =========================================================================
    // DEBUG
    // =========================================================================
    always @(*) begin
        state_out = state;
        current_layer = layer_id;
    end
    
    // =========================================================================
    // MAIN STATE MACHINE
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy <= 0;
            inference_done <= 0;
            layer_id <= 0;
            gen_layer_count <= 0;
            disc_layer_count <= 0;
            output_group_count <= 0;
            total_output_groups <= 0;
            drain_count <= 0;
            
            // Control signals
            noise_enable <= 0;
            fc_start <= 0;
            ws_start_bias <= 0;
            ws_start_stream <= 0;
            ws_stop_stream <= 0;
            ws_next_group <= 0;
            pe_start <= 0;
            mem_r2s_start <= 0;
            mem_s2r_start <= 0;
            mem_layer_done <= 0;
            mem_layer_start <= 0;
            
            // Config signals
            ws_weight_base <= 0;
            ws_bias_base <= 0;
            ws_out_channels <= 0;
            ws_num_biases <= 0;
            ws_weights_per_filter <= 0;
            pe_img_width <= 0;
            pe_img_height <= 0;
            pe_in_channels <= 0;
            pe_kernel_size <= 0;
            pe_stride <= 0;
            pe_padding <= 0;
            ups_bypass <= 1;
            prb_patch_size <= 0;
            prb_replay_count <= 0;
            prb_num_patches <= 0;
            prb_start <= 0;
            mem_r2s_start_addr <= 0;
            mem_r2s_length <= 0;
            mem_r2s_row_length <= 0;
            mem_r2s_row_repeat <= 0;
            mem_r2s_from_fb <= 0;
            mem_s2r_start_addr <= 0;
            mem_s2r_length <= 0;
            input_mux_sel <= 0;
            output_mux_sel <= 0;
            engine_mode_disc <= 0;
            engine_acc_limit <= 0;
            engine_activation <= 0;
            
        end else begin
            // Clear pulses
            inference_done <= 0;
            fc_start <= 0;
            ws_start_bias <= 0;
            ws_start_cache <= 0;
            ws_start_stream <= 0;
            ws_stop_stream <= 0;
            ws_next_group <= 0;
            pe_start <= 0;
            prb_start <= 0;
            mem_r2s_start <= 0;
            mem_s2r_start <= 0;
            mem_layer_done <= 0;
            mem_layer_start <= 0;
            
            case (state)
                S_IDLE: begin
                    busy <= 0;
                    noise_enable <= 0;
                    
                    if (start_generator) begin
                        state <= S_GEN_START;
                        busy <= 1;
                        layer_id <= 0;
                        gen_layer_count <= 0;
                        $display("[CTRL] Starting Generator");
                    end else if (start_discriminator) begin
                        state <= S_DISC_START;
                        busy <= 1;
                        disc_layer_count <= 0;
                        layer_id <= 5;  // D_L0
                        $display("[CTRL] Starting Discriminator");
                    end
                end
                
                S_GEN_START: begin
                    input_mux_sel <= 2'd0;
                    output_mux_sel <= 2'd0;
                    engine_mode_disc <= 0;
                    engine_acc_limit <= acc_limit;
                    engine_activation <= activation;
                    
                    ws_weight_base <= weight_base;
                    ws_bias_base <= bias_base;
                    // FC layer: need to cache ALL 512 outputs' weights
                    ws_out_channels <= fc_output_len;
                    ws_num_biases <= {4'd0, out_channels};  // 32 biases for FC
                    ws_weights_per_filter <= fc_input_len;
                    
                    total_output_groups <= fc_output_len / ARRAY_SIZE;
                    output_group_count <= 0;
                    
                    state <= S_LOAD_BIAS;
                    $display("[CTRL] FC: Loading bias, output_groups=%0d", fc_output_len / ARRAY_SIZE);
                end
                
                S_LOAD_BIAS: begin
                    ws_start_bias <= 1;
                    state <= S_WAIT_BIAS;
                end
                
                S_WAIT_BIAS: begin
                    if (ws_bias_done) begin
                        if (gen_layer_count == 0) begin
                            state <= S_FC_CACHE;
                            $display("[CTRL] FC: Bias loaded, loading cache");
                        end else begin
                            state <= S_CONV_START;
                            $display("[CTRL] Conv: Bias loaded, starting process");
                        end
                    end
                end
                
                S_FC_CACHE: begin
                    ws_start_cache <= 1;
                    state <= S_FC_WAIT_CACHE;
                end
                
                S_FC_WAIT_CACHE: begin
                    if (ws_cache_done) begin
                        state <= S_FC_START;
                        $display("[CTRL] FC: Cache loaded, starting process");
                    end
                end
                
                S_FC_START: begin
                    ws_start_stream <= 1;
                    mem_layer_start <= 1;
                    mem_s2r_start_addr <= 0;
                    mem_s2r_length <= fc_output_len;
                    mem_s2r_start <= 1;
                    noise_enable <= 1;
                    state <= S_FC_PROCESS;
                end
                
                S_FC_PROCESS: begin
                    fc_start <= 1;
                    state <= S_FC_WAIT_DONE;
                end
                
                S_FC_WAIT_DONE: begin
                    if (ws_group_done) begin
                        output_group_count <= output_group_count + 1;
                        
                        if (output_group_count >= total_output_groups - 1) begin
                            ws_stop_stream <= 1;
                            noise_enable <= 0;
                            drain_count <= 0;
                            state <= S_FC_DRAIN;
                            $display("[CTRL] FC: All groups done, draining");
                        end else begin
                            ws_next_group <= 1;
                        end
                    end
                    
                    if (fc_done) begin
                        ws_stop_stream <= 1;
                        noise_enable <= 0;
                        drain_count <= 0;
                        state <= S_FC_DRAIN;
                    end
                end
                
                S_FC_DRAIN: begin
                    drain_count <= drain_count + 1;
                    if (drain_count >= 4'd10) begin
                        drain_count <= 0;
                        state <= S_BANK_SWITCH;
                        gen_layer_count <= 1;
                        $display("[CTRL] FC: Complete, switching banks");
                    end
                end
                
                S_BANK_SWITCH: begin
                    mem_layer_done <= 1;
                    state <= S_NEXT_LAYER;
                end
                
                S_NEXT_LAYER: begin
                    if (mem_bank_switch_ready) begin
                        // Check if discriminator mode
                        if (layer_id >= 5) begin
                            // Discriminator: move to next layer
                            state <= S_DISC_LAYER_WAIT;
                            $display("[CTRL] Disc: Starting layer %0d (layer_id=%0d)", disc_layer_count, layer_id);
                        end else if (gen_layer_count > 4) begin
                            state <= S_OUTPUT;
                            $display("[CTRL] All generator layers done");
                        end else begin
                            layer_id <= gen_layer_count;
                            state <= S_LAYER_WAIT;
                            $display("[CTRL] Starting layer %0d", gen_layer_count);
                        end
                    end
                end
                
                S_LAYER_WAIT: begin
                    state <= S_LAYER_WAIT2;
                end
                
                S_LAYER_WAIT2: begin
                    state <= S_CONV_SETUP;
                end
                
                S_CONV_SETUP: begin
                    input_mux_sel <= 2'd1;
                    
                    $display("[CTRL] Conv L%0d: in_ch=%0d out_ch=%0d in_sz=%0d out_sz=%0d k=%0d",
                            gen_layer_count, in_channels, out_channels, in_size, out_size, kernel_size);
                    
                    if (gen_layer_count == 4) begin
                        output_mux_sel <= 2'd1;
                        $display("[CTRL] Conv L4: OUTPUT TO FRAMEBUFFER (mux_sel=1)");
                    end else begin
                        output_mux_sel <= 2'd0;
                        $display("[CTRL] Conv L%0d: output to RAM (mux_sel=0)", gen_layer_count);
                    end
                    
                    ws_weight_base <= weight_base;
                    ws_bias_base <= bias_base;
                    ws_out_channels <= out_channels;
                    ws_num_biases <= {4'd0, out_channels};
                    ws_weights_per_filter <= ({7'd0, kernel_size} * {7'd0, kernel_size}) * {4'd0, in_channels};
                    
                    pe_img_width <= in_size;
                    pe_img_height <= in_size;
                    pe_in_channels <= in_channels;
                    pe_kernel_size <= kernel_size;
                    pe_stride <= stride;
                    pe_padding <= padding;
                    
                    // Configure upscaler
                    if (needs_upsample) begin
                        ups_bypass <= 0;
                        $display("[CTRL] Conv L%0d: Upscale %0dx%0d -> %0dx%0d", 
                                gen_layer_count, in_size>>1, in_size>>1, in_size, in_size);
                    end else begin
                        ups_bypass <= 1;
                        $display("[CTRL] Conv L%0d: No upsample, size=%0dx%0d", 
                                gen_layer_count, in_size, in_size);
                    end
                    
                    prb_patch_size <= ({7'd0, kernel_size} * {7'd0, kernel_size}) * {4'd0, in_channels};
                    prb_replay_count <= (out_channels + ARRAY_SIZE - 1) / ARRAY_SIZE;
                    prb_num_patches <= {10'd0, out_size} * {10'd0, out_size};
                    $display("[CTRL] Conv L%0d: PRB patch=%0d, replay=%0d, num=%0d",
                            gen_layer_count, 
                            ({7'd0, kernel_size} * {7'd0, kernel_size}) * {4'd0, in_channels},
                            (out_channels + ARRAY_SIZE - 1) / ARRAY_SIZE,
                            {10'd0, out_size} * {10'd0, out_size});
                    
                    engine_acc_limit <= acc_limit;
                    engine_activation <= activation;
                    total_output_groups <= out_channels / ARRAY_SIZE;
                    output_group_count <= 0;
                    
                    state <= S_CONV_BIAS;
                end
                
                S_CONV_BIAS: begin
                    ws_start_bias <= 1;
                    state <= S_CONV_WAIT_BIAS;
                end
                
                S_CONV_WAIT_BIAS: begin
                    if (ws_bias_done) begin
                        state <= S_CONV_CACHE;  // Go to cache loading
                        if (layer_id >= 5) begin
                            $display("[CTRL] Disc L%0d: Bias done, loading cache", disc_layer_count);
                        end else begin
                            $display("[CTRL] Conv L%0d: Bias done, loading cache", gen_layer_count);
                        end
                    end
                end
                
                S_CONV_CACHE: begin
                    ws_start_cache <= 1;
                    state <= S_CONV_WAIT_CACHE;
                end
                
                S_CONV_WAIT_CACHE: begin
                    if (ws_cache_done) begin
                        state <= S_CONV_START;
                        if (layer_id >= 5) begin
                            $display("[CTRL] Disc L%0d: Cache loaded", disc_layer_count);
                        end else begin
                            $display("[CTRL] Conv L%0d: Cache loaded", gen_layer_count);
                        end
                    end
                end
                
                S_CONV_START: begin
                    ws_start_stream <= 1;
                    mem_layer_start <= 1;
                    
                    mem_r2s_start_addr <= 0;
                    
                    // Check if discriminator mode (layer_id >= 5)
                    if (layer_id >= 5) begin
                        // Discriminator: no upsampling, use actual input size
                        // Use wider arithmetic for 32×32×3 = 3072
                        mem_r2s_length <= ({6'd0, in_size} * {6'd0, in_size}) * {6'd0, in_channels};
                        mem_r2s_row_length <= 0;
                        mem_r2s_row_repeat <= 0;
                        // D_L0 reads from framebuffer, others from RAM
                        mem_r2s_from_fb <= (disc_layer_count == 0) ? 1'b1 : 1'b0;
                        $display("[CTRL] Disc L%0d: r2s_length=%0d, from_fb=%0d", 
                                disc_layer_count, 
                                ({6'd0, in_size} * {6'd0, in_size}) * {6'd0, in_channels},
                                (disc_layer_count == 0) ? 1 : 0);
                    end else if (needs_upsample) begin
                        // Generator with upsampling
                        mem_r2s_length <= (in_size >> 1) * (in_size >> 1) * in_channels;
                        mem_r2s_row_length <= (in_size >> 1) * in_channels;
                        mem_r2s_row_repeat <= 1;
                        mem_r2s_from_fb <= 0;
                    end else begin
                        // Generator without upsampling
                        mem_r2s_length <= in_size * in_size * in_channels;
                        mem_r2s_row_length <= 0;
                        mem_r2s_row_repeat <= 0;
                        mem_r2s_from_fb <= 0;
                    end
                    mem_r2s_start <= 1;
                    
                    pe_start <= 1;
                    prb_start <= 1;
                    
                    // Output destination
                    if (layer_id >= 5) begin
                        // Discriminator: always to RAM (except last layer)
                        if (disc_layer_count == 3) begin
                            // D_L3 output is final result
                            output_mux_sel <= 2'd0;  // Still to RAM for now
                        end
                        mem_s2r_start_addr <= 0;
                        mem_s2r_length <= (out_size * out_size * out_channels > 2047) ? 
                                         11'd2047 : out_size * out_size * out_channels;
                        mem_s2r_start <= 1;
                    end else if (gen_layer_count != 4) begin
                        // Generator: to RAM (not final layer)
                        mem_s2r_start_addr <= 0;
                        mem_s2r_length <= (out_size * out_size * out_channels > 2047) ? 
                                         11'd2047 : out_size * out_size * out_channels;
                        mem_s2r_start <= 1;
                    end
                    
                    state <= S_CONV_PROCESS;
                end
                
                S_CONV_PROCESS: begin
                    state <= S_CONV_WAIT_DONE;
                end
                
                S_CONV_WAIT_DONE: begin
                    if (ws_group_done) begin
                        ws_next_group <= 1;
                    end
                    
                    if (prb_patch_done) begin
                        output_group_count <= 0;
                    end
                    
                    if (prb_done) begin
                        ws_stop_stream <= 1;
                        drain_count <= 0;
                        state <= S_CONV_DRAIN;
                        if (layer_id >= 5) begin
                            $display("[CTRL] Disc L%0d: All patches done", disc_layer_count);
                        end else begin
                            $display("[CTRL] Conv L%0d: All patches done", gen_layer_count);
                        end
                    end
                    
                    if (pe_done && !prb_busy) begin
                        ws_stop_stream <= 1;
                        drain_count <= 0;
                        state <= S_CONV_DRAIN;
                        $display("[CTRL] Conv L%0d: PE done fallback", gen_layer_count);
                    end
                end
                
                S_CONV_DRAIN: begin
                    drain_count <= drain_count + 1;
                    if (drain_count >= 4'd10) begin
                        drain_count <= 0;
                        
                        // Check if discriminator mode
                        if (layer_id >= 5) begin
                            // Discriminator
                            if (disc_layer_count >= 3) begin
                                // Final discriminator layer done
                                state <= S_DISC_DONE;
                            end else begin
                                // Move to next disc layer
                                disc_layer_count <= disc_layer_count + 1;
                                layer_id <= layer_id + 1;
                                state <= S_BANK_SWITCH;
                                $display("[CTRL] Disc: Layer %0d complete", disc_layer_count);
                            end
                        end else begin
                            // Generator
                            if (gen_layer_count == 4) begin
                                state <= S_OUTPUT;
                            end else begin
                                gen_layer_count <= gen_layer_count + 1;
                                state <= S_BANK_SWITCH;
                                $display("[CTRL] Conv: Layer %0d complete", gen_layer_count);
                            end
                        end
                    end
                end
                
                S_OUTPUT: begin
                    state <= S_DONE;
                end
                
                S_DONE: begin
                    inference_done <= 1;
                    busy <= 0;
                    state <= S_IDLE;
                    $display("[CTRL] Generator complete!");
                end
                
                // =============================================================
                // DISCRIMINATOR STATES
                // =============================================================
                S_DISC_START: begin
                    // Configure for discriminator mode
                    engine_mode_disc <= 1;  // LeakyReLU mode
                    input_mux_sel <= 2'd1;  // Patch extractor
                    output_mux_sel <= 2'd0; // To RAM
                    
                    // Signal memory subsystem to prepare
                    // First layer reads from framebuffer (generator output)
                    mem_layer_start <= 1;
                    
                    disc_layer_count <= 0;
                    layer_id <= 5;  // D_L0
                    state <= S_DISC_LAYER_WAIT;
                    $display("[CTRL] Disc: Starting, reading from framebuffer");
                end
                
                S_DISC_LAYER_WAIT: begin
                    // Wait for layer_id to propagate to config ROM
                    state <= S_DISC_SETUP;
                end
                
                S_DISC_SETUP: begin
                    // Configure for current discriminator layer
                    $display("[CTRL] Disc L%0d: in_ch=%0d out_ch=%0d in_sz=%0d out_sz=%0d k=%0d s=%0d",
                            disc_layer_count, in_channels, out_channels, in_size, out_size, 
                            kernel_size, stride);
                    
                    // Output routing: final layer (D_L3) goes to discriminator result
                    if (disc_layer_count == 3) begin
                        output_mux_sel <= 2'd2;  // To discriminator result register
                    end else begin
                        output_mux_sel <= 2'd0;  // To RAM
                    end
                    
                    // Weight streamer config
                    ws_weight_base <= weight_base;
                    ws_bias_base <= bias_base;
                    ws_out_channels <= out_channels;
                    ws_num_biases <= {4'd0, out_channels};
                    ws_weights_per_filter <= ({7'd0, kernel_size} * {7'd0, kernel_size}) * {4'd0, in_channels};
                    
                    // Patch extractor config
                    pe_img_width <= in_size;
                    pe_img_height <= in_size;
                    pe_in_channels <= in_channels;
                    pe_kernel_size <= kernel_size;
                    pe_stride <= stride;
                    pe_padding <= padding;
                    
                    // No upsampling in discriminator
                    ups_bypass <= 1;
                    
                    // Patch replay buffer - output positions based on stride
                    prb_patch_size <= ({7'd0, kernel_size} * {7'd0, kernel_size}) * {4'd0, in_channels};
                    prb_replay_count <= (out_channels + ARRAY_SIZE - 1) / ARRAY_SIZE;
                    prb_num_patches <= {10'd0, out_size} * {10'd0, out_size};
                    
                    $display("[CTRL] Disc L%0d: PRB patch=%0d, replay=%0d, num=%0d",
                            disc_layer_count,
                            ({7'd0, kernel_size} * {7'd0, kernel_size}) * {4'd0, in_channels},
                            (out_channels + ARRAY_SIZE - 1) / ARRAY_SIZE,
                            {10'd0, out_size} * {10'd0, out_size});
                    
                    // Engine config
                    engine_acc_limit <= acc_limit;
                    engine_activation <= activation;  // LeakyReLU for disc
                    
                    total_output_groups <= out_channels / ARRAY_SIZE;
                    if (out_channels < ARRAY_SIZE) total_output_groups <= 1;
                    output_group_count <= 0;
                    
                    state <= S_CONV_BIAS;  // Reuse conv bias loading
                end
                
                S_DISC_DONE: begin
                    inference_done <= 1;
                    busy <= 0;
                    engine_mode_disc <= 0;
                    state <= S_IDLE;
                    $display("[CTRL] Discriminator complete!");
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule