// socvm.cpp -- memory, address decode, load/store and the BitBlt-adjacent
// helpers.  Direct port of the matching parts of rv32i_soc_vm.py.

#include "socvm.h"

#include <cmath>
#include <cstdio>

namespace socvm {

std::string hexs(uint64_t v) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%#llx", (unsigned long long)v);
    return std::string(buf);
}

std::string vfmt(const char* f, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, f);
    std::vsnprintf(buf, sizeof(buf), f, ap);
    va_end(ap);
    return std::string(buf);
}

// Python: (val & MASK[bits]) - ((val & SIGN[bits]) << 1), evaluated with
// unbounded ints.  In 32-bit wrapping arithmetic the same expression gives the
// same two's-complement result.
static inline int32_t sign_extend(uint32_t val, int bits) {
    uint32_t mask = (bits >= 32) ? 0xFFFFFFFFu : ((1u << bits) - 1u);
    uint32_t sgn  = (bits >= 32) ? 0x80000000u : (1u << (bits - 1));
    return (int32_t)((val & mask) - ((val & sgn) << 1));
}

// ---------------------------------------------------------------------------
SapphireSoCVM::SapphireSoCVM(const std::vector<uint32_t>& code_words,
                             int lat, uint32_t stack_floor_, py::object bss)
    : latency(lat), stack_floor(stack_floor_)
{
    ram.assign(RAM_SIZE, 0);
    for (size_t i = 0; i < code_words.size(); ++i) {
        uint32_t w = code_words[i];
        size_t o = i * 4;
        ram[o + 0] = (uint8_t)(w & 0xFF);
        ram[o + 1] = (uint8_t)((w >> 8) & 0xFF);
        ram[o + 2] = (uint8_t)((w >> 16) & 0xFF);
        ram[o + 3] = (uint8_t)((w >> 24) & 0xFF);
    }
    image_end = RAM_BASE + (uint32_t)code_words.size() * 4u;

    if (!bss.is_none()) {
        py::tuple t = bss.cast<py::tuple>();
        has_bss   = true;
        bss_start = t[0].cast<uint32_t>();
        bss_end   = t[1].cast<uint32_t>();
    }

    scratch.assign(SCRATCH_SIZE, 0);

    // B1: the scanout's tile store and palette.  Zeroed here so that a fresh
    // machine - which has not booted the firmware that loads them - draws no
    // bullets instead of drawing whatever happened to be in the allocation.
    btile.assign(TILE_STORE_BYTES, 0);
    bpal.assign(PALETTE_ENTRIES, 0u);

    std::memset(regs, 0, sizeof(regs));
    pc = RAM_BASE;
    steps = 0;
    tick_left = TICK_STEPS;
    min_sp = RAM_BASE + RAM_SIZE;

    fbA.assign(FRAME_WORDS, 0xDEADBEEFu);
    fbB.assign(FRAME_WORDS, 0xDEADBEEFu);

    active = request = FRAME_BASE_A;
    right_active = right_request = FRAME_BASE_A;

    // Buffer-protocol views, built once here and then handed out as plain
    // attributes.  As pybind11 properties they cost about 1 us per access, and
    // the workbench indexes vm.scratch element by element in its inner loops
    // (153 million times in one scenario) -- that alone was 150+ seconds.
    view_ram = py::memoryview::from_memory(ram.data(), (py_ssize_t)ram.size(), false);
    view_scratch = py::memoryview::from_memory(scratch.data(), (py_ssize_t)scratch.size(), false);
    view_scratch32 = py::memoryview::from_buffer((uint32_t*)scratch.data(),
                                                 sizeof(uint32_t), "I",
                                                 {(py_ssize_t)(scratch.size() / 4)},
                                                 {(py_ssize_t)sizeof(uint32_t)}, false);
    view_fbA = py::memoryview::from_buffer(fbA.data(), sizeof(uint32_t), "I",
                                           {(py_ssize_t)FRAME_WORDS},
                                           {(py_ssize_t)sizeof(uint32_t)}, false);
    view_fbB = py::memoryview::from_buffer(fbB.data(), sizeof(uint32_t), "I",
                                           {(py_ssize_t)FRAME_WORDS},
                                           {(py_ssize_t)sizeof(uint32_t)}, false);
    {
        py::dict d;
        d[py::int_(FRAME_BASE_A)] = view_fbA;
        d[py::int_(FRAME_BASE_B)] = view_fbB;
        view_fb = d;
    }

    last_alpha = py::none();
    last_alpha_cfg = py::none();
    last_alpha_before = py::none();
    last_alpha_rect = py::none();
    last_copy = py::none();
    last_sprite_copy = py::none();
    last_boss_copy = py::none();
}

// ---------------------------------------------------------------------------
uint32_t SapphireSoCVM::frame_of(uint32_t addr) const {
    if (addr >= FRAME_BASE_A && addr < FRAME_BASE_A + FRAME_BYTES) return FRAME_BASE_A;
    if (addr >= FRAME_BASE_B && addr < FRAME_BASE_B + FRAME_BYTES) return FRAME_BASE_B;
    return 0;
}

bool SapphireSoCVM::in_scratch(uint32_t addr, uint64_t size) const {
    return addr >= SCRATCH_BASE &&
           (uint64_t)addr <= (uint64_t)SCRATCH_BASE + (uint64_t)SCRATCH_SIZE - size;
}

uint32_t* SapphireSoCVM::fb_words(uint32_t base) {
    if (base == FRAME_BASE_A) return fbA.data();
    if (base == FRAME_BASE_B) return fbB.data();
    throw VMError(vfmt("bad framebuffer base %#x", base));
}

const uint32_t* SapphireSoCVM::fb_words_c(uint32_t base) const {
    if (base == FRAME_BASE_A) return fbA.data();
    if (base == FRAME_BASE_B) return fbB.data();
    throw VMError(vfmt("bad framebuffer base %#x", base));
}

uint32_t* SapphireSoCVM::fb_ptr(uint32_t base) { return fb_words(base); }

void SapphireSoCVM::check_owner(uint32_t base, bool has_x, int x, bool hw) {
    if (hw) {
        if (base == right_active)
            throw VMError(vfmt("BitBlt wrote the SCAN active right buffer %#x at PC=%#x",
                               base, pc));
    } else {
        bool half = has_x ? (x >= HALF_PIXELS) : false;
        if (base == active && !(has_x && half))
            throw VMError(vfmt("Prohibited write to SCAN active left buffer %#x at PC=%#x",
                               base, pc));
    }
}

void SapphireSoCVM::drain() {
    if (pending.empty()) return;
    for (const auto& kv : pending) {
        uint32_t base = frame_of(kv.first);
        if (base) fb_words(base)[(kv.first - base) / 4] = kv.second;
    }
    pending.clear();
}

uint32_t SapphireSoCVM::scratch_word(uint32_t byte_off) const {
    uint32_t w;
    std::memcpy(&w, scratch.data() + byte_off, 4);
    return w;
}

uint32_t SapphireSoCVM::params_get(uint32_t key, uint32_t dflt) const {
    py::object k = py::int_(key);
    if (params.contains(k)) return params[k].cast<uint32_t>();
    return dflt;
}

// ---------------------------------------------------------------------------
uint32_t SapphireSoCVM::load(uint32_t addr, int size, bool sgn) {
    if (size == 4 && !sgn && (addr & 3) == 0 &&
        addr >= RAM_BASE && addr <= RAM_BASE + RAM_SIZE - 4) {
        return ((const uint32_t*)ram.data())[(addr - RAM_BASE) >> 2];
    }
    if (addr >= RAM_BASE && (uint64_t)addr <= (uint64_t)RAM_BASE + RAM_SIZE - size) {
        uint32_t v = 0;
        std::memcpy(&v, ram.data() + (addr - RAM_BASE), size);
        if (sgn) {
            if (size == 1) return (uint32_t)(int32_t)(int8_t)v;
            if (size == 2) return (uint32_t)(int32_t)(int16_t)v;
        }
        return v;
    }
    if (in_scratch(addr, size)) {
        uint32_t v = 0;
        std::memcpy(&v, scratch.data() + (addr - SCRATCH_BASE), size);
        if (sgn) {
            if (size == 1) return (uint32_t)(int32_t)(int8_t)v;
            if (size == 2) return (uint32_t)(int32_t)(int16_t)v;
        }
        return v;
    }
    if (size != 4)
        throw VMError("only word accesses are modelled outside RAM/scratch");

    if (addr == 0xF8B0BFF8u)
        return (uint32_t)((steps * 100000000ull) / ((uint64_t)TICK_STEPS * 75ull));
    if (addr == APB_BASE) {
        bool busy = steps < busy_until;
        return (uint32_t)((busy ? 1u : 0u) | (((done && !busy) ? 1u : 0u) << 1));
    }
    if (addr == APB_BASE + 0x24) { uint32_t v = vsync ? 1u : 0u; vsync = false; return v; }
    if (addr == APB_BASE + 0x28) return active;
    if (addr == APB_BASE + 0x2C) return right_active;
    if (addr == APB_BASE + 0x34) return params_get(0x34, 0);
    if (addr == APB_BASE + 0x38) return cpu_frames;
    if (addr == APB_BASE + 0x3C) return fpga_frames;
    if (addr == APB_BASE + 0x40) return right_request;
    if (addr == APB_BASE + 0x50) return joy;
    if (addr == APB_BASE + 0x54) return btn;
    if (addr == APB_BASE + 0x58) return board_keys;
    if (addr == APB_BASE + 0x5C) return params_get(0x5C, 0x0001005Au);
    if (addr == APB_BASE + 0x70)
        return (uint32_t)((steps * 100000000ull) / ((uint64_t)TICK_STEPS * 75ull));
    if (addr == APB_BASE + 0x44) return 0;
    if (addr == APB_BASE + 0x74) return 0;
    // These four are INSIDE the 0x00..0xFF APB window, so they have to be
    // answered before the catch-all below - the catch-all used to sit above
    // them and returned params for an offset nobody stores, so the asset ROM
    // byte window read back a constant 0 and gpu2d_asset_copy() filled
    // MM_STAGE_RLE with zeros.  Both backends had the same branch order, so
    // they agreed with each other and neither agreed with the board.

    if (addr == APB_BASE + 0x78) return params_get(0x78, 0);
    if (addr == APB_BASE + 0x7C) return params_get(0x7C, 0);
    if (addr == APB_BASE + 0x88) return params_get(0x88, 0);

    if (addr == APB_BASE + 0x84) {
        uint32_t i = asset_addr;
        return (i < asset_rom.size()) ? (uint32_t)asset_rom[i] : 0u;
    }

    if (addr == APB_BASE + 0x120) return bucket_status;
    if (addr == APB_BASE + 0x124) return bucket_player_xy;
    if (addr == APB_BASE + 0x128) return bucket_info;
    if (addr >= APB_BASE && addr < APB_BASE + 0x100)
        return params_get(addr - APB_BASE, 0);

    if (addr >= UART_BASE && addr < UART_BASE + 0x40)
        return ((addr - UART_BASE) == 0x04) ? (0xFFu << 16) : 0u;

    uint32_t base = frame_of(addr);
    if (!base) throw VMError(vfmt("unmapped load %#x at PC=%#x", addr, pc));
    if (addr % 4 != 0) throw VMError(vfmt("unaligned pixel load %#x", addr));
    drain();
    return fb_words(base)[(addr - base) / 4];
}

// ---------------------------------------------------------------------------
void SapphireSoCVM::bucket_accel(uint32_t control) {
    // Mirrors simulator/bucket_model.py: 1024 slots, stride 4096, 15-bit
    // enemy count, pool 20480, motion writeback and the candidate list.
    if (control & 0x40000000u) {
        std::memset(bucket_used, 0, sizeof(bucket_used));
        return;
    }
    if (!(control & 0x80000000u)) return;
    const unsigned buffer = control & 1u;
    const uint32_t table = 0x04800000u + buffer * (96u * 4096u);
    const unsigned EB_CAP = 20480u, FRONT = EB_CAP - 32u, SLOTS = 1024u;
    const uint32_t cand_base = 0x01675400u + EB_CAP * 8u + (EB_CAP - 512u) * 2u;
    unsigned counts[96] = {}, drops = 0, live = 0;
    const bool motion = (control & 0x20000000u) != 0;
    const unsigned eb = std::min((((control >> 16) & 0x1FFFu) | ((control & 0xC000u) >> 1)), FRONT);
    const unsigned pb = std::min((control >> 4) & 1023u, 512u);
    const int px = (int16_t)bucket_player_xy, py = (int16_t)(bucket_player_xy >> 16);
    const unsigned rows[27] = {647,647,710,742,742,742,710,647,647,647,677,676,676,676,677,647,832,481,832,768,768,768,768,768,768,768,768};
    std::vector<unsigned> candidates;
    auto aim = [](int dx, int dy) {
        int ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
        int q = 5*ay <= ax ? 0 : 3*ay <= 2*ax ? 1 : 2*ay <= 3*ax ? 2 : ay <= 5*ax ? 3 : 4;
        if (dx == 0 && dy == 0) return 4;
        if (dx < 0) q = 8-q;
        return (dy < 0 ? -q : q) & 15;
    };
    auto emit = [&](uint32_t address, unsigned index, bool player, bool tail) {
        auto *b = scratch.data() + address - SCRATCH_BASE;
        int16_t x, y; std::memcpy(&x, b, 2); std::memcpy(&y, b + 2, 2);
        int vx = (int8_t)b[4], vy = (int8_t)b[5];
        unsigned flags = b[6], color = b[7];
        if (!(flags & 1)) return;
        if (!player && motion && !tail && !(flags & 8)) {
            x = (int16_t)(x + vx); y = (int16_t)(y + vy);
            if (x < 182 || x > 1169 || y < 1 || y > 767) {
                store(address + 6, flags & ~1u, 1);
                return;
            }
            store(address, (uint16_t)x | ((uint32_t)(uint16_t)y << 16), 4);
            if (std::abs(x - px) <= 15 && std::abs(y - py) <= 15) candidates.push_back(index);
        }
        if (!player) ++live;
        int slot, width, row, bx;
        if (player) { slot = flags & 2 ? 18 : 16; width = slot == 18 ? 13 : 7; row = y; bx = x; }
        else if (flags & 8) { slot = 19 + (aim(vx, vy) >> 1); width = 24; row = y - 12; bx = x - 12; }
        else if (flags & 64) { slot = 17; width = 16; row = y - 8; bx = x - 8; }
        else {
            if (flags & 4 || !(vx || vy)) slot = aim(px - x, py - y);
            else if (color & 128) slot = (color >> 3) & 15;
            else slot = aim(vx, vy);
            width = 26; row = y - 13; bx = x - 13;
        }
        const int lo = std::max(row + (int)(rows[slot] & 31), 0);
        const int hi = std::min(row + (int)(rows[slot] >> 5), 768);
        if (lo >= hi) return;
        for (int g = lo / 8; g <= (hi - 1) / 8; ++g) {
            if (counts[g] >= SLOTS) { ++drops; continue; }
            const uint32_t word = ((color & 7) << 29) | (width << 24) | (slot << 17) | (((g * 8 - row + 8) & 63) << 11) | (bx & 2047);
            store(table + g * 4096u + counts[g]++ * 4u, word);
        }
    };
    for (unsigned i = 0; i < pb; ++i) emit(0x01620000u + i * 8u, i, true, false);
    for (unsigned i = 0; i < eb; ++i) emit(0x01675400u + i * 8u, i, false, false);
    for (unsigned i = FRONT; i < EB_CAP; ++i) emit(0x01675400u + i * 8u, i, false, true);
    for (unsigned g = 0; g < 96; ++g) {
        for (unsigned k = counts[g]; k < bucket_used[buffer][g]; ++k) store(table + g * 4096u + k * 4u, 0);
        bucket_used[buffer][g] = (uint16_t)counts[g];
        store(0x048C1000u + buffer * 192u + g * 2u, counts[g], 2);
    }
    if (motion) {
        const unsigned n = std::min<unsigned>(candidates.size(), 512u);
        for (unsigned i = 0; i < n; ++i) store(cand_base + i * 2u, candidates[i], 2);
        bucket_info = (std::min<unsigned>(candidates.size(), 65535u) << 16) | (live & 65535u);
    }
    bucket_status = 0x20000000u | std::min(drops, 65535u);
}

void SapphireSoCVM::store(uint32_t addr, uint32_t val, int size) {
    if (size < 4) val &= ((1u << (size * 8)) - 1u);

    if (addr >= RAM_BASE && (uint64_t)addr <= (uint64_t)RAM_BASE + RAM_SIZE - size) {
        uint32_t floor_ = has_bss ? bss_start : image_end;
        if (addr < floor_)
            throw VMError(vfmt("CODE OVERWRITE: store=%#x, writable from %#x, PC=%#x",
                               addr, floor_, pc));
        uint32_t o = addr - RAM_BASE;
        if (size == 4 && (addr & 3) == 0) ((uint32_t*)ram.data())[o >> 2] = val;
        else std::memcpy(ram.data() + o, &val, size);
        return;
    }
    if (in_scratch(addr, size)) {
        std::memcpy(scratch.data() + (addr - SCRATCH_BASE), &val, size);
        return;
    }
    if (size != 4)
        throw VMError("only word stores are modelled outside RAM/scratch");

    if (addr == APB_BASE + 0x120) { bucket_accel(val); return; }
    if (addr == APB_BASE + 0x124) { bucket_player_xy = val; return; }
    if (addr >= APB_BASE && addr < APB_BASE + 0x100) {
        apb_store(addr - APB_BASE, val);
        return;
    }
    if (addr >= UART_BASE && addr < UART_BASE + 0x40) {
        uint32_t off = addr - UART_BASE;
        if (off == 0x00) uart_out.append(py::int_(val & 0xFF));
        else uart_cfg[py::int_(off)] = py::int_(val);
        return;
    }
    uint32_t base = frame_of(addr);
    if (!base) {
        std::printf("UNMAPPED STORE %#x pc=%#x\n", addr, pc);
        throw VMError(vfmt("unmapped store %#x at PC=%#x", addr, pc));
    }
    if (addr % 4 != 0) throw VMError(vfmt("unaligned pixel store %#x", addr));
    check_owner(base, true, (int)(((addr - base) / 4) % SCREEN_PITCH), false);
    pending[addr] = val;
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Pool scans (see socvm.h).  Byte-for-byte the same predicates the Python
// helpers used, just without a Python loop per element.
// ---------------------------------------------------------------------------
uint32_t SapphireSoCVM::count_masked(uint32_t start, uint32_t count,
                                     uint32_t stride, uint32_t mask) {
    const uint8_t* p = scratch.data() + start;
    uint32_t n = 0;
    for (uint32_t i = 0; i < count; ++i, p += stride)
        if ((*p & mask) != 0) ++n;
    return n;
}

uint32_t SapphireSoCVM::count_nonzero(uint32_t start, uint32_t count, uint32_t stride) {
    const uint8_t* p = scratch.data() + start;
    uint32_t n = 0;
    for (uint32_t i = 0; i < count; ++i, p += stride)
        if (*p != 0) ++n;
    return n;
}

uint32_t SapphireSoCVM::count_moving(uint32_t start, uint32_t count, uint32_t stride) {
    const uint8_t* p = scratch.data() + start;
    uint32_t n = 0;
    for (uint32_t i = 0; i < count; ++i, p += stride)
        if ((p[6] & 0x01u) && (p[4] != 0 || p[5] != 0)) ++n;
    return n;
}

// ---------------------------------------------------------------------------
// Wait primitives (see socvm.h).  Semantics are exactly the Python loops they
// replace, including the order of the checks and what is returned.
// ---------------------------------------------------------------------------
uint64_t SapphireSoCVM::run_until_word_ne(uint32_t word_index, uint32_t value,
                                          uint64_t budget) {
    const uint32_t* w = (const uint32_t*)scratch.data();
    uint64_t spent = 0;
    while (spent < budget && w[word_index] != value) { step(); ++spent; }
    return spent;
}

uint64_t SapphireSoCVM::run_until_publish(uint32_t was, uint64_t budget) {
    uint64_t spent = 0;
    while (right_request == was && spent < budget) { step(); ++spent; }
    return spent;
}

void SapphireSoCVM::trace_blit(const char* kind, uint32_t dst, uint32_t src,
                               uint32_t w, uint32_t h, uint32_t extra) {
    blit_trace.append(py::make_tuple(py::int_(steps), py::str(kind), py::int_(dst),
                                     py::int_(src), py::int_(w), py::int_(h),
                                     py::int_(extra)));
    while (blit_trace.size() > 400) blit_trace.attr("pop")(0);
}

void SapphireSoCVM::dump_blit_trace(int n) {
    py_ssize_t total = blit_trace.size();
    py_ssize_t start = (n >= total) ? 0 : total - n;
    for (py_ssize_t i = start; i < total; ++i) {
        py::tuple rec = blit_trace[i].cast<py::tuple>();
        std::printf("  trace steps=%llu %s dst=%#x src=%#x %dx%d arg6=%#x\n",
                    (unsigned long long)rec[0].cast<uint64_t>(),
                    rec[1].cast<std::string>().c_str(),
                    rec[2].cast<uint32_t>(), rec[3].cast<uint32_t>(),
                    rec[4].cast<uint32_t>(), rec[5].cast<uint32_t>(),
                    rec[6].cast<uint32_t>());
    }
}

}  // namespace socvm
