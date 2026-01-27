/*
 * FC Layer Handler
 * 
 * Purpose: Handle the Generator's fully connected layer (G_FC)
 *          Converts 24-element noise vector to 512 outputs (32×4×4)
 * 
 * The FC layer is fundamentally different from conv layers:
 *   - Input: 24 values (latent vector)
 *   - Output: 512 values (reshaped to 32 channels × 4×4 spatial)
 *   - Operation: Matrix multiply (24×512 weights)
 * 
 * Strategy:
 *   - Process 4 outputs at a time (matches 4-wide systolic array)
 *   - For each group of 4 outputs: stream all 24 inputs, accumulate
 *   - Repeat 128 times (512/4 = 128 groups)
 * 
 * Interface:
 *   - Receives 24-element noise vector
 *   - Streams input 24 times per output group (for weight loading)
 *   - Outputs 512 values as stream
 */

`timescale 1ns / 1ps

module fc_layer_handler #(
    parameter DATA_WIDTH   = 16,
    parameter INPUT_LEN    = 24,    // Latent vector size (nz)
    parameter OUTPUT_LEN   = 512,   // Output features (ngf*4 * 4 * 4)
    parameter ARRAY_SIZE   = 4
)(
    input  wire clk,
    input  wire rst_n,
    
    // =========================================================================
    // NOISE INPUT (from noise_generator)
    // =========================================================================
    input  wire signed [DATA_WIDTH-1:0] noise_data,
    input  wire                         noise_valid,
    output wire                         noise_ready,
    
    // =========================================================================
    // CONTROL
    // =========================================================================
    input  wire start,              // Pulse to begin FC layer processing
    output reg  busy,
    output reg  done,
    
    // =========================================================================
    // TO SYSTOLIC ENGINE
    // =========================================================================
    output reg  signed [DATA_WIDTH-1:0] fc_data_out,
    output reg                          fc_valid_out,
    input  wire                         fc_ready_in,
    
    // =========================================================================
    // CONFIGURATION (tells engine this is FC mode)
    // =========================================================================
    output reg                          fc_mode_active
);

    // =========================================================================
    // NOISE BUFFER
    // =========================================================================
    // Store all 24 noise values so we can replay them 128 times
    reg signed [DATA_WIDTH-1:0] noise_buffer [0:INPUT_LEN-1];
    reg [4:0] noise_load_idx;
    reg       noise_loaded;
    
    // =========================================================================
    // STATE MACHINE
    // =========================================================================
    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_NOISE = 3'd1;
    localparam S_PROCESS    = 3'd2;
    localparam S_WAIT_READY = 3'd3;
    localparam S_DONE       = 3'd4;
    
    reg [2:0] state;
    
    // =========================================================================
    // PROCESSING COUNTERS
    // =========================================================================
    reg [7:0]  output_group;     // Which group of 4 outputs (0 to 127)
    reg [4:0]  input_idx;        // Which input being sent (0 to 23)
    reg [9:0]  total_outputs;    // Total outputs generated
    
    // =========================================================================
    // READY SIGNAL
    // =========================================================================
    assign noise_ready = (state == S_LOAD_NOISE);
    
    // =========================================================================
    // MAIN STATE MACHINE
    // =========================================================================
    integer i;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            busy           <= 0;
            done           <= 0;
            fc_data_out    <= 0;
            fc_valid_out   <= 0;
            fc_mode_active <= 0;
            
            noise_load_idx <= 0;
            noise_loaded   <= 0;
            output_group   <= 0;
            input_idx      <= 0;
            total_outputs  <= 0;
            
            for (i = 0; i < INPUT_LEN; i = i + 1) begin
                noise_buffer[i] <= 0;
            end
            
        end else begin
            // Default: clear done pulse
            done <= 0;
            
            case (state)
                // ---------------------------------------------------------
                S_IDLE: begin
                    busy           <= 0;
                    fc_valid_out   <= 0;
                    fc_mode_active <= 0;
                    
                    if (start) begin
                        state          <= S_LOAD_NOISE;
                        busy           <= 1;
                        fc_mode_active <= 1;
                        noise_load_idx <= 0;
                        noise_loaded   <= 0;
                    end
                end
                
                // ---------------------------------------------------------
                S_LOAD_NOISE: begin
                    // Load all 24 noise values into buffer
                    if (noise_valid && noise_ready) begin
                        noise_buffer[noise_load_idx] <= noise_data;
                        
                        if (noise_load_idx == INPUT_LEN - 1) begin
                            noise_loaded  <= 1;
                            noise_load_idx<= 0;
                            output_group  <= 0;
                            input_idx     <= 0;
                            total_outputs <= 0;
                            state         <= S_PROCESS;
                        end else begin
                            noise_load_idx <= noise_load_idx + 1;
                        end
                    end
                end
                
                // ---------------------------------------------------------
                S_PROCESS: begin
                    // Stream noise values to systolic engine
                    // For each output group, send all 24 inputs
                    
                    fc_data_out  <= noise_buffer[input_idx];
                    fc_valid_out <= 1;
                    state        <= S_WAIT_READY;
                end
                
                // ---------------------------------------------------------
                S_WAIT_READY: begin
                    if (fc_ready_in) begin
                        fc_valid_out <= 0;
                        
                        if (input_idx == INPUT_LEN - 1) begin
                            // Finished one output group
                            input_idx <= 0;
                            
                            if (output_group == (OUTPUT_LEN / ARRAY_SIZE) - 1) begin
                                // All output groups done
                                state <= S_DONE;
                            end else begin
                                output_group <= output_group + 1;
                                state        <= S_PROCESS;
                            end
                        end else begin
                            input_idx <= input_idx + 1;
                            state     <= S_PROCESS;
                        end
                    end
                end
                
                // ---------------------------------------------------------
                S_DONE: begin
                    done           <= 1;
                    busy           <= 0;
                    fc_valid_out   <= 0;
                    fc_mode_active <= 0;
                    state          <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule