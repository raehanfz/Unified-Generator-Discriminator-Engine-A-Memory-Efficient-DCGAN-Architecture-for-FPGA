`timescale 1ns / 1ps

module patch_extractor#(
    parameter DATA_WIDTH    = 16,
    parameter MAX_IMG_SIZE  = 32,
    parameter MAX_CHANNELS  = 32
)(
    input  wire clk,
    input  wire rst_n,
    
    // CONFIGURATION
    input  wire [5:0] cfg_img_width,
    input  wire [5:0] cfg_img_height,
    input  wire [2:0] cfg_kernel_size,
    input  wire [1:0] cfg_stride,
    input  wire [1:0] cfg_padding,
    input  wire [5:0] cfg_in_channels,
    
    // INPUT STREAM
    input  wire signed [DATA_WIDTH-1:0] s_pixel_data,
    input  wire                         s_pixel_valid,
    output reg                          s_pixel_ready,
    
    // OUTPUT STREAM
    output reg  signed [DATA_WIDTH-1:0] m_patch_data,
    output reg                          m_patch_valid,
    input  wire                         m_patch_ready,
    
    // CONTROL
    input  wire start,
    output reg  busy,
    output reg  done
);

    // IMAGE BUFFER - Dedicated BRAM Inference Block (No Reset)    
    localparam BUFFER_DEPTH = 3800;
    (* ram_style = "block" *)
    reg signed [DATA_WIDTH-1:0] img_buffer [0:BUFFER_DEPTH-1];

    // STATE MACHINE & COUNTERS    
    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_IMAGE = 3'd1;
    localparam S_EXTRACT    = 3'd2;
    localparam S_OUTPUT     = 3'd3;
    localparam S_NEXT_ELEM  = 3'd4;
    localparam S_NEXT_POS   = 3'd5;
    localparam S_DONE       = 3'd6;
    
    reg [2:0] state;
    reg [15:0] load_count;
    reg [15:0] total_pixels;
    reg [5:0] out_row, out_col;
    reg [2:0] k_row, k_col;
    reg [5:0] k_ch;
    reg [19:0] patch_out_cnt;

    // Output size calculation
    wire [5:0] out_width  = (cfg_img_width + (cfg_padding << 1) - cfg_kernel_size) / cfg_stride + 1;
    wire [5:0] out_height = out_width;

    // Pixel address calculation
    wire signed [6:0] img_row = (out_row * cfg_stride) + k_row - cfg_padding;
    wire signed [6:0] img_col = (out_col * cfg_stride) + k_col - cfg_padding;
    wire is_padding = (img_row < 0) || (img_col < 0) || (img_row >= cfg_img_height) || (img_col >= cfg_img_width);
    wire [15:0] pixel_addr = (img_row * cfg_img_width * cfg_in_channels) + (img_col * cfg_in_channels) + k_ch;

    // SYNCHRONOUS RAM WRITE PORT
    always @(posedge clk) begin
        if (state == S_LOAD_IMAGE && s_pixel_valid && s_pixel_ready) begin
            img_buffer[load_count] <= s_pixel_data;
        end
    end
    
    // CONTROL STATE MACHINE (With Reset)    
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
            patch_out_cnt <= 0;
        end else begin
            done <= 0;
            
            case (state)
                S_IDLE: begin
                    busy <= 0;
                    s_pixel_ready <= 0;
                    m_patch_valid <= 0;
                    if (start) begin
                        state <= S_LOAD_IMAGE;
                        busy <= 1;
                        load_count <= 0;
                        total_pixels <= cfg_img_width * cfg_img_height * cfg_in_channels;
                        s_pixel_ready <= 1;
                        patch_out_cnt <= 0;
                    end
                end
                
                S_LOAD_IMAGE: begin
                    s_pixel_ready <= 1;
                    if (s_pixel_valid && s_pixel_ready) begin
                        load_count <= load_count + 1;
                        if (load_count >= total_pixels - 1) begin
                            s_pixel_ready <= 0;
                            state <= S_EXTRACT;
                            out_row <= 0; out_col <= 0;
                            k_row <= 0; k_col <= 0; k_ch <= 0;
                        end
                    end
                end
                
                S_EXTRACT: begin
                    m_patch_data <= (is_padding) ? 16'sd0 : img_buffer[pixel_addr];
                    m_patch_valid <= 1;
                    state <= S_OUTPUT;
                end
                
                S_OUTPUT: begin
                    if (m_patch_ready) begin
                        patch_out_cnt <= patch_out_cnt + 1;
                        m_patch_valid <= 0;
                        state <= S_NEXT_ELEM;
                    end
                end
                
                S_NEXT_ELEM: begin
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
                                state <= S_NEXT_POS;
                            end
                        end
                    end
                end
                
                S_NEXT_POS: begin
                    if (out_col < out_width - 1) begin
                        out_col <= out_col + 1;
                        state <= S_EXTRACT;
                    end else begin
                        out_col <= 0;
                        if (out_row < out_height - 1) begin
                            out_row <= out_row + 1;
                            state <= S_EXTRACT;
                        end else begin
                            state <= S_DONE;
                        end
                    end
                end
                
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