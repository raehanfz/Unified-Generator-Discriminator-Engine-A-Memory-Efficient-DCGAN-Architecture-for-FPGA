`timescale 1ns / 1ps

module pingpong_ram #(
    parameter DATA_WIDTH = 16,
    parameter DEPTH = 2048,
    parameter ADDR_WIDTH = 11
)(
    input  wire                      clk,
    input  wire                      rst_n,
    
    // Bank selection (controlled by bank_controller)
    input  wire                      active_bank,  // 0=A, 1=B
    
    // Write interface
    input  wire [ADDR_WIDTH-1:0]     wr_addr,
    input  wire [DATA_WIDTH-1:0]     wr_data,
    input  wire                      wr_en,
    
    // Read interface
    input  wire [ADDR_WIDTH-1:0]     rd_addr,
    output reg  [DATA_WIDTH-1:0]     rd_data,
    
    // Debug
    output wire [1:0]                bank_status
);
    // DUAL-BANK STORAGE (BRAM Inference - No Reset)
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] bank_a [0:DEPTH-1];
    
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] bank_b [0:DEPTH-1];

    // MESSAGE: Dedicated write block without rst_n allows BRAM mapping.
    always @(posedge clk) begin
        if (wr_en) begin
            if (active_bank == 0) begin
                bank_a[wr_addr] <= wr_data;
            end else begin
                bank_b[wr_addr] <= wr_data;
            end
        end
    end

    // MESSAGE: Dedicated read block.
    always @(posedge clk) begin
        if (active_bank == 0) begin
            rd_data <= bank_b[rd_addr];
        end else begin
            rd_data <= bank_a[rd_addr];
        end
    end

    
    // STATUS & CONTROL LOGIC (With Reset)
    reg bank_a_valid;
    reg bank_b_valid;
    
    assign bank_status = {bank_b_valid, bank_a_valid};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_a_valid <= 0;
            bank_b_valid <= 0;
        end else begin
            if (wr_en) begin
                if (active_bank == 0) begin
                    bank_a_valid <= 1;
                end else begin
                    bank_b_valid <= 1;
                end
            end
        end
    end

endmodule