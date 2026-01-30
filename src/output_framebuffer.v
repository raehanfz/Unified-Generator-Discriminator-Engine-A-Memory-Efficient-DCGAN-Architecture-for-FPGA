`timescale 1ns / 1ps

module output_framebuffer #(
    parameter DATA_WIDTH = 16,
    parameter IMG_SIZE   = 32,
    parameter CHANNELS   = 3,
    parameter DEPTH      = 3072,   // 32x32x3
    parameter ADDR_WIDTH = 12
)(
    input  wire                  clk,
    input  wire                  rst_n,
    
    // Write interface (from Output Mux)
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  wr_en,
    
    // Read interface (for External Display or Discriminator)
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  [DATA_WIDTH-1:0] rd_data,
    
    // Control
    input  wire                  frame_start,
    output reg                   frame_ready
);
    // FRAME BUFFER STORAGE (BRAM Inference - No Reset)
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] frame_mem [0:DEPTH-1];

    // Synchronous Write Port
    always @(posedge clk) begin
        if (wr_en) begin
            frame_mem[wr_addr] <= wr_data;
        end
    end

    // Synchronous Read Port
    always @(posedge clk) begin
        rd_data <= frame_mem[rd_addr];
    end

    // CONTROL LOGIC (With Reset)
    reg [ADDR_WIDTH-1:0] pixel_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_ready <= 0;
            pixel_count <= 0;
        end else begin
            if (frame_start) begin
                frame_ready <= 0;
                pixel_count <= 0;
            end else if (wr_en) begin
                if (pixel_count >= DEPTH - 1) begin
                    frame_ready <= 1;
                end else begin
                    pixel_count <= pixel_count + 1;
                end
            end
        end
    end
endmodule