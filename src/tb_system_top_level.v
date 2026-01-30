`include "system_top_level.v"
`timescale 1ns / 1ps

module tb_system_top_level;

    // 1. PHYSICAL SIGNALS (FPGA Pins)    
    reg clk;
    reg rst_n;
    reg start_generator;
    reg start_discriminator;
    wire busy;
    wire inference_done;
    
    // Framebuffer & Results
    reg  [11:0] fb_rd_addr;
    wire [15:0] fb_rd_data;
    wire        frame_ready;
    wire [15:0] disc_result;
    wire        disc_result_valid;

    // 2. INTERNAL PROBES (Hierarchical - No IO Pin Cost)    
    // Sinyal ini diintip langsung dari dalam modul tanpa menambah beban pin fisik.
    wire [3:0]  current_layer;
    wire [4:0]  controller_state;
    wire [31:0] engine_output_count;
    wire [31:0] engine_data_count;

    // 3. DUT INSTANTIATION
    system_top_level dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_generator(start_generator),
        .start_discriminator(start_discriminator),
        .seed_value(16'hA5A5), // Seed awal untuk stabilitas GAN
        .seed_load(1'b0),
        .busy(busy),
        .inference_done(inference_done),
        .fb_rd_addr(fb_rd_addr),
        .fb_rd_data(fb_rd_data),
        .frame_ready(frame_ready),
        .disc_result(disc_result),
        .disc_result_valid(disc_result_valid)
    );

    // Menghubungkan probe ke internal DUT (Internalized untuk hemat IO)
    assign current_layer       = dut.current_layer;
    assign controller_state    = dut.controller_state;
    assign engine_output_count = dut.engine_output_count;
    assign engine_data_count   = dut.engine_data_count;

    // 4. CLOCK & TRACKING LOGIC (50 MHz)
    // Periode 20ns untuk memastikan WNS +3ns terpenuhi
    always #10 clk = ~clk; 

    reg [31:0] cycle_count;
    initial cycle_count = 0;
    always @(posedge clk) begin
        if (rst_n) cycle_count <= cycle_count + 1;
    end

    // 5. TEST SEQUENCE    
    integer gen_start, gen_end, disc_start, disc_end;
    integer i;

    initial begin
        $dumpfile("tb_system.vcd");
        $dumpvars(0, tb_system_top_level);
        
        $display("====================================================");
        $display("   OKINAWA LSI CONTEST: DCGAN SYSTEM TESTBENCH      ");
        $display("   Target Device: XC7A35T | Clock: 50 MHz           ");
        $display("====================================================");
        
        // --- System Reset ---
        clk = 0; rst_n = 0;
        start_generator = 0; start_discriminator = 0;
        fb_rd_addr = 0;
        repeat(20) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);
        
        // --- Test 1: Generator ---
        $display("\n[%t] INFO: Triggering Generator...", $time);
        gen_start = cycle_count;
        @(posedge clk);
        start_generator = 1;
        @(posedge clk);
        start_generator = 0;
        
        wait(inference_done);
        gen_end = cycle_count;
        $display(">>> SUCCESS: GENERATOR FINISHED");
        $display(">>> Start Cycle: %0d | End Cycle: %0d", gen_start, gen_end);
        $display(">>> Total Generator Latency: %0d cycles", (gen_end - gen_start));
        
        repeat(200) @(posedge clk); // Gap stabilisasi

        // --- Test 2: Discriminator ---
        $display("\n[%t] INFO: Triggering Discriminator...", $time);
        disc_start = cycle_count;
        @(posedge clk);
        start_discriminator = 1;
        @(posedge clk);
        start_discriminator = 0;
        
        wait(inference_done);
        disc_end = cycle_count;
        $display(">>> SUCCESS: DISCRIMINATOR FINISHED");
        $display(">>> Start Cycle: %0d | End Cycle: %0d", disc_start, disc_end);
        $display(">>> Total Discriminator Latency: %0d cycles", (disc_end - disc_start));
        
        // --- Final Summary Table ---
        $display("\n====================================================");
        $display("           FINAL PERFORMANCE SUMMARY                ");
        $display("====================================================");
        $display(" Frequency:          50 MHz");
        $display(" Gen Inference:      %0d cycles (%0.2f ms)", 
                  (gen_end - gen_start), (gen_end - gen_start) * 0.00002);
        $display(" Disc Inference:     %0d cycles (%0.2f ms)", 
                  (disc_end - disc_start), (disc_end - disc_start) * 0.00002);
        $display(" Total MACs:         %0d", engine_data_count);
        $display(" Power (Estimated):  0.129 W");
        $display(" Disc Result:        %0d (Interpretation: %s)", 
                  $signed(disc_result), ($signed(disc_result) > 0 ? "REAL" : "FAKE"));
        $display("====================================================");

        #100;
        $finish;
    end

    // Watchdog Timer
    initial begin
        #50000000; // 50ms timeout
        $display("\nERROR: SIMULATION TIMEOUT");
        $finish;
    end

endmodule