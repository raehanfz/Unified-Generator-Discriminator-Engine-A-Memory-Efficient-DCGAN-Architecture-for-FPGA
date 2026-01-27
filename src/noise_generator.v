`timescale 1ns / 1ps

/*
 * Noise Generator Module (LFSR-based)
 * 
 * Purpose: Generate pseudo-random noise for DCGAN Generator input
 * Method: 16-bit Linear Feedback Shift Register (LFSR)
 * Output: 16-bit noise values when enabled
 * 
 * LFSR Polynomial: x^16 + x^14 + x^13 + x^11 + 1
 * Period: 2^16 - 1 = 65,535 (maximal length)
 * 
 * Note: For DCGAN, we need 16 noise values per inference
 *       Controller will read 16 times with enable=1
 */

module noise_generator #(
    parameter DATA_WIDTH = 16
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      enable,     // Enable noise generation
    input  wire                      seed_load,  // Load new seed
    input  wire [DATA_WIDTH-1:0]     seed_value, // Seed value (optional)
    output reg  [DATA_WIDTH-1:0]     value,      // Noise output
    output reg                       valid       // Output valid signal
);

    // LFSR state register
    reg [DATA_WIDTH-1:0] lfsr;
    
    // LFSR feedback tap positions for maximal-length sequence
    // Taps at positions 16, 14, 13, 11 (counting from 1)
    wire feedback;
    assign feedback = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];
    
    // LFSR update and output generation
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Default seed (non-zero required for LFSR)
            lfsr <= 16'hACE1;
            value <= 16'h0000;
            valid <= 0;
        end else begin
            if (seed_load) begin
                // Load custom seed
                lfsr <= (seed_value != 0) ? seed_value : 16'hACE1;
                valid <= 0;
            end else if (enable) begin
                // Shift LFSR and generate new value
                lfsr <= {lfsr[14:0], feedback};
                
                // Output current LFSR state as noise
                // Apply some mixing for better distribution
                value <= lfsr ^ {lfsr[7:0], lfsr[15:8]};
                valid <= 1;
            end else begin
                valid <= 0;
            end
        end
    end

endmodule