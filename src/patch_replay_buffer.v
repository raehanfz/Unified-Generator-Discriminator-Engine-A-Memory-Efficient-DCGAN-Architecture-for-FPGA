`timescale 1ns / 1ps

module patch_replay_buffer #(
    parameter DATA_WIDTH = 16,
    parameter MAX_PATCH_SIZE = 288
)(
    input  wire clk,
    input  wire rst_n,
    
    // CONFIGURATION
    input  wire [9:0]  cfg_patch_size,
    input  wire [7:0]  cfg_replay_count,
    input  wire [15:0] cfg_num_patches,
    
    // CONTROL
    input  wire start,
    output reg  busy,
    output reg  done,
    output reg  patch_done,
    
    // INPUT (from patch_extractor)
    input  wire signed [DATA_WIDTH-1:0] s_data,
    input  wire                         s_valid,
    output wire                         s_ready,
    
    // OUTPUT (to compute_engine)
    output reg  signed [DATA_WIDTH-1:0] m_data,
    output reg                          m_valid,
    input  wire                         m_ready,
    
    // DEBUG
    output reg  [15:0] debug_patch_count,
    output reg  [7:0]  debug_replay_idx
);

    // PATCH BUFFER - Dedicated BRAM Inference (No Reset)
    (* ram_style = "block" *)
    reg signed [DATA_WIDTH-1:0] buffer [0:MAX_PATCH_SIZE-1];
    
    // STATE MACHINE & COUNTERS    
    localparam S_IDLE   = 3'd0;
    localparam S_LOAD   = 3'd1;
    localparam S_REPLAY = 3'd2;
    localparam S_NEXT   = 3'd3;
    localparam S_DONE   = 3'd4;
    
    reg [2:0] state;
    reg [9:0] load_idx;
    reg [9:0] replay_idx;
    reg [7:0] replay_count;
    reg [15:0] patch_count;

    assign s_ready = (state == S_LOAD);

    // SYNCHRONOUS RAM WRITE PORT (Preserves BRAM Inference)    
    always @(posedge clk) begin
        if (state == S_LOAD && s_valid && s_ready) begin
            buffer[load_idx] <= s_data;
        end
    end

    // MAIN CONTROL MACHINE (With Reset)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy <= 0;
            done <= 0;
            patch_done <= 0;
            m_data <= 0;
            m_valid <= 0;
            load_idx <= 0;
            replay_idx <= 0;
            replay_count <= 0;
            patch_count <= 0;
            debug_patch_count <= 0;
            debug_replay_idx <= 0;
        end else begin
            done <= 0;
            patch_done <= 0;
            
            case (state)
                S_IDLE: begin
                    busy <= 0;
                    m_valid <= 0;
                    if (start) begin
                        state <= S_LOAD;
                        busy <= 1;
                        load_idx <= 0;
                        replay_idx <= 0;
                        replay_count <= 0;
                        patch_count <= 0;
                        debug_patch_count <= 0;
                    end
                end
                
                S_LOAD: begin
                    m_valid <= 0;
                    if (s_valid && s_ready) begin
                        if (load_idx >= cfg_patch_size - 1) begin
                            load_idx <= 0;
                            replay_idx <= 0;
                            replay_count <= 0;
                            state <= S_REPLAY;
                        end else begin
                            load_idx <= load_idx + 1;
                        end
                    end
                end
                
                S_REPLAY: begin
                    m_data <= buffer[replay_idx];
                    m_valid <= 1;
                    debug_replay_idx <= replay_count;
                    
                    if (m_ready) begin
                        if (replay_idx >= cfg_patch_size - 1) begin
                            replay_idx <= 0;
                            if (replay_count >= cfg_replay_count - 1) begin
                                m_valid <= 0;
                                patch_done <= 1;
                                state <= S_NEXT;
                            end else begin
                                replay_count <= replay_count + 1;
                            end
                        end else begin
                            replay_idx <= replay_idx + 1;
                        end
                    end
                end
                
                S_NEXT: begin
                    m_valid <= 0;
                    patch_count <= patch_count + 1;
                    debug_patch_count <= patch_count + 1;
                    
                    if (patch_count >= cfg_num_patches - 1) begin
                        state <= S_DONE;
                    end else begin
                        load_idx <= 0;
                        replay_count <= 0;
                        state <= S_LOAD;
                    end
                end
                
                S_DONE: begin
                    done <= 1;
                    busy <= 0;
                    m_valid <= 0;
                    state <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule