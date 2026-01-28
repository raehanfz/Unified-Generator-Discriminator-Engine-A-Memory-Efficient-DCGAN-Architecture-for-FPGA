/*
 * Output Multiplexer
 * 
 * Routes systolic engine output to appropriate destination:
 *   - sel=0: To stream_to_ram (intermediate layers → pingpong RAM)
 *   - sel=1: To output_framebuffer (G_L3 final output)
 *   - sel=2: To discriminator output register (D_L3 final output)
 * 
 * AXI-Stream interface on input and outputs.
 * Only the selected output receives valid data and asserts ready back.
 */

`timescale 1ns / 1ps

module output_mux #(
    parameter DATA_WIDTH = 16
)(
    input  wire clk,
    input  wire rst_n,
    
    // =========================================================================
    // SELECTION
    // =========================================================================
    input  wire [1:0] sel,  // 0=RAM, 1=Framebuffer, 2=Discriminator
    
    // =========================================================================
    // INPUT (from systolic engine serializer)
    // =========================================================================
    input  wire signed [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready,
    
    // =========================================================================
    // OUTPUT 0: To stream_to_ram (pingpong RAM)
    // =========================================================================
    output wire signed [DATA_WIDTH-1:0] m0_axis_tdata,
    output wire                         m0_axis_tvalid,
    input  wire                         m0_axis_tready,
    
    // =========================================================================
    // OUTPUT 1: To output_framebuffer
    // =========================================================================
    output wire signed [DATA_WIDTH-1:0] m1_axis_tdata,
    output wire                         m1_axis_tvalid,
    input  wire                         m1_axis_tready,
    
    // =========================================================================
    // OUTPUT 2: Discriminator result (single value)
    // =========================================================================
    output reg  signed [DATA_WIDTH-1:0] disc_result,
    output reg                          disc_result_valid
);

    // =========================================================================
    // DATA ROUTING (directly pass through)
    // =========================================================================
    assign m0_axis_tdata = s_axis_tdata;
    assign m1_axis_tdata = s_axis_tdata;
    
    // =========================================================================
    // VALID ROUTING (only selected output gets valid)
    // =========================================================================
    assign m0_axis_tvalid = (sel == 2'd0) ? s_axis_tvalid : 1'b0;
    assign m1_axis_tvalid = (sel == 2'd1) ? s_axis_tvalid : 1'b0;
    
    // Debug: track framebuffer writes
    reg [15:0] fb_write_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fb_write_cnt <= 0;
        end else begin
            if (sel == 2'd1 && s_axis_tvalid && m1_axis_tready) begin
                fb_write_cnt <= fb_write_cnt + 1;
                if (fb_write_cnt < 4 || fb_write_cnt >= 3068)
                    $display("[OMUX] FB write %0d: val=%0d", fb_write_cnt, $signed(s_axis_tdata));
            end
        end
    end
    
    // =========================================================================
    // READY ROUTING (only selected output's ready propagates back)
    // =========================================================================
    assign s_axis_tready = (sel == 2'd0) ? m0_axis_tready :
                           (sel == 2'd1) ? m1_axis_tready :
                           (sel == 2'd2) ? 1'b1 :  // Always ready for disc output
                           1'b0;
    
    // =========================================================================
    // DISCRIMINATOR OUTPUT CAPTURE
    // Latches the result - stays valid until next inference starts
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            disc_result       <= 0;
            disc_result_valid <= 0;
        end else begin
            // Capture and latch when discriminator result arrives
            if (sel == 2'd2 && s_axis_tvalid) begin
                disc_result       <= s_axis_tdata;
                disc_result_valid <= 1;
                $display("[DISC] Captured result: %0d (0x%04h)", $signed(s_axis_tdata), s_axis_tdata);
            end
            // Note: disc_result_valid stays high until reset
            // In real usage, controller would clear it when starting new inference
        end
    end

endmodule