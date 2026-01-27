/*
 * RAM to Stream Adapter
 * 
 * Purpose: Convert raw RAM interface to AXI-Stream output
 *          Sequentially reads from RAM and outputs as stream
 *          Supports row repeat for vertical upsampling
 */

`timescale 1ns / 1ps

module ram_to_stream #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 11
)(
    input  wire clk,
    input  wire rst_n,
    
    input  wire [ADDR_WIDTH-1:0] cfg_start_addr,
    input  wire [ADDR_WIDTH-1:0] cfg_length,
    input  wire [ADDR_WIDTH-1:0] cfg_row_length,  // Length of one row (0 = no repeat)
    input  wire                  cfg_row_repeat,  // 1 = repeat each row twice
    
    input  wire start,
    output reg  busy,
    output reg  done,
    
    output reg  [ADDR_WIDTH-1:0] ram_rd_addr,
    input  wire [DATA_WIDTH-1:0] ram_rd_data,
    
    output reg  signed [DATA_WIDTH-1:0] m_axis_tdata,
    output reg                          m_axis_tvalid,
    input  wire                         m_axis_tready
);

    localparam S_IDLE   = 2'd0;
    localparam S_READ   = 2'd1;
    localparam S_WAIT   = 2'd2;  // Wait for RAM latency
    localparam S_VALID  = 2'd3;  // Hold valid until ready
    
    reg [1:0] state;
    reg [ADDR_WIDTH-1:0] count;         // Total output count
    reg [ADDR_WIDTH-1:0] row_count;     // Position within row
    reg [ADDR_WIDTH-1:0] row_start;     // Start address of current row
    reg                  row_pass;       // 0=first pass, 1=second pass (repeat)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            busy         <= 0;
            done         <= 0;
            ram_rd_addr  <= 0;
            m_axis_tdata <= 0;
            m_axis_tvalid<= 0;
            count        <= 0;
            row_count    <= 0;
            row_start    <= 0;
            row_pass     <= 0;
        end else begin
            done <= 0;
            
            case (state)
                S_IDLE: begin
                    busy <= 0;
                    m_axis_tvalid <= 0;
                    
                    if (start) begin
                        state       <= S_READ;
                        busy        <= 1;
                        count       <= 0;
                        row_count   <= 0;
                        row_start   <= cfg_start_addr;
                        row_pass    <= 0;
                        ram_rd_addr <= cfg_start_addr;
                        $display("[R2S] Starting: addr=%0d, len=%0d, row_len=%0d, row_repeat=%0d", 
                                cfg_start_addr, cfg_length, cfg_row_length, cfg_row_repeat);
                    end
                end
                
                S_READ: begin
                    // Address set this cycle, RAM needs 1 cycle
                    state <= S_WAIT;
                end
                
                S_WAIT: begin
                    // RAM data available now, latch it
                    m_axis_tdata  <= ram_rd_data;
                    m_axis_tvalid <= 1;
                    state <= S_VALID;
                end
                
                S_VALID: begin
                    // Hold valid high, wait for ready
                    if (m_axis_tready) begin
                        m_axis_tvalid <= 0;
                        count <= count + 1;
                        
                        // Check if done
                        if (cfg_row_repeat) begin
                            // With row repeat: total output is 2× length
                            if (count >= (cfg_length << 1) - 1) begin
                                state <= S_IDLE;
                                done  <= 1;
                                busy  <= 0;
                            end else begin
                                // Advance within row
                                row_count <= row_count + 1;
                                
                                if (row_count >= cfg_row_length - 1) begin
                                    // End of row
                                    row_count <= 0;
                                    
                                    if (row_pass == 0) begin
                                        // First pass done, repeat same row
                                        row_pass <= 1;
                                        ram_rd_addr <= row_start;
                                    end else begin
                                        // Second pass done, move to next row
                                        row_pass <= 0;
                                        row_start <= row_start + cfg_row_length;
                                        ram_rd_addr <= row_start + cfg_row_length;
                                    end
                                end else begin
                                    // Continue within row
                                    ram_rd_addr <= ram_rd_addr + 1;
                                end
                                state <= S_READ;
                            end
                        end else begin
                            // No row repeat: simple sequential read
                            if (count >= cfg_length - 1) begin
                                state <= S_IDLE;
                                done  <= 1;
                                busy  <= 0;
                            end else begin
                                ram_rd_addr <= cfg_start_addr + count + 1;
                                state       <= S_READ;
                            end
                        end
                    end
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule