/*
 * Simple Streaming Upscaler
 * 
 * Purpose: 2× nearest-neighbor upsampling via simple value duplication
 * 
 * Strategy: 
 *   This upscaler requires the data to be fed TWICE (two passes):
 *   - First pass: outputs each value twice (horizontal duplication)
 *   - Second pass: outputs each value twice again (for second row)
 * 
 * The controller/memory must handle reading the same data twice.
 * This avoids needing a large row buffer.
 * 
 * Simpler alternative: Just duplicate horizontally, let memory
 * handle vertical duplication by reading each row twice.
 */

`timescale 1ns / 1ps

module upscaler_simple #(
    parameter DATA_WIDTH = 16
)(
    input  wire clk,
    input  wire rst_n,
    
    // Configuration  
    input  wire bypass,         // 1=pass through, 0=2× horizontal duplication
    
    // Input interface
    input  wire signed [DATA_WIDTH-1:0] in_data,
    input  wire                         in_valid,
    output wire                         in_ready,
    
    // Output interface
    output reg  signed [DATA_WIDTH-1:0] out_data,
    output reg                          out_valid,
    input  wire                         out_ready
);

    // SIMPLE STATE: just track if we're on first or second output of a pixel    
    reg dup_phase;  // 0=first output, 1=second output (duplicate)
    reg signed [DATA_WIDTH-1:0] held_data;
    reg [15:0] ups_out_cnt;  // Debug counter
    
    // BYPASS MODE
    wire bypass_mode;
    assign bypass_mode = bypass;
    
    // HANDSHAKING
    // In bypass: pass-through handshake
    // In upsample: only ready when we've output the duplicate (dup_phase=1) or idle
    assign in_ready = bypass_mode ? out_ready : 
                      (dup_phase == 0) ? (out_ready && out_valid) || !out_valid : 
                      out_ready;
    
    
    // STATE MACHINE
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data <= 0;
            out_valid <= 0;
            dup_phase <= 0;
            held_data <= 0;
            ups_out_cnt <= 0;
            
        end else if (bypass_mode) begin
            // Simple pass-through
            out_data <= in_data;
            out_valid <= in_valid;
            dup_phase <= 0;
            
            // Debug: track output count in bypass mode
            if (in_valid && out_ready) begin
                ups_out_cnt <= ups_out_cnt + 1;
                if (ups_out_cnt < 3)
                    $display("[UPS] bypass out[%0d] = %0d", ups_out_cnt, $signed(in_data));
            end
            
        end else begin
            // 2× horizontal duplication
            
            if (dup_phase == 0) begin
                // Waiting for or outputting first copy
                if (in_valid && !out_valid) begin
                    // New data arrived, output first copy
                    out_data <= in_data;
                    out_valid <= 1;
                    held_data <= in_data;
                end else if (out_valid && out_ready) begin
                    // First copy consumed, output duplicate
                    out_data <= held_data;
                    out_valid <= 1;
                    dup_phase <= 1;
                end
            end else begin
                // Outputting duplicate
                if (out_ready) begin
                    // Duplicate consumed
                    out_valid <= 0;
                    dup_phase <= 0;
                    
                    // Check for immediate next input
                    if (in_valid) begin
                        out_data <= in_data;
                        out_valid <= 1;
                        held_data <= in_data;
                    end
                end
            end
        end
    end
endmodule