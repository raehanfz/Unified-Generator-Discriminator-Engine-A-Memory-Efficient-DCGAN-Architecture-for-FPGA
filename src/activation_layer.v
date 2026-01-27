/*
    description:
    hold the 4 activation unit
*/

`include "activation_unit.v"
`timescale 1ns / 1ps

module activation_layer #(
    parameter DATA_WIDTH = 16, 
    parameter ACC_WIDTH  = 48, 
    parameter ARRAY_SIZE = 4
)(
    input  wire clk, 
    input  wire rst_n, 
    
    // Input Data (Dari Accumulator)
    input  wire signed [(ARRAY_SIZE*ACC_WIDTH)-1:0] col_in,
    input  wire [ARRAY_SIZE-1:0] col_valid_in, 
    
    input  wire signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] bias_in,

    // Control
    input  wire [1:0] mode,

    // Output Data (Ke Serializer/FIFO)
    output wire signed [(ARRAY_SIZE*DATA_WIDTH)-1:0] col_out,
    output wire [ARRAY_SIZE-1:0] col_valid_out
);

    genvar i;
    generate
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : ACT_GEN
            
            activation_unit #(
                .DATA_WIDTH(DATA_WIDTH),
                .ACC_WIDTH (ACC_WIDTH)
            ) u_unit (
                .clk      (clk),
                .rst_n    (rst_n),
                
                // Mapping Data Per Kolom
                .in_data  (col_in[(i+1)*ACC_WIDTH-1 : i*ACC_WIDTH]), 
                .in_valid (col_valid_in[i]),
                
                // [BARU] Mapping Bias Per Kolom
                // Mengambil irisan 16-bit yang sesuai untuk kolom ke-i
                .bias     (bias_in[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH]),
                
                .mode     (mode),
                
                .out_data (col_out[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH]),
                .out_valid(col_valid_out[i])
            );
            
        end
    endgenerate

endmodule