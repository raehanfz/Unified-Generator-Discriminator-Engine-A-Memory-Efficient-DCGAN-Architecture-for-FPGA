/*
 * Layer Configuration ROM
 * 
 * Purpose: Store pre-computed layer parameters for DCGAN inference
 *          Eliminates need for controller to compute these at runtime
 * 
 * Layers (9 total):
 *   G_FC:   24×512 = 12,288 weights + 512 biases = 12,800 total
 *   G_L0:   32×32×9 = 9,216 weights + 32 biases = 9,248 total
 *   G_L1:   16×32×9 = 4,608 weights + 16 biases = 4,624 total
 *   G_L2:   8×16×9  = 1,152 weights + 8 biases  = 1,160 total
 *   G_L3:   3×8×9   = 216 weights + 3 biases    = 219 total
 *   D_L0:   4×3×16  = 192 weights + 4 biases    = 196 total
 *   D_L1:   8×4×16  = 512 weights + 8 biases    = 520 total
 *   D_L2:   16×8×16 = 2,048 weights + 16 biases = 2,064 total
 *   D_L3:   1×16×16 = 256 weights + 1 bias      = 257 total
 */

`timescale 1ns / 1ps

module layer_config_rom (
    input  wire [3:0] layer_id,     // 0-8 for 9 layers

    // Weight/Bias ROM addresses
    output reg [14:0] weight_base,   // Start address for weights
    output reg [14:0] bias_base,     // Start address for biases
    output reg [15:0] num_weights,   // Number of weights (excluding bias)
    output reg [5:0]  num_biases,    // Number of biases
    
    // Layer dimensions
    output reg [5:0]  in_channels,   // Input channels
    output reg [5:0]  out_channels,  // Output channels
    output reg [5:0]  in_size,       // Input spatial size (4, 8, 16, 32)
    output reg [5:0]  out_size,      // Output spatial size
    
    // Convolution parameters
    output reg [2:0]  kernel_size,   // 1 (FC), 3, or 4
    output reg [1:0]  stride,        // 1 or 2
    output reg [1:0]  padding,       // 0 or 1
    
    // Accumulator configuration
    output reg [9:0]  acc_limit,     // How many MACs before output
    
    // Datapath control
    output reg        is_generator,  // 1=Gen, 0=Disc
    output reg        needs_upsample,// 1=upsample before this layer
    output reg        is_fc_layer,   // 1=fully connected (special handling)
    output reg [1:0]  activation,    // 0=linear, 1=ReLU, 2=LeakyReLU, 3=Tanh/Sigmoid
    
    // For FC layer: special dimensions
    output reg [9:0]  fc_input_len,  // 24 for G_FC
    output reg [9:0]  fc_output_len  // 512 for G_FC
);    
    always @(*) begin
        // Defaults
        weight_base    = 15'd0;
        bias_base      = 15'd0;
        num_weights    = 16'd0;
        num_biases     = 6'd0;
        in_channels    = 6'd0;
        out_channels   = 6'd0;
        in_size        = 6'd0;
        out_size       = 6'd0;
        kernel_size    = 3'd1;
        stride         = 2'd1;
        padding        = 2'd0;
        acc_limit      = 10'd1;
        is_generator   = 1'b1;
        needs_upsample = 1'b0;
        is_fc_layer    = 1'b0;
        activation     = 2'd1;  // ReLU default
        fc_input_len   = 10'd0;
        fc_output_len  = 10'd0;
        
        case (layer_id)
            // GENERATOR LAYERS
            4'd0: begin  // G_FC - Fully Connected
                weight_base    = 15'd0;
                bias_base      = 15'd12288;
                num_weights    = 16'd12288;  // 24 × 512
                num_biases     = 6'd32;      // 512, but we process 32 ch at a time
                in_channels    = 6'd24;      // Latent vector size
                out_channels   = 6'd32;      // ngf*4 = 32 channels
                in_size        = 6'd1;       // Vector (no spatial)
                out_size       = 6'd4;       // Reshape to 4×4
                kernel_size    = 3'd1;       // N/A for FC
                stride         = 2'd1;
                padding        = 2'd0;
                acc_limit      = 10'd24;     // Sum across 24 inputs
                is_generator   = 1'b1;
                needs_upsample = 1'b0;
                is_fc_layer    = 1'b1;
                activation     = 2'd1;       // ReLU
                fc_input_len   = 10'd24;
                fc_output_len  = 10'd512;    // 32×4×4
            end
            
            4'd1: begin  // G_L0 - Conv 32→32, 3×3 @ 4×4
                weight_base    = 15'd12800;
                bias_base      = 15'd22016;
                num_weights    = 16'd9216;   // 32×32×9
                num_biases     = 6'd32;
                in_channels    = 6'd32;
                out_channels   = 6'd32;
                in_size        = 6'd4;
                out_size       = 6'd4;       // Same with padding=1
                kernel_size    = 3'd3;
                stride         = 2'd1;
                padding        = 2'd1;
                acc_limit      = 10'd288;    // 32×9 = 288
                is_generator   = 1'b1;
                needs_upsample = 1'b0;       // No upsample before first conv
                is_fc_layer    = 1'b0;
                activation     = 2'd1;       // ReLU
            end
            
            4'd2: begin  // G_L1 - Conv 32→16, 3×3 @ 8×8
                weight_base    = 15'd22048;
                bias_base      = 15'd26656;
                num_weights    = 16'd4608;   // 16×32×9
                num_biases     = 6'd16;
                in_channels    = 6'd32;
                out_channels   = 6'd16;
                in_size        = 6'd8;       // After 2× upsample from 4×4
                out_size       = 6'd8;
                kernel_size    = 3'd3;
                stride         = 2'd1;
                padding        = 2'd1;
                acc_limit      = 10'd288;    // 32×9 = 288
                is_generator   = 1'b1;
                needs_upsample = 1'b1;       // Upsample 4→8 before this
                is_fc_layer    = 1'b0;
                activation     = 2'd1;       // ReLU
            end
            
            4'd3: begin  // G_L2 - Conv 16→8, 3×3 @ 16×16
                weight_base    = 15'd26672;
                bias_base      = 15'd27824;
                num_weights    = 16'd1152;   // 8×16×9
                num_biases     = 6'd8;
                in_channels    = 6'd16;
                out_channels   = 6'd8;
                in_size        = 6'd16;      // After 2× upsample from 8×8
                out_size       = 6'd16;
                kernel_size    = 3'd3;
                stride         = 2'd1;
                padding        = 2'd1;
                acc_limit      = 10'd144;    // 16×9 = 144
                is_generator   = 1'b1;
                needs_upsample = 1'b1;       // Upsample 8→16 before this
                is_fc_layer    = 1'b0;
                activation     = 2'd1;       // ReLU
            end
            
            4'd4: begin  // G_L3 - Conv 8→3, 3×3 @ 32×32 (final)
                weight_base    = 15'd27832;
                bias_base      = 15'd28048;
                num_weights    = 16'd216;    // 3×8×9
                num_biases     = 6'd3;
                in_channels    = 6'd8;
                out_channels   = 6'd3;       // RGB output
                in_size        = 6'd32;      // After 2× upsample from 16×16
                out_size       = 6'd32;
                kernel_size    = 3'd3;
                stride         = 2'd1;
                padding        = 2'd1;
                acc_limit      = 10'd72;     // 8×9 = 72
                is_generator   = 1'b1;
                needs_upsample = 1'b1;       // Upsample 16→32 before this
                is_fc_layer    = 1'b0;
                activation     = 2'd3;       // Tanh (maps to linear, software post-process)
            end
            
            
            // DISCRIMINATOR LAYERS
            
            4'd5: begin  // D_L0 - Conv 3→4, 4×4 stride 2 @ 32×32
                weight_base    = 15'd28051;
                bias_base      = 15'd28243;
                num_weights    = 16'd192;    // 4×3×16
                num_biases     = 6'd4;
                in_channels    = 6'd3;       // RGB input
                out_channels   = 6'd4;       // ndf = 4
                in_size        = 6'd32;
                out_size       = 6'd16;      // 32/2 = 16
                kernel_size    = 3'd4;
                stride         = 2'd2;
                padding        = 2'd1;
                acc_limit      = 10'd48;     // 3×16 = 48
                is_generator   = 1'b0;
                needs_upsample = 1'b0;
                is_fc_layer    = 1'b0;
                activation     = 2'd2;       // LeakyReLU
            end
            
            4'd6: begin  // D_L1 - Conv 4→8, 4×4 stride 2 @ 16×16
                weight_base    = 15'd28247;
                bias_base      = 15'd28759;
                num_weights    = 16'd512;    // 8×4×16
                num_biases     = 6'd8;
                in_channels    = 6'd4;
                out_channels   = 6'd8;       // ndf*2 = 8
                in_size        = 6'd16;
                out_size       = 6'd8;       // 16/2 = 8
                kernel_size    = 3'd4;
                stride         = 2'd2;
                padding        = 2'd1;
                acc_limit      = 10'd64;     // 4×16 = 64
                is_generator   = 1'b0;
                needs_upsample = 1'b0;
                is_fc_layer    = 1'b0;
                activation     = 2'd2;       // LeakyReLU
            end
            
            4'd7: begin  // D_L2 - Conv 8→16, 4×4 stride 2 @ 8×8
                weight_base    = 15'd28767;
                bias_base      = 15'd30815;
                num_weights    = 16'd2048;   // 16×8×16
                num_biases     = 6'd16;
                in_channels    = 6'd8;
                out_channels   = 6'd16;      // ndf*4 = 16
                in_size        = 6'd8;
                out_size       = 6'd4;       // 8/2 = 4
                kernel_size    = 3'd4;
                stride         = 2'd2;
                padding        = 2'd1;
                acc_limit      = 10'd128;    // 8×16 = 128
                is_generator   = 1'b0;
                needs_upsample = 1'b0;
                is_fc_layer    = 1'b0;
                activation     = 2'd2;       // LeakyReLU
            end
            
            4'd8: begin  // D_L3 - Conv 16→1, 4×4 stride 1 @ 4×4 (final)
                weight_base    = 15'd30831;
                bias_base      = 15'd31087;
                num_weights    = 16'd256;    // 1×16×16
                num_biases     = 6'd1;
                in_channels    = 6'd16;
                out_channels   = 6'd1;       // Single output (real/fake)
                in_size        = 6'd4;
                out_size       = 6'd1;       // 4-4+1 = 1 (no padding)
                kernel_size    = 3'd4;
                stride         = 2'd1;
                padding        = 2'd0;       // No padding for final
                acc_limit      = 10'd256;    // 16×16 = 256
                is_generator   = 1'b0;
                needs_upsample = 1'b0;
                is_fc_layer    = 1'b0;
                activation     = 2'd3;       // Sigmoid (linear, software post-process)
            end
            
            default: begin
            end
        endcase
    end

endmodule