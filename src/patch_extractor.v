/*
 * Patch Extractor Module v2 (im2col for Convolution) - FIXED
 * 
 * Purpose: Extract sliding window patches from feature maps for convolution
 * 
 * Simplified approach:
 *   1. First, load ENTIRE image into buffer
 *   2. Then, extract patches by reading from buffer
 *   
 * This is less memory-efficient but much simpler and more reliable.
 * For small images (up to 32×32), this is acceptable.
 */

`timescale 1ns / 1ps

module patch_extractor#(
    parameter DATA_WIDTH    = 16,
    parameter MAX_IMG_SIZE  = 32,
    parameter MAX_CHANNELS  = 32
)(
    input  wire clk,
    input  wire rst_n,
    
    // =========================================================================
    // CONFIGURATION
    // =========================================================================
    input  wire [5:0] cfg_img_width,      // Input image width (4, 8, 16, 32)
    input  wire [5:0] cfg_img_height,     // Input image height
    input  wire [2:0] cfg_kernel_size,    // 3 or 4
    input  wire [1:0] cfg_stride,         // 1 or 2
    input  wire [1:0] cfg_padding,        // 0 or 1
    input  wire [5:0] cfg_in_channels,    // Number of input channels
    
    // =========================================================================
    // INPUT STREAM (from Feature Map Memory)
    // =========================================================================
    input  wire signed [DATA_WIDTH-1:0] s_pixel_data,
    input  wire                         s_pixel_valid,
    output reg                          s_pixel_ready,
    
    // =========================================================================
    // OUTPUT STREAM (to Systolic Engine)
    // =========================================================================
    output reg  signed [DATA_WIDTH-1:0] m_patch_data,
    output reg                          m_patch_valid,
    input  wire                         m_patch_ready,
    
    // =========================================================================
    // CONTROL
    // =========================================================================
    input  wire start,
    output reg  busy,
    output reg  done
);

    // =========================================================================
    // IMAGE BUFFER - Store entire input image
    // =========================================================================
    // Max size: 32×32×32 = 32768 elements (too large!)
    // Practical: 32×32×3 = 3072 for discriminator input, or 16×16×32 = 8192
    // We'll use a reasonable limit
    localparam BUFFER_DEPTH = 4096;  // Supports up to 32×32×4 or 16×16×16
    
    reg signed [DATA_WIDTH-1:0] img_buffer [0:BUFFER_DEPTH-1];
    
    // =========================================================================
    // STATE MACHINE
    // =========================================================================
    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_IMAGE = 3'd1;
    localparam S_EXTRACT    = 3'd2;
    localparam S_OUTPUT     = 3'd3;
    localparam S_NEXT_ELEM  = 3'd4;
    localparam S_NEXT_POS   = 3'd5;
    localparam S_DONE       = 3'd6;
    
    reg [2:0] state;
    
    // =========================================================================
    // COUNTERS
    // =========================================================================
    // Image loading
    reg [15:0] load_count;
    reg [15:0] total_pixels;  // img_width × img_height × in_channels
    
    // Patch extraction
    reg [5:0] out_row;        // Output position row (0 to out_height-1)
    reg [5:0] out_col;        // Output position col (0 to out_width-1)
    reg [2:0] k_row;          // Kernel row (0 to kernel_size-1)
    reg [2:0] k_col;          // Kernel col (0 to kernel_size-1)
    reg [5:0] k_ch;           // Kernel channel (0 to in_channels-1)
    
    // Computed values
    wire [5:0] out_width;
    wire [5:0] out_height;
    
    // Output size calculation: (input + 2*padding - kernel) / stride + 1
    wire [5:0] padded_size;
    assign padded_size = cfg_img_width + (cfg_padding << 1);
    assign out_width  = (padded_size - cfg_kernel_size) / cfg_stride + 1;
    assign out_height = out_width;
    
    // =========================================================================
    // PIXEL ADDRESS CALCULATION
    // =========================================================================
    // For reading from buffer during extraction
    wire signed [6:0] img_row;  // Signed to detect negative (padding)
    wire signed [6:0] img_col;
    wire [15:0] pixel_addr;
    wire is_padding;
    
    // Calculate actual image coordinates
    // img_row = out_row * stride + k_row - padding
    assign img_row = (out_row * cfg_stride) + k_row - cfg_padding;
    assign img_col = (out_col * cfg_stride) + k_col - cfg_padding;
    
    // Check if in padding region (negative or out of bounds)
    assign is_padding = (img_row < 0) || (img_col < 0) || 
                        (img_row >= cfg_img_height) || (img_col >= cfg_img_width);
    
    // Buffer address: row * width * channels + col * channels + ch
    assign pixel_addr = (img_row * cfg_img_width * cfg_in_channels) + 
                        (img_col * cfg_in_channels) + k_ch;
    
    // =========================================================================
    // MAIN STATE MACHINE
    // =========================================================================
    integer i;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy <= 0;
            done <= 0;
            s_pixel_ready <= 0;
            m_patch_data <= 0;
            m_patch_valid <= 0;
            
            load_count <= 0;
            total_pixels <= 0;
            out_row <= 0;
            out_col <= 0;
            k_row <= 0;
            k_col <= 0;
            k_ch <= 0;
            
        end else begin
            // Default
            done <= 0;
            
            case (state)
                // ---------------------------------------------------------
                S_IDLE: begin
                    busy <= 0;
                    s_pixel_ready <= 0;
                    m_patch_valid <= 0;
                    
                    if (start) begin
                        state <= S_LOAD_IMAGE;
                        busy <= 1;
                        load_count <= 0;
                        total_pixels <= cfg_img_width * cfg_img_height * cfg_in_channels;
                        s_pixel_ready <= 1;  // Ready to receive
                        $display("[PE] Starting: %0dx%0d x %0d = %0d pixels, k=%0d s=%0d", 
                                cfg_img_width, cfg_img_height, cfg_in_channels,
                                cfg_img_width * cfg_img_height * cfg_in_channels,
                                cfg_kernel_size, cfg_stride);
                    end
                end
                
                // ---------------------------------------------------------
                S_LOAD_IMAGE: begin
                    s_pixel_ready <= 1;
                    
                    if (s_pixel_valid && s_pixel_ready) begin
                        img_buffer[load_count] <= s_pixel_data;
                        load_count <= load_count + 1;
                        
                        if (load_count >= total_pixels - 1) begin
                            // Image fully loaded
                            s_pixel_ready <= 0;
                            state <= S_EXTRACT;
                            $display("[PE] Image loaded: %0d pixels", load_count + 1);
                            
                            // Reset extraction counters
                            out_row <= 0;
                            out_col <= 0;
                            k_row <= 0;
                            k_col <= 0;
                            k_ch <= 0;
                        end
                    end
                end
                
                // ---------------------------------------------------------
                S_EXTRACT: begin
                    // Read from buffer and prepare output
                    if (is_padding) begin
                        m_patch_data <= 16'sd0;  // Zero padding
                    end else begin
                        m_patch_data <= img_buffer[pixel_addr];
                    end
                    m_patch_valid <= 1;
                    state <= S_OUTPUT;
                end
                
                // ---------------------------------------------------------
                S_OUTPUT: begin
                    // Wait for downstream to accept
                    if (m_patch_ready) begin
                        m_patch_valid <= 0;
                        state <= S_NEXT_ELEM;
                    end
                end
                
                // ---------------------------------------------------------
                S_NEXT_ELEM: begin
                    // Advance to next element in patch (channel → col → row)
                    if (k_ch < cfg_in_channels - 1) begin
                        k_ch <= k_ch + 1;
                        state <= S_EXTRACT;
                    end else begin
                        k_ch <= 0;
                        
                        if (k_col < cfg_kernel_size - 1) begin
                            k_col <= k_col + 1;
                            state <= S_EXTRACT;
                        end else begin
                            k_col <= 0;
                            
                            if (k_row < cfg_kernel_size - 1) begin
                                k_row <= k_row + 1;
                                state <= S_EXTRACT;
                            end else begin
                                k_row <= 0;
                                // Completed one patch, move to next position
                                state <= S_NEXT_POS;
                            end
                        end
                    end
                end
                
                // ---------------------------------------------------------
                S_NEXT_POS: begin
                    // Move to next output position (col → row)
                    if (out_col < out_width - 1) begin
                        out_col <= out_col + 1;
                        state <= S_EXTRACT;
                    end else begin
                        out_col <= 0;
                        
                        if (out_row < out_height - 1) begin
                            out_row <= out_row + 1;
                            state <= S_EXTRACT;
                        end else begin
                            // All patches extracted
                            state <= S_DONE;
                        end
                    end
                end
                
                // ---------------------------------------------------------
                S_DONE: begin
                    done <= 1;
                    busy <= 0;
                    m_patch_valid <= 0;
                    state <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule