/*
 * Weight Streamer with Integrated Cache - Fixed Version
 * 
 * Purpose: Load biases and stream weights, with caching to avoid redundant ROM reads
 * 
 * Operation:
 *   1. BIAS_LOAD: Load biases from ROM (unchanged from original)
 *   2. CACHE_LOAD: Load ALL weights for layer into cache
 *   3. STREAM: Serve weights from cache synchronized with data flow
 * 
 * Cache Size: 12288 elements max (FC: 512 outputs × 24 inputs)
 * 
 * Key Fix: Weights are output and held valid until data handshake occurs,
 *          matching the original weight_streamer behavior.
 */

`timescale 1ns / 1ps

module weight_streamer_cached #(
    parameter DATA_WIDTH  = 16,
    parameter ADDR_WIDTH  = 15,
    parameter ARRAY_SIZE  = 4,
    parameter CACHE_DEPTH = 12288
)(
    input  wire clk,
    input  wire rst_n,
    
    // =========================================================================
    // CONFIGURATION (from Controller)
    // =========================================================================
    input  wire [ADDR_WIDTH-1:0] cfg_weight_base,
    input  wire [ADDR_WIDTH-1:0] cfg_bias_base,
    input  wire [9:0]            cfg_out_channels,
    input  wire [9:0]            cfg_num_biases,
    input  wire [9:0]            cfg_weights_per_filter,
    
    // =========================================================================
    // CONTROL
    // =========================================================================
    input  wire start_bias,
    input  wire start_cache,
    input  wire start_stream,
    input  wire stop_stream,
    input  wire next_output_group,
    
    // =========================================================================
    // SYNCHRONIZATION WITH DATA
    // =========================================================================
    input  wire data_valid,
    input  wire data_ready,
    
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
    output reg  cache_done,
    output reg  stream_ready,
    output reg  group_done
);

    // =========================================================================
    // WEIGHT CACHE - 4 banks for parallel access
    // =========================================================================
    (* ram_style = "block" *)
    reg signed [DATA_WIDTH-1:0] cache_bank0 [0:CACHE_DEPTH/4-1];
    reg signed [DATA_WIDTH-1:0] cache_bank1 [0:CACHE_DEPTH/4-1];
    reg signed [DATA_WIDTH-1:0] cache_bank2 [0:CACHE_DEPTH/4-1];
    reg signed [DATA_WIDTH-1:0] cache_bank3 [0:CACHE_DEPTH/4-1];
    
    // =========================================================================
    // STATE MACHINE
    // =========================================================================
    localparam S_IDLE        = 4'd0;
    localparam S_LOAD_BIAS   = 4'd1;
    localparam S_BIAS_READ   = 4'd2;
    localparam S_CACHE_LOAD  = 4'd3;
    localparam S_CACHE_WAIT  = 4'd4;
    localparam S_STREAM_FETCH1 = 4'd5;  // Initiate cache read
    localparam S_STREAM_FETCH2 = 4'd6;  // Wait for cache read
    localparam S_STREAM_HOLD   = 4'd7;  // Hold weights, wait for handshake
    localparam S_GROUP_DONE    = 4'd8;
    
    reg [3:0] state;
    
    // =========================================================================
    // BIAS LOADING
    // =========================================================================
    reg [9:0]  bias_count;
    reg [1:0]  bias_idx;
    reg signed [DATA_WIDTH-1:0] bias_buffer [0:ARRAY_SIZE-1];
    reg        read_pending;
    
    // =========================================================================
    // CACHE LOADING
    // =========================================================================
    reg [15:0] cache_load_count;
    reg [15:0] cache_load_total;
    reg [9:0]  cache_filter_idx;
    reg [9:0]  cache_weight_idx;
    reg [9:0]  weights_per_filter_reg;
    reg [9:0]  out_channels_reg;
    reg [9:0]  total_groups_reg;
    
    // =========================================================================
    // STREAMING FROM CACHE
    // =========================================================================
    reg [9:0]  output_group;
    reg [9:0]  input_idx;
    
    // Bank read
    reg [13:0] bank_rd_addr;
    reg signed [DATA_WIDTH-1:0] weight_rd0, weight_rd1, weight_rd2, weight_rd3;
    
    // =========================================================================
    // MAIN STATE MACHINE
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy <= 0;
            bias_done <= 0;
            cache_done <= 0;
            stream_ready <= 0;
            group_done <= 0;
            weights_valid <= 0;
            bias_valid <= 0;
            rom_addr <= 0;
            
            bias_count <= 0;
            bias_idx <= 0;
            read_pending <= 0;
            
            cache_load_count <= 0;
            cache_load_total <= 0;
            cache_filter_idx <= 0;
            cache_weight_idx <= 0;
            weights_per_filter_reg <= 0;
            out_channels_reg <= 0;
            total_groups_reg <= 0;
            
            output_group <= 0;
            input_idx <= 0;
            bank_rd_addr <= 0;
            
            bias_buffer[0] <= 0;
            bias_buffer[1] <= 0;
            bias_buffer[2] <= 0;
            bias_buffer[3] <= 0;
            weights_out <= 0;
            
        end else begin
            // Default pulse signals
            bias_done <= 0;
            cache_done <= 0;
            group_done <= 0;
            bias_valid <= 0;
            
            case (state)
                // =============================================================
                // IDLE
                // =============================================================
                S_IDLE: begin
                    busy <= 0;
                    stream_ready <= 0;
                    weights_valid <= 0;
                    
                    if (start_bias) begin
                        state <= S_LOAD_BIAS;
                        busy <= 1;
                        bias_count <= 0;
                        bias_idx <= 0;
                        rom_addr <= cfg_bias_base;
                        read_pending <= 1;
                        $display("[WS] Starting bias load: base=%0d, num_biases=%0d", 
                                cfg_bias_base, cfg_num_biases);
                    end else if (start_cache) begin
                        state <= S_CACHE_LOAD;
                        busy <= 1;
                        cache_load_count <= 0;
                        cache_load_total <= cfg_out_channels * cfg_weights_per_filter;
                        cache_filter_idx <= 0;
                        cache_weight_idx <= 0;
                        weights_per_filter_reg <= cfg_weights_per_filter;
                        out_channels_reg <= cfg_out_channels;
                        total_groups_reg <= (cfg_out_channels + ARRAY_SIZE - 1) / ARRAY_SIZE;
                        rom_addr <= cfg_weight_base;
                        $display("[WS] Starting cache load: %0d weights (%0d filters x %0d wpf)",
                                cfg_out_channels * cfg_weights_per_filter,
                                cfg_out_channels, cfg_weights_per_filter);
                    end else if (start_stream) begin
                        state <= S_STREAM_FETCH1;
                        busy <= 1;
                        output_group <= 0;
                        input_idx <= 0;
                        stream_ready <= 1;
                        // Start first cache read
                        bank_rd_addr <= 0;  // group 0, idx 0
                        $display("[WS] Starting stream: wpf=%0d, groups=%0d", 
                                weights_per_filter_reg, total_groups_reg);
                    end
                end
                
                // =============================================================
                // BIAS LOADING
                // =============================================================
                S_LOAD_BIAS: begin
                    if (read_pending) begin
                        state <= S_BIAS_READ;
                    end
                end
                
                S_BIAS_READ: begin
                    read_pending <= 0;
                    bias_buffer[bias_idx] <= rom_data;
                    
                    if (bias_idx == ARRAY_SIZE - 1) begin
                        // Pack and output bias
                        bias_out <= {rom_data, bias_buffer[2], bias_buffer[1], bias_buffer[0]};
                        bias_valid <= 1;
                        bias_idx <= 0;
                        
                        if (bias_count >= cfg_num_biases - 1) begin
                            bias_done <= 1;
                            busy <= 0;
                            state <= S_IDLE;
                            $display("[WS] Bias load complete: count=%0d", bias_count + 1);
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
                
                // =============================================================
                // CACHE LOADING
                // =============================================================
                S_CACHE_LOAD: begin
                    state <= S_CACHE_WAIT;
                end
                
                S_CACHE_WAIT: begin
                    // Store to appropriate bank based on filter index
                    case (cache_filter_idx[1:0])
                        2'd0: cache_bank0[(cache_filter_idx >> 2) * weights_per_filter_reg + cache_weight_idx] <= rom_data;
                        2'd1: cache_bank1[(cache_filter_idx >> 2) * weights_per_filter_reg + cache_weight_idx] <= rom_data;
                        2'd2: cache_bank2[(cache_filter_idx >> 2) * weights_per_filter_reg + cache_weight_idx] <= rom_data;
                        2'd3: cache_bank3[(cache_filter_idx >> 2) * weights_per_filter_reg + cache_weight_idx] <= rom_data;
                    endcase
                    
                    cache_load_count <= cache_load_count + 1;
                    
                    // Advance indices
                    if (cache_weight_idx >= weights_per_filter_reg - 1) begin
                        cache_weight_idx <= 0;
                        cache_filter_idx <= cache_filter_idx + 1;
                    end else begin
                        cache_weight_idx <= cache_weight_idx + 1;
                    end
                    
                    // Check if done
                    if (cache_load_count >= cache_load_total - 1) begin
                        cache_done <= 1;
                        busy <= 0;
                        state <= S_IDLE;
                        $display("[WS] Cache load complete: %0d weights", cache_load_count + 1);
                    end else begin
                        rom_addr <= rom_addr + 1;
                        state <= S_CACHE_LOAD;
                    end
                end
                
                // =============================================================
                // STREAMING FROM CACHE
                // =============================================================
                S_STREAM_FETCH1: begin
                    // Initiate cache read - calculate address
                    bank_rd_addr <= output_group * weights_per_filter_reg + input_idx;
                    state <= S_STREAM_FETCH2;
                    stream_ready <= 1;
                    
                    if (stop_stream) begin
                        state <= S_IDLE;
                        busy <= 0;
                        stream_ready <= 0;
                        weights_valid <= 0;
                    end
                end
                
                S_STREAM_FETCH2: begin
                    // Read from all 4 banks (registered read)
                    weight_rd0 <= cache_bank0[bank_rd_addr];
                    weight_rd1 <= cache_bank1[bank_rd_addr];
                    weight_rd2 <= cache_bank2[bank_rd_addr];
                    weight_rd3 <= cache_bank3[bank_rd_addr];
                    state <= S_STREAM_HOLD;
                    
                    if (stop_stream) begin
                        state <= S_IDLE;
                        busy <= 0;
                        stream_ready <= 0;
                        weights_valid <= 0;
                    end
                end
                
                S_STREAM_HOLD: begin
                    // Output weights and hold until handshake
                    weights_out <= {weight_rd3, weight_rd2, weight_rd1, weight_rd0};
                    weights_valid <= 1;
                    stream_ready <= 1;
                    
                    if (stop_stream) begin
                        state <= S_IDLE;
                        busy <= 0;
                        stream_ready <= 0;
                        weights_valid <= 0;
                    end else if (data_valid && data_ready) begin
                        // Handshake occurred, advance to next weight
                        if (input_idx >= weights_per_filter_reg - 1) begin
                            // Group complete
                            input_idx <= 0;
                            group_done <= 1;
                            weights_valid <= 0;
                            state <= S_GROUP_DONE;
                            // Only print every 32 groups to reduce output
                            if (output_group[4:0] == 5'd31)
                                $display("[WS] Groups 0-%0d complete", output_group);
                        end else begin
                            // Fetch next weight
                            input_idx <= input_idx + 1;
                            state <= S_STREAM_FETCH1;
                        end
                    end
                    // If no handshake, keep holding current weights
                end
                
                S_GROUP_DONE: begin
                    weights_valid <= 0;
                    stream_ready <= 1;
                    
                    if (stop_stream) begin
                        state <= S_IDLE;
                        busy <= 0;
                        stream_ready <= 0;
                    end else if (next_output_group) begin
                        // Advance to next group
                        if (output_group >= total_groups_reg - 1) begin
                            output_group <= 0;
                        end else begin
                            output_group <= output_group + 1;
                        end
                        input_idx <= 0;
                        state <= S_STREAM_FETCH1;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule