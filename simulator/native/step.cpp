// step.cpp -- the RV32I/RV32M interpreter loop.
//
// Direct port of SapphireSoCVM.step() in rv32i_soc_vm.py.  The dispatch order is
// the one the Python side measured (OP-IMM 40%, BRANCH 24%, LOAD 16%, STORE
// 5.5%, LUI 5.3%, OP 4%, JALR 3.5%, AUIPC 1.8%, JAL 0.4%), so the C++ version
// sees the same branch-prediction profile.

#include "socvm.h"

#include <cstdio>

namespace socvm {

static inline int32_t sign_extend(uint32_t val, int bits) {
    uint32_t mask = (bits >= 32) ? 0xFFFFFFFFu : ((1u << bits) - 1u);
    uint32_t sgn  = (bits >= 32) ? 0x80000000u : (1u << (bits - 1));
    return (int32_t)((val & mask) - ((val & sgn) << 1));
}

// Arithmetic shift right, matching Python's >> on a negative int.
static inline uint32_t asr32(uint32_t v, uint32_t sh) {
    int32_t s = (int32_t)v;
    return (uint32_t)(s >> (sh & 31u));
}

void SapphireSoCVM::step() {
    uint32_t pcv = pc;
    uint32_t* r = regs;

    if (!(pcv >= RAM_BASE && pcv < image_end && (pcv & 3u) == 0))
        throw VMError(vfmt("bad PC %#x (image ends at %#x)", pcv, image_end));

    uint32_t ins = ((const uint32_t*)ram.data())[(pcv - RAM_BASE) >> 2];
    uint32_t op  = ins & 0x7Fu;
    uint32_t rd  = (ins >> 7) & 0x1Fu;
    uint32_t f3  = (ins >> 12) & 0x07u;
    uint32_t rs1 = (ins >> 15) & 0x1Fu;
    uint32_t rs2 = (ins >> 20) & 0x1Fu;
    uint32_t f7  = ins >> 25;

    uint32_t a = r[rs1];
    uint32_t b = r[rs2];
    uint32_t npc = pcv + 4u;
    bool has_result = false;
    uint32_t result = 0;

    if (op == 0x13u) {                                  // OP-IMM
        int32_t imm = sign_extend(ins >> 20, 12);
        if (f3 == 0)      { result = (uint32_t)(a + (uint32_t)imm); has_result = true; }
        else if (f3 == 2) { result = ((int32_t)a < imm) ? 1u : 0u; has_result = true; }
        else if (f3 == 3) { result = (a < (uint32_t)imm) ? 1u : 0u; has_result = true; }
        else if (f3 == 4) { result = a ^ (uint32_t)imm; has_result = true; }
        else if (f3 == 6) { result = a | (uint32_t)imm; has_result = true; }
        else if (f3 == 7) { result = a & (uint32_t)imm; has_result = true; }
        else if (f3 == 1 && f7 == 0x00u) { result = a << (rs2 & 31u); has_result = true; }
        else if (f3 == 5 && f7 == 0x00u) { result = a >> (rs2 & 31u); has_result = true; }
        else if (f3 == 5 && f7 == 0x20u) { result = asr32(a, rs2); has_result = true; }
        else throw VMError(vfmt("unknown OP-IMM %#x", ins));
    }
    else if (op == 0x63u) {                             // BRANCH
        uint32_t imm = ((ins >> 31) << 12) | (((ins >> 7) & 1u) << 11) |
                       (((ins >> 25) & 0x3Fu) << 5) | (((ins >> 8) & 0x0Fu) << 1);
        bool take;
        if (f3 == 0)      take = (a == b);
        else if (f3 == 1) take = (a != b);
        else if (f3 == 4) take = ((int32_t)a < (int32_t)b);
        else if (f3 == 5) take = ((int32_t)a >= (int32_t)b);
        else if (f3 == 6) take = (a < b);
        else if (f3 == 7) take = (a >= b);
        else throw VMError(vfmt("unknown BRANCH %#x", ins));
        if (take) npc = pcv + (uint32_t)sign_extend(imm, 13);
    }
    else if (op == 0x03u) {                             // LOAD
        uint32_t addr = (uint32_t)(a + (uint32_t)sign_extend(ins >> 20, 12));
        if (f3 == 0)      { result = load(addr, 1, true);  has_result = true; }
        else if (f3 == 1) { result = load(addr, 2, true);  has_result = true; }
        else if (f3 == 2) { result = load(addr, 4, false); has_result = true; }
        else if (f3 == 4) { result = load(addr, 1, false); has_result = true; }
        else if (f3 == 5) { result = load(addr, 2, false); has_result = true; }
        else throw VMError(vfmt("unknown LOAD %#x", ins));
    }
    else if (op == 0x23u) {                             // STORE
        uint32_t imm = ((ins >> 25) << 5) | ((ins >> 7) & 0x1Fu);
        uint32_t addr = (uint32_t)(a + (uint32_t)sign_extend(imm, 12));
        if (f3 == 0)      store(addr, b, 1);
        else if (f3 == 1) store(addr, b, 2);
        else if (f3 == 2) store(addr, b, 4);
        else throw VMError(vfmt("unknown STORE %#x", ins));
    }
    else if (op == 0x37u) {                             // LUI
        result = ins & 0xFFFFF000u; has_result = true;
    }
    else if (op == 0x33u) {                             // OP (incl. RV32M)
        if (f7 == 0x01u) {
            int32_t sa = (int32_t)a;
            int32_t sb = (int32_t)b;
            if (f3 == 0)      { result = (uint32_t)(a * b); has_result = true; }
            else if (f3 == 1) { result = (uint32_t)(((int64_t)sa * (int64_t)sb) >> 32); has_result = true; }
            else if (f3 == 2) { result = (uint32_t)(((int64_t)sa * (int64_t)(uint64_t)b) >> 32); has_result = true; }
            else if (f3 == 3) { result = (uint32_t)(((uint64_t)a * (uint64_t)b) >> 32); has_result = true; }
            else if (f3 == 4) {
                if (sb == 0) result = 0xFFFFFFFFu;
                else if (sa == (int32_t)0x80000000 && sb == -1) result = 0x80000000u;
                else result = (uint32_t)((int64_t)sa / (int64_t)sb);
                has_result = true;
            }
            else if (f3 == 5) { result = (b == 0) ? 0xFFFFFFFFu : (a / b); has_result = true; }
            else if (f3 == 6) {
                if (sb == 0) result = a;
                else if (sa == (int32_t)0x80000000 && sb == -1) result = 0u;
                else result = (uint32_t)((int64_t)sa % (int64_t)sb);
                has_result = true;
            }
            else if (f3 == 7) { result = (b == 0) ? a : (a % b); has_result = true; }
            else throw VMError(vfmt("unknown RV32M %#x", ins));
        }
        else if (f3 == 0 && f7 == 0x00u) { result = a + b; has_result = true; }
        else if (f3 == 0 && f7 == 0x20u) { result = a - b; has_result = true; }
        else if (f3 == 1 && f7 == 0x00u) { result = a << (b & 31u); has_result = true; }
        else if (f3 == 2 && f7 == 0x00u) { result = ((int32_t)a < (int32_t)b) ? 1u : 0u; has_result = true; }
        else if (f3 == 3 && f7 == 0x00u) { result = (a < b) ? 1u : 0u; has_result = true; }
        else if (f3 == 4 && f7 == 0x00u) { result = a ^ b; has_result = true; }
        else if (f3 == 5 && f7 == 0x00u) { result = a >> (b & 31u); has_result = true; }
        else if (f3 == 5 && f7 == 0x20u) { result = asr32(a, b); has_result = true; }
        else if (f3 == 6 && f7 == 0x00u) { result = a | b; has_result = true; }
        else if (f3 == 7 && f7 == 0x00u) { result = a & b; has_result = true; }
        else throw VMError(vfmt("unknown OP %#x", ins));
    }
    else if (op == 0x67u && f3 == 0) {                  // JALR
        result = npc; has_result = true;
        npc = (uint32_t)(a + (uint32_t)sign_extend(ins >> 20, 12)) & ~1u;
    }
    else if (op == 0x17u) {                             // AUIPC
        result = (uint32_t)(pcv + (ins & 0xFFFFF000u)); has_result = true;
    }
    else if (op == 0x6Fu) {                             // JAL
        uint32_t imm = ((ins >> 31) << 20) | (((ins >> 12) & 0xFFu) << 12) |
                       (((ins >> 20) & 1u) << 11) | (((ins >> 21) & 0x3FFu) << 1);
        result = npc; has_result = true;
        npc = pcv + (uint32_t)sign_extend(imm, 21);
    }
    else if (ins == 0x0000500Fu) {                      // Sapphire dcache flush
        drain();
    }
    else if (ins == 0x0000000Fu) {
        /* FENCE: no-op */
    }
    else if (op == 0x0Fu && f3 == 0) {
        /* FENCE / FENCE.I: no-op */
    }
    else {
        throw VMError(vfmt("illegal instruction %#010x at PC=%#x", ins, pcv));
    }

    if (has_result && rd != 0) r[rd] = result;

    uint32_t sp = r[2];
    if (sp >= RAM_BASE && sp < RAM_BASE + RAM_SIZE && sp < min_sp) {
        min_sp = sp;
        if (sp < stack_floor)
            throw VMError(vfmt("stack overflow: sp=%#x below floor %#x", sp, stack_floor));
    }

    pc = npc;
    steps += 1;

    tick_left -= 1;
    if (tick_left <= 0) {
        tick_left = TICK_STEPS;
        if (active != request)             cpu_frames  += 1u;
        if (right_active != right_request) fpga_frames += 1u;
        active = request;
        right_active = right_request;
        vsync = true;
    }
}

void SapphireSoCVM::step_n(uint64_t n) {
    for (uint64_t i = 0; i < n; ++i) step();
}

}  // namespace socvm
