/*
 * Patch Replay Buffer
 * 
 * Purpose: Buffer one patch from patch_extractor and replay it
 *          multiple times for each output channel group
 * 
 * Operation:
 *   1. Load: Accept patch_size elements into buffer
 *   2. Replay: Output buffer contents replay_count times
 *   3. Repeat for next patch until num_patches complete
 * 
 * Example (G_L0):
 *   patch_size = 288 (3×3×32)
 *   replay_count = 8 (32 out_channels / 4)
 *   num_patches = 16 (4×4 output positions)
 *   Total outputs = 288 × 8 × 16 = 36,864
 */

`timescale 1ns / 1ps

module patch_replay_buffer #(
    parameter DATA_WIDTH = 16,
    parameter MAX_PATCH_SIZE = 288  // 3×3×32 max
)(
    input  wire clk,
    input  wire rst_n,
    
    // =========================================================================
    // CONFIGURATION
    // =========================================================================
    input  wire [9:0]  cfg_patch_size,    // Elements per patch (K²×C_in)
    input  wire [7:0]  cfg_replay_count,  // Times to replay (C_out/4)
    input  wire [15:0] cfg_num_patches,   // Total patches (H_out × W_out)
    
    // =========================================================================
    // CONTROL
    // =========================================================================
    input  wire start,
    output reg  busy,
    output reg  done,
    output reg  patch_done,              // Pulse when one patch fully replayed
    
    // =========================================================================
    // INPUT (from patch_extractor)
    // =========================================================================
    input  wire signed [DATA_WIDTH-1:0] s_data,
    input  wire                         s_valid,
    output wire                         s_ready,
    
    // =========================================================================
    // OUTPUT (to input_mux/compute_engine)
    // =========================================================================
    output reg  signed [DATA_WIDTH-1:0] m_data,
    output reg                          m_valid,
    input  wire                         m_ready,
    
    // =========================================================================
    // DEBUG
    // =========================================================================
    output reg  [15:0] debug_patch_count,
    output reg  [7:0]  debug_replay_idx
);

    // =========================================================================
    // STATE MACHINE
    // =========================================================================
    localparam S_IDLE    = 3'd0;
    localparam S_LOAD    = 3'd1;
    localparam S_REPLAY  = 3'd2;
    localparam S_NEXT    = 3'd3;
    localparam S_DONE    = 3'd4;
    
    reg [2:0] state;
    
    // =========================================================================
    // PATCH BUFFER
    // =========================================================================
    reg signed [DATA_WIDTH-1:0] buffer [0:MAX_PATCH_SIZE-1];
    
    // =========================================================================
    // COUNTERS
    // =========================================================================
    reg [9:0]  load_idx;       // Index during loading (0 to patch_size-1)
    reg [9:0]  replay_idx;     // Index during replay (0 to patch_size-1)
    reg [7:0]  replay_count;   // Current replay iteration (0 to cfg_replay_count-1)
    reg [15:0] patch_count;    // Current patch number (0 to num_patches-1)
    
    // =========================================================================
    // READY LOGIC
    // =========================================================================
    // Only accept input during LOAD state
    assign s_ready = (state == S_LOAD);
    
    // =========================================================================
    // MAIN STATE MACHINE
    // =========================================================================
    integer i;
    
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
            // Default: clear pulses
            done <= 0;
            patch_done <= 0;
            
            case (state)
                // ---------------------------------------------------------
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
                        $display("[PRB] Starting: patch_size=%0d, replay=%0d, num_patches=%0d",
                                cfg_patch_size, cfg_replay_count, cfg_num_patches);
                    end
                end
                
                // ---------------------------------------------------------
                // LOAD: Fill buffer with one patch
                // ---------------------------------------------------------
                S_LOAD: begin
                    m_valid <= 0;
                    
                    if (s_valid && s_ready) begin
                        buffer[load_idx] <= s_data;
                        
                        if (load_idx >= cfg_patch_size - 1) begin
                            // Patch fully loaded
                            load_idx <= 0;
                            replay_idx <= 0;
                            replay_count <= 0;
                            state <= S_REPLAY;
                            
                            if (patch_count < 3) begin
                                $display("[PRB] Patch %0d loaded", patch_count);
                            end
                        end else begin
                            load_idx <= load_idx + 1;
                        end
                    end
                end
                
                // ---------------------------------------------------------
                // REPLAY: Output buffer contents
                // ---------------------------------------------------------
                S_REPLAY: begin
                    m_data <= buffer[replay_idx];
                    m_valid <= 1;
                    debug_replay_idx <= replay_count;
                    
                    if (m_ready) begin
                        if (replay_idx >= cfg_patch_size - 1) begin
                            // Finished one replay
                            replay_idx <= 0;
                            
                            if (replay_count >= cfg_replay_count - 1) begin
                                // All replays done for this patch
                                m_valid <= 0;
                                patch_done <= 1;
                                state <= S_NEXT;
                            end else begin
                                // More replays needed
                                replay_count <= replay_count + 1;
                            end
                        end else begin
                            replay_idx <= replay_idx + 1;
                        end
                    end
                end
                
                // ---------------------------------------------------------
                // NEXT: Move to next patch or finish
                // ---------------------------------------------------------
                S_NEXT: begin
                    m_valid <= 0;
                    patch_count <= patch_count + 1;
                    debug_patch_count <= patch_count + 1;
                    
                    if (patch_count >= cfg_num_patches - 1) begin
                        // All patches done
                        state <= S_DONE;
                        $display("[PRB] All %0d patches complete", patch_count + 1);
                    end else begin
                        // Load next patch
                        load_idx <= 0;
                        replay_count <= 0;
                        state <= S_LOAD;
                    end
                end
                
                // ---------------------------------------------------------
                // DONE
                // ---------------------------------------------------------
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