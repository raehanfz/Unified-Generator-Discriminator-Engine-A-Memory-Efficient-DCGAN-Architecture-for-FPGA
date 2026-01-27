/*
    description:
    given sum from accumulator, perform activation function
*/

`timescale 1ns / 1ps

module activation_unit #(
    parameter DATA_WIDTH = 16, // Q8.8
    parameter ACC_WIDTH  = 48  // Input dari Accumulator (Qxx.16)
)(
    input  wire clk, rst_n,
    input  wire signed [ACC_WIDTH-1:0] in_data,
    input  wire in_valid,
    
    // [BARU] Input Bias Q8.8
    input  wire signed [DATA_WIDTH-1:0] bias, 
    
    input  wire [1:0] mode, // 0:Linear, 1:ReLU, 2:LeakyReLU
    
    output reg  signed [DATA_WIDTH-1:0] out_data,
    output reg  out_valid
);

    // Q8.8 Constants
    localparam signed [DATA_WIDTH-1:0] MAX_VAL = 16'h7FFF;
    localparam signed [DATA_WIDTH-1:0] MIN_VAL = 16'h8000;

    // --- LOGIC PENJUMLAHAN BIAS ---
    // Accumulator format: Q(Int).16 (LSB ada di bit 0, bernilai 2^-16)
    // Bias format:        Q8.8      (LSB ada di bit 0, bernilai 2^-8)
    // Agar bisa dijumlahkan, Bias harus digeser ke kiri 8 bit (dikali 256).
    // Structure: [Sign Ext 24-bit] [Bias 16-bit] [Zero Pad 8-bit] = 48-bit
    
    wire signed [ACC_WIDTH-1:0] bias_expanded;
    assign bias_expanded = { {24{bias[DATA_WIDTH-1]}}, bias, 8'd0 };

    wire signed [ACC_WIDTH-1:0] data_biased;
    assign data_biased = in_data + bias_expanded;

    // --- SLICING & SATURATION (Menggunakan data_biased) ---
    // Kita mengambil bit [23:8] dari hasil penjumlahan
    wire sign_bit = data_biased[ACC_WIDTH-1];
    wire [24:0] upper_check = data_biased[47:23]; 
    wire signed [DATA_WIDTH-1:0] sliced_val = data_biased[23:8];

    reg overflow_pos, overflow_neg;
    reg signed [DATA_WIDTH-1:0] sat_val;

    // Combinational Logic untuk menentukan nilai sebelum register
    always @(*) begin
        // Cek Overflow pada hasil penjumlahan bias
        overflow_pos = (sign_bit == 0) && (upper_check != 25'd0);
        overflow_neg = (sign_bit == 1) && (upper_check != {25{1'b1}});

        if (overflow_pos)      sat_val = MAX_VAL;
        else if (overflow_neg) sat_val = MIN_VAL;
        else                   sat_val = sliced_val;
    end

    // --- PIPELINED OUTPUT REGISTER ---
    // Latency = 1 Clock Cycle
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data  <= 0;
            out_valid <= 0;
        end else begin
            out_valid <= in_valid; // Valid merambat 1 cycle
            
            if (in_valid) begin
                case (mode)
                    2'd1: begin // ReLU
                        out_data <= (sat_val[DATA_WIDTH-1]) ? 0 : sat_val;
                    end
                    2'd2: begin // LeakyReLU (div 8 -> shift right 3)
                        out_data <= (sat_val[DATA_WIDTH-1]) ? (sat_val >>> 3) : sat_val;
                    end
                    default: out_data <= sat_val; // Linear/Bypass
                endcase
            end
        end
    end
endmodule