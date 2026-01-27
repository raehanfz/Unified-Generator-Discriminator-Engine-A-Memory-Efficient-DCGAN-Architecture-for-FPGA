/* 
    description
    BANK CONTROLLER - Automatic Mode 
*/ 

`timescale 1ns / 1ps

module bank_controller #(
    parameter NUM_LAYERS = 4
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // Layer control
    input  wire [2:0]  current_layer,      // 0-3 for 4 layers
    input  wire        layer_start,        // Pulse: layer starts processing
    input  wire        layer_done,         // Pulse: layer completes
    
    // Bank control output
    output reg         active_bank,        // 0=A active, 1=B active
    output reg         bank_switch_ready,  // Safe to switch
    
    // Status/Debug
    output reg         bank_switched,      // Pulse: bank just switched
    output reg  [3:0]  layer_sequence      // Shows layer progression
);

    // State machine
    reg [1:0] state;
    localparam IDLE       = 2'b00;
    localparam PROCESSING = 2'b01;
    localparam SWITCHING  = 2'b10;
    localparam WAIT_READY = 2'b11;
    
    // State machine logic
    always @(posedge clk) begin
        if (!rst_n) begin
            active_bank <= 0;
            bank_switch_ready <= 1;
            layer_sequence <= 0;
            bank_switched <= 0;
            state <= IDLE;
        end else begin
            // Default: no switch pulse
            bank_switched <= 0;
            
            case (state)
                IDLE: begin
                    if (layer_start) begin
                        state <= PROCESSING;
                        layer_sequence <= (1 << current_layer);
                        bank_switch_ready <= 0;
                    end
                end
                
                PROCESSING: begin
                    if (layer_done) begin
                        state <= SWITCHING;
                    end
                end
                
                SWITCHING: begin
                    // Toggle bank for next layer
                    active_bank <= ~active_bank;
                    bank_switched <= 1;  // Pulse
                    state <= WAIT_READY;
                end
                
                WAIT_READY: begin
                    // Wait a few cycles for bank to stabilize
                    bank_switch_ready <= 1;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule