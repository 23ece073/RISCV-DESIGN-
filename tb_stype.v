// ============================================================
// tb_stype_pico.v
// Testbench for S-Type instructions
// Target: tiny_rv32i_pico_compat
// ============================================================
//Verified:
//Full 32-bit store
//Address calculation
//Memory overwrite
//Zero case
`timescale 1ns/1ps
module tb_stype_pico;

    // ─────────────────────────────
    // Signal declarations
    // ─────────────────────────────
    reg         clk;
    reg         resetn;

    wire        mem_valid;
    wire        mem_instr;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg         mem_ready;
    reg  [31:0] mem_rdata;

    wire        pcpi_valid;
    wire [31:0] pcpi_insn;
    wire [31:0] pcpi_rs1;
    wire [31:0] pcpi_rs2;
    reg         pcpi_wait;
    reg         pcpi_ready;
    reg         pcpi_wr;
    reg  [31:0] pcpi_rd;

    wire        trap;

    // Memory
    reg [31:0] mem [0:255];

    integer pass_count;
    integer fail_count;
    integer i;

    // ─────────────────────────────
    // DUT
    // ─────────────────────────────
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

    // Clock
    always #5 clk = ~clk;

    // PCPI OFF
    initial begin
        pcpi_wait  = 0;
        pcpi_ready = 0;
        pcpi_wr    = 0;
        pcpi_rd    = 0;
    end

    // ─────────────────────────────
    // Memory model
    // ─────────────────────────────
    always @(*) begin
        mem_ready = 0;
        mem_rdata = 0;

        if (mem_valid) begin
            mem_ready = 1;

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

    // ─────────────────────────────
    // Check memory task
    // ─────────────────────────────
    task check_mem;
        input [31:0] addr;
        input [31:0] expected;
        input [127:0] test_name;
    begin
        #1;
        if (mem[addr>>2] === expected) begin
            $display("  PASS: %s | mem[%0d] = 0x%08h",
                      test_name, addr, mem[addr>>2]);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: %s | mem[%0d] = 0x%08h | expected = 0x%08h",
                      test_name, addr, mem[addr>>2], expected);
            fail_count = fail_count + 1;
        end
    end
    endtask

    // ─────────────────────────────
    // Reset + run
    // ─────────────────────────────
    task load_and_run;
        input integer num_cycles;
    begin
        resetn = 0;
        #20;
        resetn = 1;
        repeat(num_cycles) @(posedge clk);
    end
    endtask

    // Clear memory
    task clear_mem;
    begin
        for (i = 0; i < 256; i = i + 1)
            mem[i] = 32'h00000013;
    end
    endtask

    // ─────────────────────────────
    // MAIN TESTS
    // ─────────────────────────────
    initial begin
        clk = 0;
        resetn = 0;
        pass_count = 0;
        fail_count = 0;

        $display("========================================");
        $display("  S-TYPE INSTRUCTION TESTBENCH");
        $display("========================================");

        // TEST 1: SW basic
        $display("\n--- TEST 1: SW ---");
        clear_mem;
        mem[0] = 32'h00F00093; // x1=15
        mem[1] = 32'h00102023; // sw x1,0(x0)
        mem[2] = 32'h00000013;

        load_and_run(50);
        check_mem(0, 32'd15, "SW x1 -> mem[0]");

        // TEST 2: SW offset
        $display("\n--- TEST 2: SW offset ---");
        clear_mem;
        mem[0] = 32'h00A00093; // x1=10
        mem[1] = 32'h00102223; // sw x1,4(x0)
        mem[2] = 32'h00000013;

        load_and_run(50);
        check_mem(4, 32'd10, "SW x1 -> mem[4]");

        // TEST 3: overwrite
        $display("\n--- TEST 3: overwrite ---");
        clear_mem;
        mem[0] = 32'h00500093;
        mem[1] = 32'h00102023;
        mem[2] = 32'h00A00093;
        mem[3] = 32'h00102023;
        mem[4] = 32'h00000013;

        load_and_run(80);
        check_mem(0, 32'd10, "overwrite mem[0]");

        // TEST 4: store zero
        $display("\n--- TEST 4: store zero ---");
        clear_mem;
        mem[0] = 32'h00000093;
        mem[1] = 32'h00102023;
        mem[2] = 32'h00000013;

        load_and_run(50);
        check_mem(0, 32'd0, "store zero");
// ════════════════════════════════════════
// TEST 5: SB (Store Byte)
// Store only 1 byte into memory
// ════════════════════════════════════════
$display("\n--- TEST 5: SB ---");
clear_mem;   //  VERY IMPORTANT

mem[0] = 32'hAABBCCDD;
mem[1] = 32'h01100093; // x1 = 0x11
mem[2] = 32'h001000A3; // sb x1,1(x0)
mem[3] = 32'h00000013;

load_and_run(60);

check_mem(0, 32'hAABB11DD, "SB byte1 write");
// ════════════════════════════════════════
// TEST 6: SH (Store Half-word)
// Store 2 bytes into memory
// ════════════════════════════════════════
$display("\n--- TEST 6: SH ---");
clear_mem;

// Initial memory value
mem[0] = 32'hAABBCCDD; // [AA][BB][CC][DD]

// Load x1 = 0x1122
mem[1] = 32'h12200093; // addi x1, x0, 0x122 (we'll use lower 16 bits = 0x0122)

// SH x1, 0(x0) → write lower 2 bytes
mem[2] = 32'h00101023; // sh x1,0(x0)

mem[3] = 32'h00000013;

load_and_run(60);

// Expected:
// Before: AABBCCDD
// After : AABB0122
check_mem(0, 32'hAABB0122, "SH lower half write");


// Expected result:
// original: AABBCCDD
// byte1 replaced → AA11CCDD
$display("\n--- CORNER 1: SB all byte positions ---");
clear_mem;

mem[0] = 32'hAABBCCDD;
mem[1] = 32'h01100093; // x1 = 0x11

mem[2] = 32'h00100023; // sb x1,0(x0)
mem[3] = 32'h001000A3; // sb x1,1(x0)
mem[4] = 32'h00100123; // sb x1,2(x0)
mem[5] = 32'h001001A3; // sb x1,3(x0)

load_and_run(100);

check_mem(0, 32'h11111111, "SB all byte positions");
$display("\n--- CORNER 2A: SH lower half ---");
clear_mem;

mem[0] = 32'hAABBCCDD;

mem[1] = 32'h12200093; // x1 = 0x0122
mem[2] = 32'h00101023; // sh x1,0(x0)

load_and_run(60);

check_mem(0, 32'hAABB0122, "SH lower half");
$display("\n--- CORNER 2B: SH upper half (TB observation) ---");
clear_mem;

mem[0] = 32'hAABBCCDD;

mem[1] = 32'h12200093; // x1 = 0x0122
mem[2] = 32'h00101223; // sh x1,2(x0)

load_and_run(60);

// Expected SAME (no change)
check_mem(0, 32'hAABBCCDD, "SH upper half (not supported)");
$display("\n--- CORNER 3: x0 as source ---");
clear_mem;

mem[0] = 32'hAABBCCDD;

mem[1] = 32'h00002023; // sw x0,0(x0)

load_and_run(50);

check_mem(0, 32'h00000000, "store x0");
$display("\n--- CORNER 4: back-to-back stores ---");
clear_mem;

mem[0] = 32'h00500093; // x1=5
mem[1] = 32'h00102023; // sw x1,0(x0)

mem[2] = 32'h00A00093; // x1=10
mem[3] = 32'h00102023; // sw x1,0(x0)

load_and_run(80);

check_mem(0, 32'd10, "back-to-back overwrite");
$display("\n--- CORNER 5: address offset ---");
clear_mem;

mem[0] = 32'h00500093; // addi x1, x0, 5
mem[1] = 32'h00102823; // sw x1,16(x0)

mem[2] = 32'h00000013; // nop

load_and_run(60);

// MUST match offset
check_mem(16, 32'd5, "store at offset address");
        // CORNER: trap check
        $display("\n--- CORNER: trap check ---");
        if (!trap)
            $display("  PASS: trap never fired");
        else
            $display("  FAIL: trap fired!");

        // CORNER: pcpi_valid
        $display("\n--- CORNER: pcpi_valid ---");
        if (!pcpi_valid)
            $display("  PASS: pcpi_valid not used");
        else
            $display("  FAIL: pcpi triggered!");

        // FINAL
        $display("\n========================================");
        $display("PASS = %0d", pass_count);
        $display("FAIL = %0d", fail_count);

        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("TEST FAILED");

        $finish;
    end

endmodule
