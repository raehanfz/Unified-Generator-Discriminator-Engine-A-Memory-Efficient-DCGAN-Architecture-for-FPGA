`timescale 1ns / 1ps

/*
 * Weight ROM Module (32K capacity - for Generator + Discriminator)
 * 
 * Purpose: Store pre-trained Generator AND Discriminator weights for DCGAN
 * Capacity: 32,768 entries × 16-bit = 512 Kbit
 * Format: Q8.8 fixed-point (8 integer bits, 8 fractional bits)
 * 
 * Memory Layout (nz=24, ngf=8, ndf=4):
 *   GENERATOR (0-28050):
 *     Address 0-12799:     G_FC (Linear) 12,800 params
 *     Address 12800-22047: G_L0 (Conv 32→32) 9,248 params
 *     Address 22048-26671: G_L1 (Conv 32→16) 4,624 params
 *     Address 26672-27831: G_L2 (Conv 16→8) 1,160 params
 *     Address 27832-28050: G_L3 (Conv 8→3) 219 params
 * 
 *   DISCRIMINATOR (28051-31087):
 *     Address 28051-28246: D_L0 (Conv 3→4) 196 params
 *     Address 28247-28766: D_L1 (Conv 4→8) 520 params
 *     Address 28767-30830: D_L2 (Conv 8→16) 2,064 params
 *     Address 30831-31087: D_L3 (Conv 16→1) 257 params
 */

module weight_rom #(
    parameter DATA_WIDTH = 16,      // Fixed-point data width
    parameter DEPTH = 32768,        // 32K entries (was 16K)
    parameter ADDR_WIDTH = 15       // log2(32768) = 15 (was 14)
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire [ADDR_WIDTH-1:0]     addr,       // Read address (15-bit)
    output reg  [DATA_WIDTH-1:0]     data        // Read data (1 cycle latency)
);

    // Weight memory with synthesis attributes for BRAM inference
    (* ram_style = "block" *)      // Xilinx
    (* ramstyle = "M10K" *)        // Intel/Altera
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    
    // Initialize weights from .mem file
    integer i;
    initial begin
        // File contains: G_FC + G_L0-L3 + D_L0-D3
        $readmemh("unified_rom.mem", mem, 0, 31087);
    end
    
    // Synchronous read with registered output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data <= 0;
        end else begin
            data <= mem[addr];
        end
    end

endmodule