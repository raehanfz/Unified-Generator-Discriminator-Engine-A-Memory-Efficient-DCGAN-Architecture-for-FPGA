/*
 * Compute Engine (Simple Version)
 * 
 * Purpose: Perform actual MAC operations for DCGAN inference
 *          Replaces systolic_engine_stub with real computation
 * 
 * Architecture:
 *   - 4 parallel MAC units (matches ARRAY_SIZE=4)
 *   - 48-bit accumulators to prevent overflow
 *   - Integrated activation (ReLU, LeakyReLU, Linear)
 *   - Sequential output (4 results over 4 cycles)
 * 
 * Fixed-Point Format:
 *   - Input data:   Q8.8 (16-bit)
 *   - Weights:      Q8.8 (16-bit)
 *   - Product:      Q16.16 (32-bit, sign-extended to 48-bit)
 *   - Accumulator:  Q32.16 (48-bit)
 *   - Output:       Q8.8 (16-bit after saturation)
 * 
 * Operation:
 *   1. Receive (data, 4 weights) pairs synchronized
 *   2. Multiply data × weight for each of 4 outputs
 *   3. Accumulate until acc_limit reached
 *   4. Add bias, apply activation, output 4 values
 *   5. Reset accumulators, continue next group
 */

`timescale 1ns / 1ps

`include "activation_unit.v"

module compute_engine #(
    parameter DATA_WIDTH  = 16,
    parameter ACC_WIDTH   = 48,
    parameter ARRAY_SIZE  = 4
)(
    input  wire clk,
    input  wire rst_n,
    
    // =========================================================================
    // CONFIGURATION
    // =========================================================================
    input  wire        mode_discriminator,  // 0=Generator, 1=Discriminator
    input  wire [9:0]  acc_limit,           // MACs per output (24 for FC, K²×C for conv)
    input  wire signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] bias_in,  // 4 biases packed
    input  wire [1:0]  activation_mode,     // 0=Linear, 1=ReLU, 2=LeakyReLU
    
    // =========================================================================
    // DATA INPUT (from input_mux)
    // =========================================================================
    input  wire signed [DATA_WIDTH-1:0] data_in,
    input  wire                         data_valid,
    output wire                         data_ready,
    
    // =========================================================================
    // WEIGHT INPUT (from weight_streamer)
    // =========================================================================
    input  wire signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] weights_in,
    input  wire                                      weights_valid,
    
    // =========================================================================
    // OUTPUT (to output_mux)
    // =========================================================================
    output reg  signed [DATA_WIDTH-1:0] result_out,
    output reg                          result_valid,
    input  wire                         result_ready,
    
    // =========================================================================
    // STATUS & DEBUG
    // =========================================================================
    output wire busy,
    output reg  [31:0] debug_mac_count,
    output reg  [31:0] debug_output_count
);

    // =========================================================================
    // STATE MACHINE
    // =========================================================================
    localparam S_IDLE       = 3'd0;
    localparam S_COMPUTE    = 3'd1;
    localparam S_ACTIVATE   = 3'd2;
    localparam S_OUTPUT     = 3'd3;
    localparam S_NEXT       = 3'd4;
    
    reg [2:0] state;
    
    // =========================================================================
    // COUNTERS
    // =========================================================================
    reg [9:0]  mac_count;       // Current MAC (0 to acc_limit-1)
    reg [1:0]  output_idx;      // Which output being sent (0-3)
    
    // =========================================================================
    // ACCUMULATORS (48-bit to handle overflow)
    // =========================================================================
    reg signed [ACC_WIDTH-1:0] acc [0:ARRAY_SIZE-1];
    
    // =========================================================================
    // WEIGHT UNPACKING
    // =========================================================================
    wire signed [DATA_WIDTH-1:0] w [0:ARRAY_SIZE-1];
    assign w[0] = weights_in[DATA_WIDTH-1:0];
    assign w[1] = weights_in[2*DATA_WIDTH-1:DATA_WIDTH];
    assign w[2] = weights_in[3*DATA_WIDTH-1:2*DATA_WIDTH];
    assign w[3] = weights_in[4*DATA_WIDTH-1:3*DATA_WIDTH];
    
    // =========================================================================
    // BIAS UNPACKING
    // =========================================================================
    wire signed [DATA_WIDTH-1:0] b [0:ARRAY_SIZE-1];
    assign b[0] = bias_in[DATA_WIDTH-1:0];
    assign b[1] = bias_in[2*DATA_WIDTH-1:DATA_WIDTH];
    assign b[2] = bias_in[3*DATA_WIDTH-1:2*DATA_WIDTH];
    assign b[3] = bias_in[4*DATA_WIDTH-1:3*DATA_WIDTH];
    
    // =========================================================================
    // MAC PRODUCTS (32-bit, sign-extended to 48-bit)
    // =========================================================================
    wire signed [31:0] product [0:ARRAY_SIZE-1];
    wire signed [ACC_WIDTH-1:0] product_ext [0:ARRAY_SIZE-1];
    
    genvar g;
    generate
        for (g = 0; g < ARRAY_SIZE; g = g + 1) begin : MAC_GEN
            assign product[g] = data_in * w[g];  // Q8.8 × Q8.8 = Q16.16
            assign product_ext[g] = {{16{product[g][31]}}, product[g]};  // Sign extend to 48-bit
        end
    endgenerate
    
    // =========================================================================
    // ACTIVATION UNITS (4 parallel)
    // =========================================================================
    reg  act_trigger;
    wire signed [DATA_WIDTH-1:0] act_out [0:ARRAY_SIZE-1];
    wire act_valid [0:ARRAY_SIZE-1];
    
    generate
        for (g = 0; g < ARRAY_SIZE; g = g + 1) begin : ACT_GEN
            activation_unit #(
                .DATA_WIDTH(DATA_WIDTH),
                .ACC_WIDTH(ACC_WIDTH)
            ) u_act (
                .clk      (clk),
                .rst_n    (rst_n),
                .in_data  (acc[g]),
                .in_valid (act_trigger),
                .bias     (b[g]),
                .mode     (activation_mode),
                .out_data (act_out[g]),
                .out_valid(act_valid[g])
            );
        end
    endgenerate
    
    // =========================================================================
    // HANDSHAKING
    // =========================================================================
    wire both_valid;
    assign both_valid = data_valid && weights_valid;
    
    // Ready only when computing AND weights available
    assign data_ready = ((state == S_COMPUTE) || (state == S_IDLE)) && weights_valid;
    
    assign busy = (state != S_IDLE);
    
    // =========================================================================
    // MAIN STATE MACHINE
    // =========================================================================
    integer i;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            mac_count <= 0;
            output_idx <= 0;
            result_out <= 0;
            result_valid <= 0;
            act_trigger <= 0;
            
            debug_mac_count <= 0;
            debug_output_count <= 0;
            
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                acc[i] <= 0;
            end
            
        end else begin
            // Default
            result_valid <= 0;
            act_trigger <= 0;
            
            case (state)
                // ---------------------------------------------------------
                S_IDLE: begin
                    mac_count <= 0;
                    output_idx <= 0;
                    
                    // Clear accumulators
                    for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                        acc[i] <= 0;
                    end
                    
                    // Start computing when first valid data+weights arrive
                    if (both_valid) begin
                        state <= S_COMPUTE;
                        
                        // Debug: first data input
                        $display("[CE] IN[0] = %0d (0x%04h)", $signed(data_in), data_in);
                        
                        // First MAC
                        acc[0] <= product_ext[0];
                        acc[1] <= product_ext[1];
                        acc[2] <= product_ext[2];
                        acc[3] <= product_ext[3];
                        mac_count <= 1;
                        debug_mac_count <= debug_mac_count + 1;
                    end
                end
                
                // ---------------------------------------------------------
                S_COMPUTE: begin
                    if (both_valid) begin
                        // Accumulate
                        acc[0] <= acc[0] + product_ext[0];
                        acc[1] <= acc[1] + product_ext[1];
                        acc[2] <= acc[2] + product_ext[2];
                        acc[3] <= acc[3] + product_ext[3];
                        
                        mac_count <= mac_count + 1;
                        debug_mac_count <= debug_mac_count + 1;
                        
                        // Check if group complete
                        if (mac_count >= acc_limit - 1) begin
                            state <= S_ACTIVATE;
                            act_trigger <= 1;  // Trigger activation units
                        end
                    end
                end
                
                // ---------------------------------------------------------
                S_ACTIVATE: begin
                    // Wait 1 cycle for activation pipeline
                    // Activation units have 1-cycle latency
                    if (act_valid[0]) begin
                        state <= S_OUTPUT;
                        output_idx <= 0;
                    end
                end
                
                // ---------------------------------------------------------
                S_OUTPUT: begin
                    // Output activated results sequentially
                    result_valid <= 1;
                    
                    case (output_idx)
                        2'd0: result_out <= act_out[0];
                        2'd1: result_out <= act_out[1];
                        2'd2: result_out <= act_out[2];
                        2'd3: result_out <= act_out[3];
                    endcase
                    
                    if (result_ready) begin
                        // Debug: first 4 outputs (one group)
                        if (debug_output_count < 4) begin
                            case (output_idx)
                                2'd0: $display("[CE] OUT[%0d] = %0d", debug_output_count, $signed(act_out[0]));
                                2'd1: $display("[CE] OUT[%0d] = %0d", debug_output_count, $signed(act_out[1]));
                                2'd2: $display("[CE] OUT[%0d] = %0d", debug_output_count, $signed(act_out[2]));
                                2'd3: $display("[CE] OUT[%0d] = %0d", debug_output_count, $signed(act_out[3]));
                            endcase
                        end
                        
                        debug_output_count <= debug_output_count + 1;
                        
                        if (output_idx == ARRAY_SIZE - 1) begin
                            // All 4 outputs sent
                            state <= S_NEXT;
                        end else begin
                            output_idx <= output_idx + 1;
                        end
                    end
                end
                
                // ---------------------------------------------------------
                S_NEXT: begin
                    // Reset for next group
                    mac_count <= 0;
                    output_idx <= 0;
                    result_valid <= 0;
                    
                    // Clear accumulators
                    for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                        acc[i] <= 0;
                    end
                    
                    // Immediately start next group if data available
                    if (both_valid) begin
                        state <= S_COMPUTE;
                        
                        // First MAC of new group
                        acc[0] <= product_ext[0];
                        acc[1] <= product_ext[1];
                        acc[2] <= product_ext[2];
                        acc[3] <= product_ext[3];
                        mac_count <= 1;
                        debug_mac_count <= debug_mac_count + 1;
                    end else begin
                        state <= S_IDLE;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule