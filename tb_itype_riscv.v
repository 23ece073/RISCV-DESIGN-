// ============================================================
// tb_itype_pico.v
// Testbench for I-Type instructions only
// Target: tiny_rv32i_pico_compat
//
// Tests: ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
// Corner cases: x0 destination, negative immediates
// ============================================================

module tb_I_type;

reg clk;
reg resetn;

wire mem_valid;
wire mem_instr;
wire [31:0] mem_addr;
wire [31:0] mem_wdata;
wire [3:0] mem_wstrb;
reg mem_ready;
reg [31:0] mem_rdata;

wire pcpi_valid;
wire [31:0] pcpi_insn;
wire [31:0] pcpi_rs1;
wire [31:0] pcpi_rs2;
reg pcpi_wait;
reg pcpi_ready;
reg pcpi_wr;
reg [31:0] pcpi_rd;

wire trap;

reg [31:0] mem [0:255];

integer pass_count;
integer fail_count;

tiny_rv32i_pico_compat dut (
    .clk(clk),
    .resetn(resetn),

    .mem_valid(mem_valid),
    .mem_instr(mem_instr),
    .mem_ready(mem_ready),
    .mem_addr(mem_addr),
    .mem_wdata(mem_wdata),
    .mem_wstrb(mem_wstrb),
    .mem_rdata(mem_rdata),

    .pcpi_valid(pcpi_valid),
    .pcpi_insn(pcpi_insn),
    .pcpi_rs1(pcpi_rs1),
    .pcpi_rs2(pcpi_rs2),
    .pcpi_wait(pcpi_wait),
    .pcpi_ready(pcpi_ready),
    .pcpi_wr(pcpi_wr),
    .pcpi_rd(pcpi_rd),

    .trap(trap)
);

always #5 clk = ~clk;

initial begin
    pcpi_wait  = 0;
    pcpi_ready = 0;
    pcpi_wr    = 0;
    pcpi_rd    = 0;
end

    always @(*) begin
        mem_ready = 1'b0;
        mem_rdata = 32'd0;
        if (mem_valid) begin
            mem_ready = 1'b1;
            if (mem_wstrb == 4'b0000)
                mem_rdata = mem[mem_addr[9:2]];
            else begin
                if (mem_wstrb[0]) mem[mem_addr[9:2]][7:0]   = mem_wdata[7:0];
                if (mem_wstrb[1]) mem[mem_addr[9:2]][15:8]  = mem_wdata[15:8];
                if (mem_wstrb[2]) mem[mem_addr[9:2]][23:16] = mem_wdata[23:16];
                if (mem_wstrb[3]) mem[mem_addr[9:2]][31:24] = mem_wdata[31:24];
            end
        end
    end

task check_reg;
        input [4:0]   reg_num;
        input [31:0]  expected;
        input [127:0] test_name;
        begin
            #1;
            if (dut.regs[reg_num] === expected) begin
                $display("  PASS: %s | regs[%0d] = 0x%08h",
                          test_name, reg_num, dut.regs[reg_num]);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL: %s | regs[%0d] = 0x%08h | expected = 0x%08h",
                          test_name, reg_num, dut.regs[reg_num], expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

task load_and_run;
        input integer num_cycles;
        begin
            resetn = 0;
            #20;
            resetn = 1;
            repeat(num_cycles) @(posedge clk);
        end
    endtask

    // ─────────────────────────────
    // Task: clear memory to NOP
    // ─────────────────────────────
    integer i;
    task clear_mem;
        begin
            for (i = 0; i < 256; i = i + 1)
                mem[i] = 32'h00000013; // NOP
        end
    endtask
    
initial begin
    clk        = 0;
    resetn     = 0;
    pass_count = 0;
    fail_count = 0;

    $display("========================================");
    $display("  I-TYPE INSTRUCTION TESTBENCH");
    $display("  tiny_rv32i_pico_compat");
    $display("========================================");

    // ════════════════════════════════════════
    // TEST 1: ADDI
    // x1 = 5 → x2 = x1 + 3 = 8
    // ════════════════════════════════════════
    $display("\n--- TEST 1: ADDI ---");
    clear_mem;
    mem[0] = 32'h00500093; // addi x1,x0,5
    mem[1] = 32'h00308113; // addi x2,x1,3
    mem[2] = 32'h00000013;

    load_and_run(50);
    check_reg(2, 32'd8, "ADDI x2=x1+3 (5+3=8)");

    // ════════════════════════════════════════
    // TEST 2: SLTI
    // 5 < 6 → true
    // ════════════════════════════════════════
    $display("\n--- TEST 2: SLTI ---");
    clear_mem;
    mem[0] = 32'h00500093; // x1=5
    mem[1] = 32'h0060A113; // slti x2,x1,6
    mem[2] = 32'h00000013;

    load_and_run(50);
    check_reg(2, 32'd1, "SLTI x2=(5<6)");

    // ════════════════════════════════════════
    // TEST 3: SLTIU
    // 1 < 2 → true
    // ════════════════════════════════════════
    $display("\n--- TEST 3: SLTIU ---");
    clear_mem;
    mem[0] = 32'h00100093; // x1=1
    mem[1] = 32'h0020B113; // sltiu x2,x1,2
    mem[2] = 32'h00000013;

    load_and_run(50);
    check_reg(2, 32'd1, "SLTIU x2=(1<2)");

    // ════════════════════════════════════════
    // TEST 4: XORI
    // FF ^ 0F = F0
    // ════════════════════════════════════════
    $display("\n--- TEST 4: XORI ---");
    clear_mem;
    mem[0] = 32'h0FF00093; // x1=0xFF
    mem[1] = 32'h00F0C113; // xori x2,x1,0xF
    mem[2] = 32'h00000013;

    load_and_run(50);
    check_reg(2, 32'hF0, "XORI x2=x1^0xF");

    // ════════════════════════════════════════
    // TEST 5: ORI
    // F0 | 0F = FF
    // ════════════════════════════════════════
    $display("\n--- TEST 5: ORI ---");
    clear_mem;
    mem[0] = 32'h0F000093; // x1=0xF0
    mem[1] = 32'h00F0E113; // ori x2,x1,0xF
    mem[2] = 32'h00000013;

    load_and_run(50);
    check_reg(2, 32'hFF, "ORI x2=x1|0xF");

    // ════════════════════════════════════════
    // TEST 6: ANDI
    // FF & 0F = 0F
    // ════════════════════════════════════════
    $display("\n--- TEST 6: ANDI ---");
    clear_mem;
    mem[0] = 32'h0FF00093; //addi x1, x0, 0xFF
    mem[1] = 32'h00F0F113; // andi x2,x1,0xF
    mem[2] = 32'h00000013;

    load_and_run(50);
    check_reg(2, 32'h0F, "ANDI x2=x1&0xF");

    // ════════════════════════════════════════
    // TEST 7: SLLI
    // 1 << 4 = 16
    // ════════════════════════════════════════
    $display("\n--- TEST 7: SLLI ---");
    clear_mem;
    mem[0] = 32'h00100093; // x1=1
    mem[1] = 32'h00409113; // slli x2,x1,4
    mem[2] = 32'h00000013;

    load_and_run(50);
    check_reg(2, 32'd16, "SLLI x2=1<<4");

    // ════════════════════════════════════════
    // TEST 8: SRLI
    // 16 >> 2 = 4
    // ════════════════════════════════════════
    $display("\n--- TEST 8: SRLI ---");
    clear_mem;
    mem[0] = 32'h01000093; // x1=16
    mem[1] = 32'h0020D113; // srli x2,x1,2
    mem[2] = 32'h00000013;

    load_and_run(50);
    check_reg(2, 32'd4, "SRLI x2=16>>2");

    // ════════════════════════════════════════
    // TEST 9: SRAI
    // -16 >>> 2 = -4
    // ════════════════════════════════════════
    $display("\n--- TEST 9: SRAI ---");
    clear_mem;
    mem[0] = 32'hFF000093; // x1=-16
    mem[1] = 32'h4020D113; // srai x2,x1,2
    mem[2] = 32'h00000013;

    load_and_run(50);
    check_reg(2, 32'hFFFFFFFC, "SRAI x2=-16>>>2");

    // ════════════════════════════════════════
    // CORNER 1: x0 destination
    // ════════════════════════════════════════
    $display("\n--- CORNER 1: x0 destination ---");
    clear_mem;
    mem[0] = 32'h00500093;
    mem[1] = 32'h00300013; // addi x0,x0,3
    mem[2] = 32'h00000013;

    load_and_run(50);
    check_reg(0, 32'd0, "x0 stays zero");

    // ════════════════════════════════════════
    // CORNER 2: negative immediate
    // 5 + (-2) = 3
    // ════════════════════════════════════════
    $display("\n--- CORNER 2: negative immediate ---");
    clear_mem;
    mem[0] = 32'h00500093; // x1=5
    mem[1] = 32'hFFE08113; // addi x2,x1,-2
    mem[2] = 32'h00000013;

    load_and_run(50);
    check_reg(2, 32'd3, "ADDI negative imm");

    // ════════════════════════════════════════
    // FINAL RESULTS
    // ════════════════════════════════════════
    $display("\n======================================");
    $display("  RESULTS");
    $display("  PASS : %0d", pass_count);
    $display("  FAIL : %0d", fail_count);
    $display("========================================");

    $finish;
end
// checking the cycle counts 
    
    integer cycle_count=0;

always @(posedge clk) begin

        cycle_count <= cycle_count + 1;
end

integer start_cycle;
integer end_cycle;
reg [31:0] instr;

always @(posedge clk) begin
    if (resetn && dut.state == dut.S_FETCH && mem_valid && mem_ready) begin
        start_cycle = cycle_count;
        instr = mem_rdata;
    end
end

always @(posedge clk) begin
    if (resetn && dut.state == dut.S_WB) begin
        end_cycle = cycle_count;

        $display(
        "Instruction %h completed in %0d cycles and start_cycles:%0d | end_cycle:%0d",
        instr,
        end_cycle - start_cycle,
        start_cycle,
        end_cycle
        );
    end
    end 
    endmodule
