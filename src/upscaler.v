/*
 * Upscaler
 * 
 * Description:
 *   Upscaler function with nearest neighbour principle
 *   e.g.: input = [x][y]
 *                 [z][w]
 *   e.g.: output = [x][x][y][y]
 *                  [x][x][y][y]
 *                  [z][z][w][w]
 *                  [z][z][w][w]
 */
`timescale 1ns/1ps

module upscaler #(
    parameter DATA_WIDTH = 16,
    parameter MAX_WIDTH  = 64
)(
    input  wire clk,
    input  wire rst_n,
    
    // Configuration
    input  wire [9:0] img_width,    // e.g.: 4 for 4x4, 8 for 8x8, etc.
    input  wire       bypass,       // NEW: 1=pass through, 0=2× upsample
    
    // Input interface
    input  wire signed [DATA_WIDTH-1:0] in_data,
    input  wire in_valid,
    output reg  in_ready,
    
    // Output interface
    output reg  signed [DATA_WIDTH-1:0] out_data,
    output reg  out_valid,
    input  wire out_ready
);

    // States
    localparam S_IDLE        = 3'd0;
    localparam S_OUT_1       = 3'd1; 
    localparam S_OUT_2       = 3'd2;
    localparam S_REPLAY_LOAD = 3'd3;
    localparam S_REPLAY_OUT1 = 3'd4;
    localparam S_REPLAY_OUT2 = 3'd5;
    localparam S_BYPASS      = 3'd6;  // NEW: Bypass state
    
    reg [2:0] state;
    reg [9:0] col_cnt;
    
    // Line buffer for replay
    reg signed [DATA_WIDTH-1:0] line_buffer [0:MAX_WIDTH-1];
    reg signed [DATA_WIDTH-1:0] pix_reg; 
    
    // Ready logic
    always @(*) begin
        if (bypass) begin
            in_ready = out_ready;  // Pass-through handshake
        end else begin
            in_ready = (state == S_IDLE);
        end
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            col_cnt   <= 0;
            out_valid <= 0;
            out_data  <= 0;
            pix_reg   <= 0;
        end else begin
            
            // ============================================================
            // BYPASS MODE - Simple pass-through
            // ============================================================
            if (bypass) begin
                out_data  <= in_data;
                out_valid <= in_valid;
                // in_ready handled in combinational block
                state     <= S_BYPASS;  // Stay in bypass
                col_cnt   <= 0;         // Reset counter
            end
            
            // ============================================================
            // UPSAMPLE MODE - 2× nearest neighbor
            // ============================================================
            else begin
                case (state)
                    S_IDLE: begin
                        out_valid <= 0;
                        
                        if (in_valid) begin
                            pix_reg              <= in_data;
                            line_buffer[col_cnt] <= in_data; 
                            state                <= S_OUT_1;
                        end
                    end
                    
                    S_OUT_1: begin
                        out_data  <= pix_reg;
                        out_valid <= 1;
                        if (out_ready) begin
                            state <= S_OUT_2;
                        end
                    end
                    
                    S_OUT_2: begin
                        out_data  <= pix_reg;
                        out_valid <= 1;
                        if (out_ready) begin
                            out_valid <= 0;
                            
                            if (col_cnt == img_width - 1) begin
                                col_cnt <= 0;
                                state   <= S_REPLAY_LOAD; 
                            end else begin
                                col_cnt <= col_cnt + 1;
                                state   <= S_IDLE;
                            end
                        end
                    end
                    
                    S_REPLAY_LOAD: begin
                        pix_reg   <= line_buffer[col_cnt]; 
                        out_valid <= 0;
                        state     <= S_REPLAY_OUT1;
                    end
                    
                    S_REPLAY_OUT1: begin
                        out_data  <= pix_reg;
                        out_valid <= 1;
                        
                        if (out_ready) begin
                            state <= S_REPLAY_OUT2;
                        end
                    end
                    
                    S_REPLAY_OUT2: begin
                        out_data  <= pix_reg;
                        out_valid <= 1;
                        
                        if (out_ready) begin
                            out_valid <= 0;
                            if (col_cnt == img_width - 1) begin
                                col_cnt <= 0;
                                state   <= S_IDLE;
                            end else begin
                                col_cnt <= col_cnt + 1;
                                state   <= S_REPLAY_LOAD;
                            end
                        end
                    end
                    
                    S_BYPASS: begin
                        // Will transition out when bypass goes low
                        if (!bypass) begin
                            state <= S_IDLE;
                        end
                    end
                    
                    default: state <= S_IDLE;
                endcase
            end
        end
    end
    
endmodule