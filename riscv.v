// tiny_rv32i_pico_compat.v
// A small multi-cycle RV32I core with PicoRV32-style memory + PCPI ports.
// Goal: drop-in, port-for-port compatibility with PicoRV32 smallest configs.
//
// Supported offload via PCPI:
// - CUSTOM-0..3 opcodes (0001011,0101011,1011011,1111011)
// - M-extension encoding space: opcode=0110011 and funct7=0000001 (mul/div etc)
//   (core itself does NOT implement MUL/DIV; expects external PCPI unit)
//
// Notes:
// - Unified memory bus (single port, tagged by mem_instr)
// - Multi-cycle FSM (slower than PicoRV32, but interface compatible)
// - No CSR/ECALL/EBREAK/IRQ here
// - Misaligned accesses not trapped; avoid them

module tiny_rv32i_pico_compat (
    input  wire        clk,
    input  wire        resetn,

    // PicoRV32 memory interface
    output reg         mem_valid,
    output reg         mem_instr,
    input  wire        mem_ready,

    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_wstrb,
    input  wire [31:0] mem_rdata,

    // PicoRV32 PCPI interface
    output reg         pcpi_valid,
    output reg  [31:0] pcpi_insn,
    output reg  [31:0] pcpi_rs1,
    output reg  [31:0] pcpi_rs2,
    input  wire        pcpi_wait,
    input  wire        pcpi_ready,
    input  wire        pcpi_wr,
    input  wire [31:0] pcpi_rd,

    // trap/illegal
    output reg         trap
);

    // ----------------------------
    // State machine
    // ----------------------------
    localparam S_FETCH  = 3'd0;
    localparam S_DECODE = 3'd1;
    localparam S_EXEC   = 3'd2;
    localparam S_MEM    = 3'd3;
    localparam S_WB     = 3'd4;
    localparam S_PCPI   = 3'd5;

    reg [2:0] state;

    // ----------------------------
    // Architectural state
    // ----------------------------
    reg [31:0] pc;
    reg [31:0] ir;
    reg [31:0] regs [0:31];

    // decoded fields
    wire [6:0] opcode = ir[6:0];
    wire [2:0] funct3 = ir[14:12];
    wire [6:0] funct7 = ir[31:25];
    wire [4:0] rd     = ir[11:7];
    wire [4:0] rs1    = ir[19:15];
    wire [4:0] rs2    = ir[24:20];

    wire [31:0] rs1_val = (rs1 == 0) ? 32'd0 : regs[rs1];
    wire [31:0] rs2_val = (rs2 == 0) ? 32'd0 : regs[rs2];

    // immediates
    wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
    wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
    wire [31:0] imm_b = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
    wire [31:0] imm_u = {ir[31:12], 12'b0};
    wire [31:0] imm_j = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};

    // Offload classes
    wire is_custom =
        (opcode == 7'b0001011) || // CUSTOM-0
        (opcode == 7'b0101011) || // CUSTOM-1
        (opcode == 7'b1011011) || // CUSTOM-2
        (opcode == 7'b1111011);   // CUSTOM-3

    wire is_muldiv_space =
        (opcode == 7'b0110011) && (funct7 == 7'b0000001); // RV32M encoding space

    wire wants_pcpi = is_custom || is_muldiv_space;

    // ----------------------------
    // Internal latches
    // ----------------------------
    reg [31:0] alu_out;
    reg [31:0] wb_data;
    reg        wb_en;
    reg [4:0]  wb_rd;

    reg        is_load;
    reg        is_store;
    reg [2:0]  load_f3;
    reg [2:0]  store_f3;

    reg        take_branch;

    // ----------------------------
    // Helpers
    // ----------------------------
    function [31:0] sext8(input [7:0] v);   sext8  = {{24{v[7]}}, v}; endfunction
    function [31:0] sext16(input [15:0] v); sext16 = {{16{v[15]}}, v}; endfunction

    function [31:0] alu_calc;
        input [31:0] a, b;
        input [3:0]  op;
        begin
            case (op)
                4'd0: alu_calc = a + b;                                // ADD
                4'd1: alu_calc = a - b;                                // SUB
                4'd2: alu_calc = a & b;                                // AND
                4'd3: alu_calc = a | b;                                // OR
                4'd4: alu_calc = a ^ b;                                // XOR
                4'd5: alu_calc = a << b[4:0];                           // SLL
                4'd6: alu_calc = a >> b[4:0];                           // SRL
                4'd7: alu_calc = $signed(a) >>> b[4:0];                 // SRA
                4'd8: alu_calc = ($signed(a) < $signed(b)) ? 32'd1:0;   // SLT
                4'd9: alu_calc = (a < b) ? 32'd1:0;                     // SLTU
                default: alu_calc = 32'd0;
            endcase
        end
    endfunction

    integer i;

    // ----------------------------
    // Sequential
    // ----------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            state     <= S_FETCH;
            pc        <= 32'd0;
            ir        <= 32'd0;

            mem_valid <= 1'b0;
            mem_instr <= 1'b0;
            mem_addr  <= 32'd0;
            mem_wdata <= 32'd0;
            mem_wstrb <= 4'b0000;

            pcpi_valid <= 1'b0;
            pcpi_insn  <= 32'd0;
            pcpi_rs1   <= 32'd0;
            pcpi_rs2   <= 32'd0;

            trap      <= 1'b0;

            alu_out   <= 32'd0;
            wb_data   <= 32'd0;
            wb_en     <= 1'b0;
            wb_rd     <= 5'd0;

            is_load   <= 1'b0;
            is_store  <= 1'b0;
            load_f3   <= 3'd0;
            store_f3  <= 3'd0;
            take_branch <= 1'b0;

            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'd0;

        end else begin
            // hardwire x0
            regs[0] <= 32'd0;

            case (state)

                // ----------------------------
                // FETCH (instruction read)
                // ----------------------------
                S_FETCH: begin
                    trap      <= 1'b0;
                    wb_en     <= 1'b0;

                    // PCPI idle in fetch
                    pcpi_valid <= 1'b0;

                    mem_valid <= 1'b1;
                    mem_instr <= 1'b1;
                    mem_addr  <= pc;
                    mem_wstrb <= 4'b0000;

                    if (mem_ready) begin
                        ir        <= mem_rdata;
                        mem_valid <= 1'b0;
                        state     <= S_DECODE;
                    end
                end

                // ----------------------------
                // DECODE (classify + maybe launch PCPI)
                // ----------------------------
                S_DECODE: begin
                    is_load    <= 1'b0;
                    is_store   <= 1'b0;
                    load_f3    <= 3'd0;
                    store_f3   <= 3'd0;
                    take_branch <= 1'b0;

                    wb_en   <= 1'b0;
                    wb_rd   <= rd;
                    wb_data <= 32'd0;

                    // Launch PCPI if needed (held until ready/wait resolves)
                    if (wants_pcpi) begin
                        pcpi_valid <= 1'b1;
                        pcpi_insn  <= ir;
                        pcpi_rs1   <= rs1_val;
                        pcpi_rs2   <= rs2_val;
                        state      <= S_PCPI;
                    end else begin
                        pcpi_valid <= 1'b0;
                        state      <= S_EXEC;
                    end
                end

                // ----------------------------
                // PCPI wait/complete/illegal
                // ----------------------------
                S_PCPI: begin
                    // Hold request stable
                    pcpi_valid <= 1'b1;
                    pcpi_insn  <= ir;
                    pcpi_rs1   <= rs1_val;
                    pcpi_rs2   <= rs2_val;

                    // Do not use memory while stalling for PCPI
                    mem_valid <= 1'b0;
                    mem_wstrb <= 4'b0000;
                    mem_instr <= 1'b0;

                    if (pcpi_ready) begin
                        // Coprocessor produced a result
                        wb_en   <= (pcpi_wr && (rd != 0));
                        wb_rd   <= rd;
                        wb_data <= pcpi_rd;

                        pcpi_valid <= 1'b0;
                        pc <= pc + 32'd4;
                        state <= S_WB;

                    end else if (pcpi_wait) begin
                        // Coprocessor is busy; stall
                        state <= S_PCPI;

                    end else begin
                        // Nobody claimed it => illegal instruction
                        trap <= 1'b1;
                        pcpi_valid <= 1'b0;
                        // advance (Pico-style behavior is "trap"; your SoC can handle it)
                        pc <= pc + 32'd4;
                        state <= S_FETCH;
                    end
                end

                // ----------------------------
                // EXEC
                // ----------------------------
                S_EXEC: begin
                    case (opcode)

                        7'b0110111: begin // LUI
                            wb_en   <= (rd != 0);
                            wb_rd   <= rd;
                            wb_data <= imm_u;
                            pc      <= pc + 32'd4;
                            state   <= S_WB;
                        end

                        7'b0010111: begin // AUIPC
                            wb_en   <= (rd != 0);
                            wb_rd   <= rd;
                            wb_data <= pc + imm_u;
                            pc      <= pc + 32'd4;
                            state   <= S_WB;
                        end

                        7'b1101111: begin // JAL
                            wb_en   <= (rd != 0);
                            wb_rd   <= rd;
                            wb_data <= pc + 32'd4;
                            pc      <= pc + imm_j;
                            state   <= S_WB;
                        end

                        7'b1100111: begin // JALR
                            wb_en   <= (rd != 0);
                            wb_rd   <= rd;
                            wb_data <= pc + 32'd4;
                            pc      <= (rs1_val + imm_i) & 32'hFFFF_FFFE;
                            state   <= S_WB;
                        end

                        7'b1100011: begin // BRANCH
                            case (funct3)
                                3'b000: take_branch <= (rs1_val == rs2_val); // BEQ
                                3'b001: take_branch <= (rs1_val != rs2_val); // BNE
                                3'b100: take_branch <= ($signed(rs1_val) < $signed(rs2_val));  // BLT
                                3'b101: take_branch <= ($signed(rs1_val) >= $signed(rs2_val)); // BGE
                                3'b110: take_branch <= (rs1_val < rs2_val);   // BLTU
                                3'b111: take_branch <= (rs1_val >= rs2_val);  // BGEU
                                default: take_branch <= 1'b0;
                            endcase

                            if (take_branch) pc <= pc + imm_b;
                            else             pc <= pc + 32'd4;

                            state <= S_FETCH;
                        end

                        7'b0010011: begin // OP-IMM
                            wb_en <= (rd != 0);
                            wb_rd <= rd;
                            case (funct3)
                                3'b000: wb_data <= alu_calc(rs1_val, imm_i, 4'd0); // ADDI
                                3'b010: wb_data <= alu_calc(rs1_val, imm_i, 4'd8); // SLTI
                                3'b011: wb_data <= alu_calc(rs1_val, imm_i, 4'd9); // SLTIU
                                3'b100: wb_data <= alu_calc(rs1_val, imm_i, 4'd4); // XORI
                                3'b110: wb_data <= alu_calc(rs1_val, imm_i, 4'd3); // ORI
                                3'b111: wb_data <= alu_calc(rs1_val, imm_i, 4'd2); // ANDI
                                3'b001: wb_data <= alu_calc(rs1_val, {27'd0, ir[24:20]}, 4'd5); // SLLI
                                3'b101: begin
                                    if (funct7 == 7'b0000000)
                                        wb_data <= alu_calc(rs1_val, {27'd0, ir[24:20]}, 4'd6); // SRLI
                                    else
                                        wb_data <= alu_calc(rs1_val, {27'd0, ir[24:20]}, 4'd7); // SRAI
                                end
                                default: wb_data <= 32'd0;
                            endcase
                            pc    <= pc + 32'd4;
                            state <= S_WB;
                        end

                        7'b0110011: begin // OP (reg-reg) -- NOTE: MUL/DIV space already diverted to PCPI in DECODE
                            wb_en <= (rd != 0);
                            wb_rd <= rd;
                            case (funct3)
                                3'b000: wb_data <= (funct7 == 7'b0100000) ?
                                                   alu_calc(rs1_val, rs2_val, 4'd1) : // SUB
                                                   alu_calc(rs1_val, rs2_val, 4'd0);  // ADD
                                3'b001: wb_data <= alu_calc(rs1_val, rs2_val, 4'd5); // SLL
                                3'b010: wb_data <= alu_calc(rs1_val, rs2_val, 4'd8); // SLT
                                3'b011: wb_data <= alu_calc(rs1_val, rs2_val, 4'd9); // SLTU
                                3'b100: wb_data <= alu_calc(rs1_val, rs2_val, 4'd4); // XOR
                                3'b101: wb_data <= (funct7 == 7'b0100000) ?
                                                   alu_calc(rs1_val, rs2_val, 4'd7) : // SRA
                                                   alu_calc(rs1_val, rs2_val, 4'd6);  // SRL
                                3'b110: wb_data <= alu_calc(rs1_val, rs2_val, 4'd3); // OR
                                3'b111: wb_data <= alu_calc(rs1_val, rs2_val, 4'd2); // AND
                                default: wb_data <= 32'd0;
                            endcase
                            pc    <= pc + 32'd4;
                            state <= S_WB;
                        end

                        7'b0000011: begin // LOAD
                            is_load <= 1'b1;
                            load_f3 <= funct3;
                            alu_out <= rs1_val + imm_i;
                            state   <= S_MEM;
                        end

                        7'b0100011: begin // STORE
                            is_store <= 1'b1;
                            store_f3 <= funct3;
                            alu_out  <= rs1_val + imm_s;
                            state    <= S_MEM;
                        end

                        default: begin
                            trap  <= 1'b1;
                            pc    <= pc + 32'd4;
                            state <= S_FETCH;
                        end
                    endcase
                end

                // ----------------------------
                // MEM (data access)
                // ----------------------------
                S_MEM: begin
                    mem_valid <= 1'b1;
                    mem_instr <= 1'b0;
                    mem_addr  <= alu_out;

                    if (is_store) begin
                        case (store_f3)
                            3'b000: begin // SB
                                mem_wstrb <= 4'b0001 << alu_out[1:0];
                                mem_wdata <= {4{rs2_val[7:0]}} << (8*alu_out[1:0]);
                            end
                            3'b001: begin // SH
                                mem_wstrb <= (alu_out[1] ? 4'b1100 : 4'b0011);
                                mem_wdata <= {2{rs2_val[15:0]}} << (16*alu_out[1]);
                            end
                            3'b010: begin // SW
                                mem_wstrb <= 4'b1111;
                                mem_wdata <= rs2_val;
                            end
                            default: begin
                                mem_wstrb <= 4'b0000;
                                mem_wdata <= 32'd0;
                            end
                        endcase
                    end else begin
                        mem_wstrb <= 4'b0000;
                        mem_wdata <= 32'd0;
                    end

                    if (mem_ready) begin
                        mem_valid <= 1'b0;

                        if (is_load) begin
                            case (load_f3)
                                3'b000: begin // LB
                                    case (alu_out[1:0])
                                        2'd0: wb_data <= sext8(mem_rdata[7:0]);
                                        2'd1: wb_data <= sext8(mem_rdata[15:8]);
                                        2'd2: wb_data <= sext8(mem_rdata[23:16]);
                                        2'd3: wb_data <= sext8(mem_rdata[31:24]);
                                    endcase
                                end
                                3'b001: begin // LH
                                    wb_data <= alu_out[1] ? sext16(mem_rdata[31:16]) : sext16(mem_rdata[15:0]);
                                end
                                3'b010: begin // LW
                                    wb_data <= mem_rdata;
                                end
                                3'b100: begin // LBU
                                    case (alu_out[1:0])
                                        2'd0: wb_data <= {24'd0, mem_rdata[7:0]};
                                        2'd1: wb_data <= {24'd0, mem_rdata[15:8]};
                                        2'd2: wb_data <= {24'd0, mem_rdata[23:16]};
                                        2'd3: wb_data <= {24'd0, mem_rdata[31:24]};
                                    endcase
                                end
                                3'b101: begin // LHU
                                    wb_data <= alu_out[1] ? {16'd0, mem_rdata[31:16]} : {16'd0, mem_rdata[15:0]};
                                end
                                default: wb_data <= mem_rdata;
                            endcase

                            wb_en <= (rd != 0);
                            wb_rd <= rd;

                            pc    <= pc + 32'd4;
                            state <= S_WB;
                        end else begin
                            // store done
                            pc    <= pc + 32'd4;
                            state <= S_FETCH;
                        end
                    end
                end

                // ----------------------------
                // WB
                // ----------------------------
                S_WB: begin
                    if (wb_en && (wb_rd != 0)) begin
                        regs[wb_rd] <= wb_data;
                    end
                    state <= S_FETCH;
                end

                default: state <= S_FETCH;
            endcase
        end
    end

endmodule
