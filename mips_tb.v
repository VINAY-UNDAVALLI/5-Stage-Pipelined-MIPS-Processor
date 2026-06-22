`timescale 1ns/1ns

module tb_mips;

    reg clk;
    reg rst;
    reg forwarding_EN;

    // Instantiate the Pipeline
    mips_core uut (
        .clk(clk),
        .rst(rst),
        .forwarding_EN(forwarding_EN)
    );

    // Create top-level wires to watch internal array values without triggering VCD warnings
    wire [31:0] watch_reg1 = uut.reg_file[1];
    wire [31:0] watch_reg2 = uut.reg_file[2];
    wire [31:0] watch_reg3 = uut.reg_file[3];
    wire [31:0] watch_reg4 = uut.reg_file[4]; // Watch the new R4 for the Forwarding test
    wire [31:0] watch_mem8 = uut.data_mem[2];

    // Generate Clock using repeat loop logic (100ns period)
    initial begin
        clk = 1;
        repeat(5000) #50 clk = ~clk;
    end

    initial begin
        $dumpfile("mips_tb.vcd"); // Updated to match your exact terminal command
        $dumpvars(0, tb_mips);
        
        // Initialize based on provided test bench logic
        rst = 1;
        // ENABLE FORWARDING! (If this is 0, the math will be 10 and 15)
        forwarding_EN = 1; 
        
        #100;
        rst = 0; // Release reset, PC starts fetching

        // INCREASED WAIT TIME: Clock is 100ns per cycle now, need more simulation time
        #2000; 
        
        $display("--------------------------------------------------");
        $display("SIMULATION COMPLETE (HARDWARE HAZARD RESOLUTION)");
        $display("Register 1 (Loaded 5): %d", uut.reg_file[1]);
        $display("Register 2 (Loaded 10): %d", uut.reg_file[2]);
        $display("Register 3 (R1+R2): %d", uut.reg_file[3]);
        $display("Register 4 (R3+R1): %d", uut.reg_file[4]); // Print the forwarded result
        $display("Memory Addr 8 (Stored 20): %d", uut.data_mem[2]);
        $display("--------------------------------------------------");
        
        $finish;
    end

endmodule