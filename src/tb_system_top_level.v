`include "system_top_level.v"
/*
 * DCGAN System Top Level Testbench
 * Tests both Generator and Discriminator inference
 */

`timescale 1ns / 1ps

module tb_system_top_level;

    // Clock and reset
    reg clk;
    reg rst_n;
    
    // Control
    reg start_generator;
    reg start_discriminator;
    wire busy;
    wire inference_done;
    
    // Status
    wire [3:0] current_layer;
    wire [4:0] controller_state;
    
    // Weight streamer
    wire ws_bias_done;
    wire ws_stream_ready;
    
    // Engine stats
    wire [31:0] engine_data_count;
    wire [31:0] engine_output_count;
    
    // Framebuffer output (32x32x3 generator image)
    reg  [11:0] fb_rd_addr;
    wire [15:0] fb_rd_data;
    wire frame_ready;
    
    // Discriminator output
    wire [15:0] disc_result;
    wire disc_result_valid;
    
    // Clock generation
    always #5 clk = ~clk;
    
    // DUT instantiation
    system_top_level dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_generator(start_generator),
        .start_discriminator(start_discriminator),
        .seed_value(16'h0),
        .seed_load(1'b0),
        .busy(busy),
        .inference_done(inference_done),
        .current_layer(current_layer),
        .controller_state(controller_state),
        
        // Framebuffer read port
        .fb_rd_addr(fb_rd_addr),
        .fb_rd_data(fb_rd_data),
        .frame_ready(frame_ready),
        
        // Discriminator result
        .disc_result(disc_result),
        .disc_result_valid(disc_result_valid),
        
        // Debug
        .ws_bias_done(ws_bias_done),
        .ws_stream_ready(ws_stream_ready),
        .engine_data_count(engine_data_count),
        .engine_output_count(engine_output_count)
    );
    
    // State decoder for display
    function [127:0] state_name;
        input [4:0] state;
        begin
            case(state)
                5'd0:  state_name = "IDLE";
                5'd1:  state_name = "GEN_START";
                5'd2:  state_name = "LOAD_BIAS";
                5'd3:  state_name = "WAIT_BIAS";
                5'd27: state_name = "FC_CACHE";
                5'd28: state_name = "FC_WAIT_CACHE";
                5'd4:  state_name = "FC_START";
                5'd5:  state_name = "FC_PROCESS";
                5'd6:  state_name = "FC_WAIT_DONE";
                5'd7:  state_name = "FC_DRAIN";
                5'd8:  state_name = "CONV_SETUP";
                5'd9:  state_name = "CONV_BIAS";
                5'd10: state_name = "CONV_WAIT_BIAS";
                5'd25: state_name = "CONV_CACHE";
                5'd26: state_name = "CONV_WAIT_CACHE";
                5'd11: state_name = "CONV_START";
                5'd12: state_name = "CONV_PROCESS";
                5'd13: state_name = "CONV_WAIT_DONE";
                5'd14: state_name = "CONV_DRAIN";
                5'd15: state_name = "BANK_SWITCH";
                5'd16: state_name = "NEXT_LAYER";
                5'd17: state_name = "OUTPUT";
                5'd18: state_name = "DONE";
                5'd19: state_name = "LAYER_WAIT";
                5'd20: state_name = "LAYER_WAIT2";
                5'd21: state_name = "DISC_START";
                5'd22: state_name = "DISC_SETUP";
                5'd23: state_name = "DISC_LAYER_WAIT";
                5'd24: state_name = "DISC_DONE";
                default: state_name = "UNKNOWN";
            endcase
        end
    endfunction
    
    // Progress monitor
    reg [31:0] cycle_count;
    reg [4:0] prev_state;
    reg [3:0] prev_layer;
    
    initial begin
        cycle_count = 0;
        prev_state = 5'd31;
        prev_layer = 4'd15;
    end
    
    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        
        // Print on state change
        if (controller_state != prev_state) begin
            $display("[%0d] State: %0s -> %0s (layer=%0d)", 
                    cycle_count, state_name(prev_state), state_name(controller_state), current_layer);
            prev_state <= controller_state;
        end
        
        // Print on layer change
        if (current_layer != prev_layer && busy) begin
            $display("[%0d] Layer changed: %0d -> %0d (out_cnt=%0d)", 
                    cycle_count, prev_layer, current_layer, engine_output_count);
            prev_layer <= current_layer;
        end
    end

    // Test variables
    integer errors;
    integer timeout_count;
    integer gen_cycles;
    integer disc_cycles;
    integer gen_outputs;
    integer disc_outputs;
    integer i;

    initial begin
        $dumpfile("tb_system.vcd");
        $dumpvars(0, tb_system_top_level);
        
        $display("==============================================");
        $display("DCGAN System Testbench - Generator + Discriminator");
        $display("==============================================");
        
        errors = 0;
        
        // Initialize
        clk = 0;
        rst_n = 0;
        start_generator = 0;
        start_discriminator = 0;
        fb_rd_addr = 0;
        
        // Reset
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);
        
        // ================================================================
        // GENERATOR TEST
        // ================================================================
        $display("\n######################################");
        $display("# GENERATOR TEST                     #");
        $display("######################################");
        
        // Start generator
        @(posedge clk);
        start_generator = 1;
        @(posedge clk);
        start_generator = 0;
        
        // Wait for generator completion
        timeout_count = 0;
        while (!inference_done && timeout_count < 10000000) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
        end
        
        if (inference_done) begin
            gen_cycles = timeout_count;
            gen_outputs = engine_output_count;
            $display("\n  ✓ Generator PASS");
            $display("    Cycles: %0d", gen_cycles);
            $display("    Outputs: %0d", gen_outputs);
        end else begin
            $display("\n  ✗ Generator FAIL (timeout)");
            $display("    State: %0d, Layer: %0d", controller_state, current_layer);
            errors = errors + 1;
        end
        
        // Wait for return to idle
        repeat(20) @(posedge clk);
        
        if (!busy && controller_state == 0) begin
            $display("    Returned to IDLE");
        end else begin
            $display("    WARNING: Did not return to idle");
        end
        
        // Quick framebuffer check after generator (before discriminator)
        $display("\n  [DEBUG] Framebuffer check after generator:");
        $display("  frame_ready=%0d, r2s_from_fb=%0d", frame_ready, dut.ctrl_mem_r2s_from_fb);
        fb_rd_addr = 0;
        repeat(3) @(posedge clk);
        $display("  fb[0] = %0d (0x%04h)", $signed(fb_rd_data), fb_rd_data);
        fb_rd_addr = 1000;
        repeat(3) @(posedge clk);
        $display("  fb[1000] = %0d (0x%04h)", $signed(fb_rd_data), fb_rd_data);
        
        // ================================================================
        // DISCRIMINATOR TEST
        // ================================================================
        $display("\n######################################");
        $display("# DISCRIMINATOR TEST                 #");
        $display("######################################");
        
        // Reset output count for discriminator
        // Note: In real HW, we'd load an image to framebuffer first
        // For testing, discriminator will process whatever is in RAM
        
        repeat(10) @(posedge clk);
        
        // Start discriminator
        @(posedge clk);
        start_discriminator = 1;
        @(posedge clk);
        start_discriminator = 0;
        
        // Wait for discriminator completion
        timeout_count = 0;
        while (!inference_done && timeout_count < 10000000) begin
            @(posedge clk);
            timeout_count = timeout_count + 1;
        end
        
        if (inference_done) begin
            disc_cycles = timeout_count;
            disc_outputs = engine_output_count - gen_outputs;
            $display("\n  ✓ Discriminator PASS");
            $display("    Cycles: %0d", disc_cycles);
            $display("    Outputs: %0d", disc_outputs);
        end else begin
            $display("\n  ✗ Discriminator FAIL (timeout)");
            $display("    State: %0d, Layer: %0d", controller_state, current_layer);
            errors = errors + 1;
        end
        
        // Wait for return to idle
        repeat(20) @(posedge clk);
        
        // ================================================================
        // READ AND DISPLAY OUTPUTS
        // ================================================================
        $display("\n######################################");
        $display("# OUTPUT VALUES                      #");
        $display("######################################");
        
        // Display discriminator result
        $display("\nDiscriminator Result:");
        $display("  Value: %0d (0x%04h)", $signed(disc_result), disc_result);
        $display("  Valid: %0d", disc_result_valid);
        // Interpretation: positive = real, negative = fake (before sigmoid)
        if ($signed(disc_result) > 0)
            $display("  Interpretation: REAL (raw logit > 0)");
        else
            $display("  Interpretation: FAKE (raw logit <= 0)");
        
        // Read and display some framebuffer values (first 16 and last 16 pixels)
        $display("\nGenerator Output (first 16 pixels of 3072):");
        $display("  frame_ready=%b", frame_ready);
        for (i = 0; i < 16; i = i + 1) begin
            fb_rd_addr = i;
            repeat(3) @(posedge clk);  // Extra latency for safety
            $display("  fb[%4d] = 0x%04h (%0d)", i, fb_rd_data, $signed(fb_rd_data));
        end
        
        $display("\nGenerator Output (last 4 pixels of 3072):");
        for (i = 3068; i < 3072; i = i + 1) begin
            fb_rd_addr = i;
            repeat(3) @(posedge clk);
            $display("  fb[%4d] = 0x%04h (%0d)", i, fb_rd_data, $signed(fb_rd_data));
        end
        
        // ================================================================
        // SUMMARY
        // ================================================================
        $display("\n==============================================");
        $display("FINAL SUMMARY");
        $display("==============================================");
        $display("Generator:");
        $display("  Cycles:  %0d", gen_cycles);
        $display("  Outputs: %0d (expected ~7168)", gen_outputs);
        $display("Discriminator:");
        $display("  Cycles:  %0d", disc_cycles);
        $display("  Outputs: %0d (expected ~337)", disc_outputs);
        $display("Total MACs: %0d", engine_data_count);
        $display("==============================================");
        
        if (errors == 0) begin
            $display("ALL TESTS PASSED!");
        end else begin
            $display("TESTS FAILED: %0d errors", errors);
        end
        $display("==============================================");

        #100;
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #100000000;  // 100ms timeout
        $display("\n!!! WATCHDOG TIMEOUT !!!");
        $display("Cycle: %0d, State: %0d, Layer: %0d", 
                cycle_count, controller_state, current_layer);
        $finish;
    end

endmodule