`timescale 1ns/1ns

// ==========================================
// MIPS 5-STAGE PIPELINE PROCESSOR (Phase 3)
// HARDWARE HAZARD & FORWARDING UNIT IMPLEMENTED
// ==========================================
module mips_core(
    input clk,
    input rst,
    input forwarding_EN
);

    // -----------------------------------------
    // STAGE 1: INSTRUCTION FETCH (IF)
    // -----------------------------------------
    reg [31:0] pc;
    wire pc_write;     // Hardware Hazard PC Freeze
    wire if_id_write;  // Hardware Hazard Reg Freeze
    wire [31:0] if_pc_plus4 = pc + 4;
    wire [31:0] if_instr;

    always @(posedge clk or posedge rst) begin
        if (rst) pc <= 0;
        else if (pc_write) pc <= if_pc_plus4; // Freeze PC on Hazard
    end

    // Instruction Memory (ROM)
    reg [31:0] imem [0:63];
    initial begin
        // TIGHT CODE: No manual NOPs! The hardware handles collisions dynamically.
        imem[0] = 32'h8C010000; // LW R1, 0(R0)   -> Loads 5
        imem[1] = 32'h8C020004; // LW R2, 4(R0)   -> Loads 10
        imem[2] = 32'h00221820; // ADD R3, R1, R2 -> Load-Use Hazard! (Stalls automatically)
        imem[3] = 32'h00612020; // ADD R4, R3, R1 -> RAW Data Hazard! (Forwards automatically)
        imem[4] = 32'hAC040008; // SW R4, 8(R0)   -> Stores 20
        imem[5] = 32'h00000000;
        imem[6] = 32'h00000000;
        imem[7] = 32'h00000000;
    end
    assign if_instr = imem[pc[7:2]]; // Fetch Instruction

    // --- IF/ID Pipeline Register ---
    reg [31:0] id_pc_plus4, id_instr;
    always @(posedge clk or posedge rst) begin
        if (rst) begin id_pc_plus4 <= 0; id_instr <= 0; end
        else if (if_id_write) begin id_pc_plus4 <= if_pc_plus4; id_instr <= if_instr; end
    end

    // -----------------------------------------
    // STAGE 2: INSTRUCTION DECODE (ID)
    // -----------------------------------------
    wire [5:0] id_opcode = id_instr[31:26];
    wire [4:0] id_rs = id_instr[25:21];
    wire [4:0] id_rt = id_instr[20:16];
    wire [4:0] id_rd = id_instr[15:11];
    wire [15:0] id_imm = id_instr[15:0];
    wire [31:0] id_sign_ext_imm = {{16{id_imm[15]}}, id_imm};

    // Register File
    reg [31:0] reg_file [0:31];
    wire [31:0] id_reg_data1 = (id_rs == 0) ? 0 : reg_file[id_rs];
    wire [31:0] id_reg_data2 = (id_rt == 0) ? 0 : reg_file[id_rt];

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) reg_file[i] = 0;
    end

    // Basic Control Unit Decoder
    reg id_reg_dst, id_alu_src, id_mem_to_reg, id_reg_write, id_mem_read, id_mem_write;
    reg [1:0] id_alu_op;
    
    always @(*) begin
        // Defaults
        id_reg_dst=0; id_alu_src=0; id_mem_to_reg=0; id_reg_write=0; 
        id_mem_read=0; id_mem_write=0; id_alu_op=2'b00;
        case(id_opcode)
            6'h00: begin id_reg_dst=1; id_reg_write=1; id_alu_op=2'b10; end // R-Type (ADD)
            6'h23: begin id_alu_src=1; id_mem_to_reg=1; id_reg_write=1; id_mem_read=1; end // LW
            6'h2B: begin id_alu_src=1; id_mem_write=1; end // SW
        endcase
    end

    // --- HAZARD DETECTION UNIT ---
    wire id_ex_mem_read; 
    wire [4:0] ex_rt_peek; 
    wire load_use_hazard = (id_ex_mem_read && (ex_rt_peek == id_rs || ex_rt_peek == id_rt));
    
    assign pc_write = !load_use_hazard;
    assign if_id_write = !load_use_hazard;
    wire ctrl_mux = !load_use_hazard; // If hazard, flush controls to insert a NOP bubble

    // --- ID/EX Pipeline Register ---
    reg ex_reg_dst, ex_alu_src, ex_mem_to_reg, ex_reg_write, ex_mem_read, ex_mem_write;
    reg [1:0] ex_alu_op;
    reg [31:0] ex_reg_data1, ex_reg_data2, ex_sign_ext_imm;
    reg [4:0] ex_rs, ex_rt, ex_rd;
    
    assign id_ex_mem_read = ex_mem_read;
    assign ex_rt_peek = ex_rt;

    always @(posedge clk or posedge rst) begin
        if (rst || !ctrl_mux) begin // Flush on hazard
            ex_reg_write <= 0; ex_mem_write <= 0; ex_mem_read <= 0; ex_reg_dst <= 0;
            ex_alu_src <= 0; ex_mem_to_reg <= 0; ex_alu_op <= 0;
        end else begin
            ex_reg_dst <= id_reg_dst; ex_alu_src <= id_alu_src; ex_mem_to_reg <= id_mem_to_reg;
            ex_reg_write <= id_reg_write; ex_mem_read <= id_mem_read; ex_mem_write <= id_mem_write;
            ex_alu_op <= id_alu_op; ex_reg_data1 <= id_reg_data1; ex_reg_data2 <= id_reg_data2;
            ex_sign_ext_imm <= id_sign_ext_imm; ex_rs <= id_rs; ex_rt <= id_rt; ex_rd <= id_rd;
        end
    end

    // -----------------------------------------
    // STAGE 3: EXECUTE (EX)
    // -----------------------------------------
    
    // --- FORWARDING UNIT ---
    wire mem_reg_write_peek;
    wire [4:0] mem_write_reg_peek;
    wire wb_reg_write_peek;
    wire [4:0] wb_write_reg_peek;
    wire [31:0] mem_alu_result_peek;
    wire [31:0] wb_write_data_peek;
    
    reg [1:0] forward_a, forward_b;
    always @(*) begin
        forward_a = 2'b00; forward_b = 2'b00;
        
        if (forwarding_EN) begin
            // EX Hazard
            if (mem_reg_write_peek && (mem_write_reg_peek != 0) && (mem_write_reg_peek == ex_rs))
                forward_a = 2'b10;
            // MEM Hazard
            else if (wb_reg_write_peek && (wb_write_reg_peek != 0) && (wb_write_reg_peek == ex_rs))
                forward_a = 2'b01;

            // EX Hazard
            if (mem_reg_write_peek && (mem_write_reg_peek != 0) && (mem_write_reg_peek == ex_rt))
                forward_b = 2'b10;
            // MEM Hazard
            else if (wb_reg_write_peek && (wb_write_reg_peek != 0) && (wb_write_reg_peek == ex_rt))
                forward_b = 2'b01;
        end
    end

    // ALU Input Muxes for Forwarding
    wire [31:0] alu_mux_a = (forward_a == 2'b10) ? mem_alu_result_peek :
                            (forward_a == 2'b01) ? wb_write_data_peek : ex_reg_data1;
    wire [31:0] alu_mux_b_fwd = (forward_b == 2'b10) ? mem_alu_result_peek :
                                (forward_b == 2'b01) ? wb_write_data_peek : ex_reg_data2;

    wire [31:0] ex_alu_in2 = ex_alu_src ? ex_sign_ext_imm : alu_mux_b_fwd;
    reg [31:0] ex_alu_result;
    wire [4:0] ex_write_reg = ex_reg_dst ? ex_rd : ex_rt;

    // Simplified ALU
    always @(*) begin
        if (ex_alu_op == 2'b10) begin
            ex_alu_result = alu_mux_a + ex_alu_in2; // Assume ADD for all R-types
        end else begin
            ex_alu_result = alu_mux_a + ex_alu_in2; // LW/SW uses ADD for address calculation
        end
    end

    // --- EX/MEM Pipeline Register ---
    reg mem_mem_to_reg, mem_reg_write, mem_mem_read, mem_mem_write;
    reg [31:0] mem_alu_result, mem_reg_data2;
    reg [4:0] mem_write_reg;

    assign mem_reg_write_peek = mem_reg_write;
    assign mem_write_reg_peek = mem_write_reg;
    assign mem_alu_result_peek = mem_alu_result;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mem_reg_write <= 0; mem_mem_write <= 0; mem_mem_read <= 0;
        end else begin
            mem_mem_to_reg <= ex_mem_to_reg; mem_reg_write <= ex_reg_write;
            mem_mem_read <= ex_mem_read; mem_mem_write <= ex_mem_write;
            mem_alu_result <= ex_alu_result; 
            mem_reg_data2 <= alu_mux_b_fwd; // Forward data to memory store!
            mem_write_reg <= ex_write_reg;
        end
    end

    // -----------------------------------------
    // STAGE 4: MEMORY (MEM)
    // -----------------------------------------
    reg [31:0] data_mem [0:63];
    wire [31:0] mem_read_data;

    initial begin
        data_mem[0] = 32'd5;  // Initial Data at Address 0
        data_mem[1] = 32'd10; // Initial Data at Address 4 (Word aligned: Index 1)
    end

    assign mem_read_data = mem_mem_read ? data_mem[mem_alu_result[7:2]] : 0;

    always @(posedge clk) begin
        if (mem_mem_write) data_mem[mem_alu_result[7:2]] <= mem_reg_data2;
    end

    // --- MEM/WB Pipeline Register ---
    reg wb_mem_to_reg, wb_reg_write;
    reg [31:0] wb_read_data, wb_alu_result;
    reg [4:0] wb_write_reg;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wb_reg_write <= 0;
        end else begin
            wb_mem_to_reg <= mem_mem_to_reg; wb_reg_write <= mem_reg_write;
            wb_read_data <= mem_read_data; wb_alu_result <= mem_alu_result;
            wb_write_reg <= mem_write_reg;
        end
    end

    // -----------------------------------------
    // STAGE 5: WRITE BACK (WB)
    // -----------------------------------------
    wire [31:0] wb_write_data = wb_mem_to_reg ? wb_read_data : wb_alu_result;

    assign wb_reg_write_peek = wb_reg_write;
    assign wb_write_reg_peek = wb_write_reg;
    assign wb_write_data_peek = wb_write_data;

    // FIXED: Using negedge clk to avoid Register File read-after-write timing hazards
    always @(negedge clk) begin
        // Write back to Register File
        if (wb_reg_write && wb_write_reg != 0) begin
            reg_file[wb_write_reg] <= wb_write_data;
        end
    end

endmodule