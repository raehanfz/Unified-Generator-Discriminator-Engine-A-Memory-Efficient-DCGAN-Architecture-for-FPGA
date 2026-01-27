/*
 * Weight Streamer - Synchronized Streaming
 * 
 * Purpose: Stream weights from ROM synchronized with input data
 *          NO preloading - weights flow during compute
 * 
 * Operation Modes:
 *   1. BIAS_LOAD: Load biases into internal buffer (small, done first)
 *   2. STREAM: Output 4 weights per input data item
 * 
 * Weight Addressing:
 *   For 4-output parallel processing, we need interleaved access:
 *   - Input i going to outputs [g*4, g*4+1, g*4+2, g*4+3]
 *   - Addresses: base + (g*4+0)*wpf + i, base + (g*4+1)*wpf + i, ...
 *   where wpf = weights_per_filter (e.g., 24 for FC, K²×Cin for conv)
 */

`timescale 1ns / 1ps

module weight_streamer #(
    parameter DATA_WIDTH  = 16,
    parameter ADDR_WIDTH  = 15,
    parameter ARRAY_SIZE  = 4
)(
    input  wire clk,
    input  wire rst_n,
    
    // =========================================================================
    // CONFIGURATION (from Controller)
    // =========================================================================
    input  wire [ADDR_WIDTH-1:0] cfg_weight_base,
    input  wire [ADDR_WIDTH-1:0] cfg_bias_base,
    input  wire [5:0]            cfg_out_channels,
    input  wire [9:0]            cfg_weights_per_filter,  // 24 for FC, K²×Cin for conv
    
    // =========================================================================
    // CONTROL
    // =========================================================================
    input  wire start_bias,           // Pulse: load biases first
    input  wire start_stream,         // Pulse: begin weight streaming mode
    input  wire stop_stream,          // Pulse: end streaming
    input  wire next_output_group,    // Pulse: advance to next 4 outputs
    
    // =========================================================================
    // SYNCHRONIZATION WITH DATA
    // =========================================================================
    input  wire data_valid,           // Input data is valid this cycle
    input  wire data_ready,           // Downstream accepted data
    
    // =========================================================================
    // ROM INTERFACE
    // =========================================================================
    output reg  [ADDR_WIDTH-1:0] rom_addr,
    input  wire [DATA_WIDTH-1:0] rom_data,
    
    // =========================================================================
    // WEIGHT OUTPUT (4 weights packed)
    // =========================================================================
    output reg  signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] weights_out,
    output reg                                       weights_valid,
    
    // =========================================================================
    // BIAS OUTPUT
    // =========================================================================
    output reg  signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] bias_out,
    output reg                                       bias_valid,
    
    // =========================================================================
    // STATUS
    // =========================================================================
    output reg  busy,
    output reg  bias_done,
    output reg  stream_ready,         // Ready to stream weights
    output reg  group_done            // Current output group complete
);

    // =========================================================================
    // STATE MACHINE
    // =========================================================================
    localparam S_IDLE        = 3'd0;
    localparam S_LOAD_BIAS   = 3'd1;
    localparam S_BIAS_READ   = 3'd2;
    localparam S_STREAM_INIT = 3'd3;
    localparam S_STREAM_RUN  = 3'd4;
    localparam S_STREAM_WAIT = 3'd5;
    localparam S_GROUP_DONE  = 3'd6;
    
    reg [2:0] state;
    
    // =========================================================================
    // COUNTERS & POINTERS
    // =========================================================================
    reg [5:0]  bias_count;
    reg [1:0]  bias_idx;
    reg signed [DATA_WIDTH-1:0] bias_buffer [0:ARRAY_SIZE-1];
    
    reg [7:0]  output_group;          // Which group of 4 outputs (0 to out_ch/4 - 1)
    reg [9:0]  input_idx;             // Which input in current group (0 to wpf-1)
    reg [1:0]  weight_fetch_idx;      // Which of 4 weights being fetched (0-3)
    reg signed [DATA_WIDTH-1:0] weight_buffer [0:ARRAY_SIZE-1];
    
    // =========================================================================
    // ADDRESS CALCULATION
    // =========================================================================
    // For interleaved access: base + (output_group*4 + weight_fetch_idx) * wpf + input_idx
    wire [ADDR_WIDTH-1:0] weight_addr;
    wire [ADDR_WIDTH-1:0] output_offset;
    
    assign output_offset = (output_group * ARRAY_SIZE + weight_fetch_idx) * cfg_weights_per_filter;
    assign weight_addr = cfg_weight_base + output_offset + input_idx;
    
    // =========================================================================
    // PIPELINE CONTROL
    // =========================================================================
    reg read_pending;
    reg [1:0] pending_idx;
    
    integer i;
    
    // =========================================================================
    // MAIN STATE MACHINE
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy <= 0;
            bias_done <= 0;
            stream_ready <= 0;
            group_done <= 0;
            
            rom_addr <= 0;
            weights_out <= 0;
            weights_valid <= 0;
            bias_out <= 0;
            bias_valid <= 0;
            
            bias_count <= 0;
            bias_idx <= 0;
            output_group <= 0;
            input_idx <= 0;
            weight_fetch_idx <= 0;
            read_pending <= 0;
            pending_idx <= 0;
            
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                bias_buffer[i] <= 0;
                weight_buffer[i] <= 0;
            end
            
        end else begin
            // Default: clear pulses
            bias_done <= 0;
            group_done <= 0;
            
            case (state)
                // ---------------------------------------------------------
                S_IDLE: begin
                    busy <= 0;
                    stream_ready <= 0;
                    weights_valid <= 0;
                    bias_valid <= 0;
                    
                    if (start_bias) begin
                        state <= S_LOAD_BIAS;
                        busy <= 1;
                        bias_count <= 0;
                        bias_idx <= 0;
                        rom_addr <= cfg_bias_base;
                        read_pending <= 1;
                        pending_idx <= 0;
                        $display("[WS] Starting bias load: base=%0d, out_ch=%0d", 
                                cfg_bias_base, cfg_out_channels);
                    end else if (start_stream) begin
                        state <= S_STREAM_INIT;
                        busy <= 1;
                        output_group <= 0;
                        input_idx <= 0;
                        weight_fetch_idx <= 0;
                    end
                end
                
                // ---------------------------------------------------------
                // BIAS LOADING
                // ---------------------------------------------------------
                S_LOAD_BIAS: begin
                    if (read_pending) begin
                        read_pending <= 0;
                        state <= S_BIAS_READ;
                    end
                end
                
                S_BIAS_READ: begin
                    // Store bias from ROM
                    bias_buffer[bias_idx] <= rom_data;
                    
                    if (bias_idx == ARRAY_SIZE - 1) begin
                        // Got 4 biases, pack and output
                        bias_out <= {rom_data, bias_buffer[2], bias_buffer[1], bias_buffer[0]};
                        bias_valid <= 1;
                        bias_idx <= 0;
                        
                        if (bias_count >= cfg_out_channels - 1) begin
                            // All biases loaded
                            bias_done <= 1;
                            busy <= 0;
                            state <= S_IDLE;
                            $display("[WS] Bias load complete: count=%0d", bias_count);
                        end else begin
                            bias_count <= bias_count + 1;
                            rom_addr <= cfg_bias_base + bias_count + 1;
                            read_pending <= 1;
                            state <= S_LOAD_BIAS;
                        end
                    end else begin
                        bias_idx <= bias_idx + 1;
                        bias_count <= bias_count + 1;
                        rom_addr <= cfg_bias_base + bias_count + 1;
                        read_pending <= 1;
                        state <= S_LOAD_BIAS;
                    end
                end
                
                // ---------------------------------------------------------
                // WEIGHT STREAMING
                // ---------------------------------------------------------
                S_STREAM_INIT: begin
                    // Start fetching first set of 4 weights
                    weight_fetch_idx <= 0;
                    rom_addr <= weight_addr;
                    read_pending <= 1;
                    pending_idx <= 0;
                    stream_ready <= 1;
                    state <= S_STREAM_RUN;
                end
                
                S_STREAM_RUN: begin
                    weights_valid <= 0;
                    
                    // Check for stop signal
                    if (stop_stream) begin
                        state <= S_IDLE;
                        busy <= 0;
                        stream_ready <= 0;
                        weights_valid <= 0;
                        $display("[WS] Stopped streaming (from STREAM_RUN)");
                    end
                    // Handle ROM read completion
                    else if (read_pending) begin
                        read_pending <= 0;
                        weight_buffer[pending_idx] <= rom_data;
                        
                        if (pending_idx == ARRAY_SIZE - 1) begin
                            // All 4 weights fetched, pack output
                            weights_out <= {rom_data, weight_buffer[2], 
                                          weight_buffer[1], weight_buffer[0]};
                            weights_valid <= 1;
                            state <= S_STREAM_WAIT;
                        end else begin
                            // Fetch next weight
                            weight_fetch_idx <= pending_idx + 1;
                            pending_idx <= pending_idx + 1;
                            rom_addr <= cfg_weight_base + 
                                       (output_group * ARRAY_SIZE + pending_idx + 1) * cfg_weights_per_filter + 
                                       input_idx;
                            read_pending <= 1;
                        end
                    end
                end
                
                S_STREAM_WAIT: begin
                    // Check for stop signal
                    if (stop_stream) begin
                        state <= S_IDLE;
                        busy <= 0;
                        stream_ready <= 0;
                        weights_valid <= 0;
                    end
                    // Wait for data handshake
                    else if (data_valid && data_ready) begin
                        weights_valid <= 0;
                        
                        if (input_idx >= cfg_weights_per_filter - 1) begin
                            // Finished this output group
                            group_done <= 1;
                            input_idx <= 0;
                            state <= S_GROUP_DONE;
                        end else begin
                            // Next input in same group
                            input_idx <= input_idx + 1;
                            weight_fetch_idx <= 0;
                            pending_idx <= 0;
                            rom_addr <= cfg_weight_base + 
                                       (output_group * ARRAY_SIZE + 0) * cfg_weights_per_filter + 
                                       input_idx + 1;
                            read_pending <= 1;
                            state <= S_STREAM_RUN;
                        end
                    end
                    
                    if (stop_stream) begin
                        state <= S_IDLE;
                        busy <= 0;
                        stream_ready <= 0;
                    end
                end
                
                S_GROUP_DONE: begin
                    group_done <= 0;
                    
                    if (next_output_group) begin
                        // Check if we need to wrap around
                        if ((output_group + 1) * ARRAY_SIZE >= cfg_out_channels) begin
                            // Wrap to group 0 for next patch
                            output_group <= 0;
                        end else begin
                            output_group <= output_group + 1;
                        end
                        input_idx <= 0;
                        weight_fetch_idx <= 0;
                        pending_idx <= 0;
                        
                        // Calculate address for (potentially wrapped) next group
                        if ((output_group + 1) * ARRAY_SIZE >= cfg_out_channels) begin
                            rom_addr <= cfg_weight_base + 0;  // Group 0
                        end else begin
                            rom_addr <= cfg_weight_base + 
                                       ((output_group + 1) * ARRAY_SIZE + 0) * cfg_weights_per_filter + 0;
                        end
                        read_pending <= 1;
                        state <= S_STREAM_RUN;
                    end
                    
                    if (stop_stream) begin
                        state <= S_IDLE;
                        busy <= 0;
                        stream_ready <= 0;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule