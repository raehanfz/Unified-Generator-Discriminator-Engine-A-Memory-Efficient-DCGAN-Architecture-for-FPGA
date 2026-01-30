`timescale 1ns / 1ps

module weight_streamer_cached #(
    parameter DATA_WIDTH  = 16,
    parameter ADDR_WIDTH  = 15,
    parameter ARRAY_SIZE  = 4,
    parameter CACHE_DEPTH = 12288
)(
    input  wire clk,
    input  wire rst_n,
    
    // CONFIGURATION
    input  wire [ADDR_WIDTH-1:0] cfg_weight_base,
    input  wire [ADDR_WIDTH-1:0] cfg_bias_base,
    input  wire [9:0]            cfg_out_channels,
    input  wire [9:0]            cfg_num_biases,
    input  wire [9:0]            cfg_weights_per_filter,
    
    // CONTROL
    input  wire start_bias,
    input  wire start_cache,
    input  wire start_stream,
    input  wire stop_stream,
    input  wire next_output_group,
    
    // SYNCHRONIZATION
    input  wire data_valid,
    input  wire data_ready,
    
    // ROM INTERFACE
    output reg  [ADDR_WIDTH-1:0] rom_addr,
    input  wire [DATA_WIDTH-1:0] rom_data,
    
    // WEIGHT OUTPUT
    output reg  signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] weights_out,
    output reg                                       weights_valid,
    
    // BIAS OUTPUT
    output reg  signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] bias_out,
    output reg                                       bias_valid,
    
    // STATUS
    output reg  busy,
    output reg  bias_done,
    output reg  cache_done,
    output reg  stream_ready,
    output reg  group_done
);
    // WEIGHT CACHE - 4 banks for BRAM Inference
    (* ram_style = "block" *)
    reg signed [DATA_WIDTH-1:0] cache_bank0 [0:CACHE_DEPTH/4-1];
    reg signed [DATA_WIDTH-1:0] cache_bank1 [0:CACHE_DEPTH/4-1];
    reg signed [DATA_WIDTH-1:0] cache_bank2 [0:CACHE_DEPTH/4-1];
    reg signed [DATA_WIDTH-1:0] cache_bank3 [0:CACHE_DEPTH/4-1];
    
    
    // STATE MACHINE & REGISTERS
    localparam S_IDLE          = 4'd0;
    localparam S_LOAD_BIAS     = 4'd1;
    localparam S_BIAS_READ     = 4'd2;
    localparam S_CACHE_LOAD    = 4'd3;
    localparam S_CACHE_WAIT    = 4'd4;
    localparam S_STREAM_FETCH1 = 4'd5;
    localparam S_STREAM_FETCH2 = 4'd6;
    localparam S_STREAM_HOLD   = 4'd7;
    localparam S_GROUP_DONE    = 4'd8;
    
    reg [3:0] state;
    reg [9:0] bias_count;
    reg [1:0] bias_idx;
    reg signed [DATA_WIDTH-1:0] bias_buffer [0:ARRAY_SIZE-1];
    reg read_pending;
    
    reg [15:0] cache_load_count;
    reg [15:0] cache_load_total;
    reg [9:0]  cache_filter_idx;
    reg [9:0]  cache_weight_idx;
    reg [9:0]  weights_per_filter_reg;
    reg [9:0]  total_groups_reg;
    
    reg [9:0]  output_group;
    reg [9:0]  input_idx;
    reg [13:0] bank_rd_addr;
    
    reg signed [DATA_WIDTH-1:0] weight_rd0, weight_rd1, weight_rd2, weight_rd3;

    
    // BRAM WRITE LOGIC (NO RESET)
    // Separating the write port enables BRAM inference.
    wire [13:0] current_cache_addr = (cache_filter_idx >> 2) * weights_per_filter_reg + cache_weight_idx;
    
    always @(posedge clk) begin
        if (state == S_CACHE_WAIT) begin
            case (cache_filter_idx[1:0])
                2'd0: cache_bank0[current_cache_addr] <= rom_data;
                2'd1: cache_bank1[current_cache_addr] <= rom_data;
                2'd2: cache_bank2[current_cache_addr] <= rom_data;
                2'd3: cache_bank3[current_cache_addr] <= rom_data;
            endcase
        end
    end

    // CONTROL LOGIC (WITH RESET)
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
            total_groups_reg <= 0;
            output_group <= 0;
            input_idx <= 0;
            bank_rd_addr <= 0;
            weights_out <= 0;
            bias_out <= 0;
            bias_buffer[0] <= 0; bias_buffer[1] <= 0; bias_buffer[2] <= 0; bias_buffer[3] <= 0;
        end else begin
            bias_done <= 0;
            cache_done <= 0;
            group_done <= 0;
            bias_valid <= 0;

            case (state)
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
                    end else if (start_cache) begin
                        state <= S_CACHE_LOAD;
                        busy <= 1;
                        cache_load_count <= 0;
                        cache_load_total <= cfg_out_channels * cfg_weights_per_filter;
                        cache_filter_idx <= 0;
                        cache_weight_idx <= 0;
                        weights_per_filter_reg <= cfg_weights_per_filter;
                        total_groups_reg <= (cfg_out_channels + ARRAY_SIZE - 1) / ARRAY_SIZE;
                        rom_addr <= cfg_weight_base;
                    end else if (start_stream) begin
                        state <= S_STREAM_FETCH1;
                        busy <= 1;
                        output_group <= 0;
                        input_idx <= 0;
                        stream_ready <= 1;
                        bank_rd_addr <= 0;
                    end
                end

                S_LOAD_BIAS: if (read_pending) state <= S_BIAS_READ;

                S_BIAS_READ: begin
                    read_pending <= 0;
                    bias_buffer[bias_idx] <= rom_data;
                    if (bias_idx == ARRAY_SIZE - 1) begin
                        bias_out <= {rom_data, bias_buffer[2], bias_buffer[1], bias_buffer[0]};
                        bias_valid <= 1;
                        bias_idx <= 0;
                        if (bias_count >= cfg_num_biases - 1) begin
                            bias_done <= 1; busy <= 0; state <= S_IDLE;
                        end else begin
                            bias_count <= bias_count + 1;
                            rom_addr <= cfg_bias_base + bias_count + 1;
                            read_pending <= 1; state <= S_LOAD_BIAS;
                        end
                    end else begin
                        bias_idx <= bias_idx + 1;
                        bias_count <= bias_count + 1;
                        rom_addr <= cfg_bias_base + bias_count + 1;
                        read_pending <= 1; state <= S_LOAD_BIAS;
                    end
                end

                S_CACHE_LOAD: state <= S_CACHE_WAIT;

                S_CACHE_WAIT: begin
                    cache_load_count <= cache_load_count + 1;
                    if (cache_weight_idx >= weights_per_filter_reg - 1) begin
                        cache_weight_idx <= 0;
                        cache_filter_idx <= cache_filter_idx + 1;
                    end else begin
                        cache_weight_idx <= cache_weight_idx + 1;
                    end

                    if (cache_load_count >= cache_load_total - 1) begin
                        cache_done <= 1; busy <= 0; state <= S_IDLE;
                    end else begin
                        rom_addr <= rom_addr + 1; state <= S_CACHE_LOAD;
                    end
                end

                S_STREAM_FETCH1: begin
                    bank_rd_addr <= output_group * weights_per_filter_reg + input_idx;
                    state <= S_STREAM_FETCH2;
                    stream_ready <= 1;
                    if (stop_stream) begin state <= S_IDLE; busy <= 0; stream_ready <= 0; weights_valid <= 0; end
                end

                S_STREAM_FETCH2: begin
                    weight_rd0 <= cache_bank0[bank_rd_addr];
                    weight_rd1 <= cache_bank1[bank_rd_addr];
                    weight_rd2 <= cache_bank2[bank_rd_addr];
                    weight_rd3 <= cache_bank3[bank_rd_addr];
                    state <= S_STREAM_HOLD;
                    if (stop_stream) begin state <= S_IDLE; busy <= 0; stream_ready <= 0; weights_valid <= 0; end
                end

                S_STREAM_HOLD: begin
                    weights_out <= {weight_rd3, weight_rd2, weight_rd1, weight_rd0};
                    weights_valid <= 1;
                    stream_ready <= 1;
                    if (stop_stream) begin
                        state <= S_IDLE; busy <= 0; stream_ready <= 0; weights_valid <= 0;
                    end else if (data_valid && data_ready) begin
                        if (input_idx >= weights_per_filter_reg - 1) begin
                            input_idx <= 0; group_done <= 1; weights_valid <= 0; state <= S_GROUP_DONE;
                        end else begin
                            input_idx <= input_idx + 1; state <= S_STREAM_FETCH1;
                        end
                    end
                end

                S_GROUP_DONE: begin
                    weights_valid <= 0; stream_ready <= 1;
                    if (stop_stream) begin
                        state <= S_IDLE; busy <= 0; stream_ready <= 0;
                    end else if (next_output_group) begin
                        output_group <= (output_group >= total_groups_reg - 1) ? 0 : output_group + 1;
                        input_idx <= 0; state <= S_STREAM_FETCH1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule