/*
 * Stream to RAM Adapter
 * 
 * Purpose: Convert AXI-Stream input to raw RAM write interface
 *          Receives stream data and writes sequentially to RAM
 * 
 * Debug note: After completing configured length, goes to S_DRAIN
 *             which keeps accepting data without blocking upstream
 */

`timescale 1ns / 1ps

module stream_to_ram #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 11
)(
    input  wire clk,
    input  wire rst_n,
    
    input  wire [ADDR_WIDTH-1:0] cfg_start_addr,
    input  wire [ADDR_WIDTH-1:0] cfg_length,
    
    input  wire start,
    output reg  busy,
    output reg  done,
    
    input  wire signed [DATA_WIDTH-1:0] s_axis_tdata,
    input  wire                         s_axis_tvalid,
    output reg                          s_axis_tready,
    
    output reg  [ADDR_WIDTH-1:0] ram_wr_addr,
    output reg  [DATA_WIDTH-1:0] ram_wr_data,
    output reg                   ram_wr_en
);

    localparam S_IDLE  = 2'd0;
    localparam S_WRITE = 2'd1;
    localparam S_DONE  = 2'd2;
    localparam S_DRAIN = 2'd3;
    
    reg [1:0] state;
    reg [ADDR_WIDTH-1:0] write_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            busy          <= 0;
            done          <= 0;
            s_axis_tready <= 0;
            ram_wr_addr   <= 0;
            ram_wr_data   <= 0;
            ram_wr_en     <= 0;
            write_count   <= 0;
        end else begin
            done      <= 0;
            ram_wr_en <= 0;
            
            case (state)
                S_IDLE: begin
                    busy          <= 0;
                    s_axis_tready <= 0;
                    
                    if (start) begin
                        state         <= S_WRITE;
                        busy          <= 1;
                        write_count   <= 0;
                        s_axis_tready <= 1;
                    end
                end
                
                S_WRITE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        ram_wr_addr <= cfg_start_addr + write_count;
                        ram_wr_data <= s_axis_tdata;
                        ram_wr_en   <= 1;
                        write_count <= write_count + 1;
                        
                        if (write_count >= cfg_length - 1) begin
                            state <= S_DONE;
                        end
                    end
                end
                
                S_DONE: begin
                    done  <= 1;
                    busy  <= 0;
                    // Keep ready high to drain extra data
                    s_axis_tready <= 1;
                    state <= S_DRAIN;
                end
                
                S_DRAIN: begin
                    // Accept and discard - don't block upstream
                    // Wait for new start to begin fresh transfer
                    s_axis_tready <= 1;
                    if (start) begin
                        state         <= S_WRITE;
                        busy          <= 1;
                        write_count   <= 0;
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule