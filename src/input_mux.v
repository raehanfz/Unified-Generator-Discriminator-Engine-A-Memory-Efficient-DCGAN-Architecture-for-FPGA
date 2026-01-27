/*
 * Input Multiplexer for Systolic Engine
 * 
 * Purpose: Select between multiple input sources for the systolic engine
 *          Pure selector - no processing, just routing with handshake management
 * 
 * Input Sources:
 *   sel = 0: FC Layer data (Generator fully-connected layer)
 *   sel = 1: Patch data (Convolution layers - from patch_extractor)
 *   sel = 2: Weight data (Weight loading phase)
 * 
 * All sources use AXI-Stream-like handshaking (valid/ready)
 */

`timescale 1ns / 1ps

module input_mux #(
    parameter DATA_WIDTH = 16
)(
    input  wire clk,
    input  wire rst_n,
    
    // =========================================================================
    // SELECTION CONTROL
    // =========================================================================
    input  wire [1:0] sel,  // 0=FC, 1=Patch, 2=Weight
    
    // =========================================================================
    // SOURCE 0: FC Layer Handler
    // =========================================================================
    input  wire signed [DATA_WIDTH-1:0] fc_data,
    input  wire                         fc_valid,
    output wire                         fc_ready,
    
    // =========================================================================
    // SOURCE 1: Patch Extractor
    // =========================================================================
    input  wire signed [DATA_WIDTH-1:0] patch_data,
    input  wire                         patch_valid,
    output wire                         patch_ready,
    
    // =========================================================================
    // SOURCE 2: Weight Streamer
    // =========================================================================
    input  wire signed [DATA_WIDTH-1:0] weight_data,
    input  wire                         weight_valid,
    output wire                         weight_ready,
    input  wire                         weight_load_en,  // Pass through to engine
    
    // =========================================================================
    // OUTPUT: To Systolic Engine
    // =========================================================================
    output wire signed [DATA_WIDTH-1:0] out_data,
    output wire                         out_valid,
    input  wire                         out_ready,
    output wire                         out_load_en      // Weight loading mode
);

    // =========================================================================
    // OUTPUT DATA MUX
    // =========================================================================
    reg signed [DATA_WIDTH-1:0] mux_data;
    reg                         mux_valid;
    reg                         mux_load_en;
    
    always @(*) begin
        case (sel)
            2'd0: begin  // FC Layer
                mux_data    = fc_data;
                mux_valid   = fc_valid;
                mux_load_en = 1'b0;
            end
            2'd1: begin  // Patch Extractor
                mux_data    = patch_data;
                mux_valid   = patch_valid;
                mux_load_en = 1'b0;
            end
            2'd2: begin  // Weight Streamer
                mux_data    = weight_data;
                mux_valid   = weight_valid;
                mux_load_en = weight_load_en;
            end
            default: begin
                mux_data    = {DATA_WIDTH{1'b0}};
                mux_valid   = 1'b0;
                mux_load_en = 1'b0;
            end
        endcase
    end
    
    assign out_data    = mux_data;
    assign out_valid   = mux_valid;
    assign out_load_en = mux_load_en;
    
    // =========================================================================
    // READY SIGNAL ROUTING
    // =========================================================================
    // Only the selected source receives the ready signal
    // Non-selected sources see ready = 0 (blocked)
    
    assign fc_ready     = (sel == 2'd0) ? out_ready : 1'b0;
    assign patch_ready  = (sel == 2'd1) ? out_ready : 1'b0;
    assign weight_ready = (sel == 2'd2) ? out_ready : 1'b0;

endmodule