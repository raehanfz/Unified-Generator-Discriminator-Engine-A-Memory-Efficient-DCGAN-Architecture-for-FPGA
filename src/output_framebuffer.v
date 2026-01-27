`timescale 1ns / 1ps

/*
    description:
    Stores final generated image (32×32×3 RGB)
*/
module output_framebuffer #(
    parameter DATA_WIDTH = 16,
    parameter IMG_SIZE = 32,            // 32×32 image
    parameter CHANNELS = 3,             // RGB
    parameter DEPTH = 3072,             // 32×32×3 = 3072 pixels
    parameter ADDR_WIDTH = 12
)(
    input  wire                      clk,
    input  wire                      rst_n,
    
    // Write interface (from final layer output)
    input  wire [ADDR_WIDTH-1:0]     wr_addr,
    input  wire [DATA_WIDTH-1:0]     wr_data,
    input  wire                      wr_en,
    
    // Read interface (to display controller or discriminator)
    input  wire [ADDR_WIDTH-1:0]     rd_addr,
    output reg  [DATA_WIDTH-1:0]     rd_data,
    
    // Frame sync
    input  wire                      frame_start,
    output reg                       frame_ready
);

    // Frame buffer storage
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] frame_mem [0:DEPTH-1];
    
    reg [ADDR_WIDTH-1:0] write_count;
    
    // Read operation
    always @(posedge clk) begin
        if (!rst_n) begin
            rd_data <= 0;
        end else begin
            rd_data <= frame_mem[rd_addr];
        end
    end
    
    always @(posedge clk) begin
        if (!rst_n) begin
            frame_ready <= 0;
            write_count <= 0;
        end else begin
            if (frame_start) begin
                frame_ready <= 0;
                write_count <= 0;
            end else if (wr_en) begin
                frame_mem[wr_addr] <= wr_data;
                
                write_count <= write_count + 1;

                if (write_count >= DEPTH - 1) begin
                    frame_ready <= 1;
                end
            end
        end
    end

endmodule