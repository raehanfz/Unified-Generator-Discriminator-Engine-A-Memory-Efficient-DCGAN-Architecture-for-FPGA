/*
    descriptioon:
    dual bank feature map storage
    it allows smooth write and read process
*/

`timescale 1ns / 1ps

module pingpong_ram #(
    parameter DATA_WIDTH = 16,
    parameter DEPTH = 2048,         // 2K entries per bank (4KB per bank @ 16-bit)
    parameter ADDR_WIDTH = 11
)(
    input  wire                      clk,
    input  wire                      rst_n,
    
    // Bank selection (controlled by bank_controller)
    input  wire                      active_bank,  // 0=A, 1=B
    
    // Write interface (from systolic engine output)
    input  wire [ADDR_WIDTH-1:0]     wr_addr,
    input  wire [DATA_WIDTH-1:0]     wr_data,
    input  wire                      wr_en,
    
    // Read interface (to systolic engine input)
    input  wire [ADDR_WIDTH-1:0]     rd_addr,
    output reg  [DATA_WIDTH-1:0]     rd_data,
    
    // Debug
    output wire [1:0]                bank_status  // [1]=B full, [0]=A full
);

    // Dual-bank storage
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] bank_a [0:DEPTH-1];
    
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] bank_b [0:DEPTH-1];
    
    reg bank_a_valid;
    reg bank_b_valid;
    
    assign bank_status = {bank_b_valid, bank_a_valid};
    
    // Read from inactive bank (while active bank is being written)
    always @(posedge clk) begin
        if (!rst_n) begin
            rd_data <= 0;
        end else begin
            if (active_bank == 0) begin
                // Bank A is active (writing), read from Bank B
                rd_data <= bank_b[rd_addr];
            end else begin
                // Bank B is active (writing), read from Bank A
                rd_data <= bank_a[rd_addr];
            end
        end
    end
    
    // Write to active bank
    always @(posedge clk) begin
        if (!rst_n) begin
            bank_a_valid <= 0;
            bank_b_valid <= 0;
        end else begin
            if (wr_en) begin
                if (active_bank == 0) begin
                    // Write to Bank A
                    bank_a[wr_addr] <= wr_data;
                    bank_a_valid <= 1;
                end else begin
                    // Write to Bank B
                    bank_b[wr_addr] <= wr_data;
                    bank_b_valid <= 1;
                end
            end
        end
    end

endmodule