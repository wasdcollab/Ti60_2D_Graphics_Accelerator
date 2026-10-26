// socvm.h -- C++ core for the Ti60 2D graphics accelerator virtual machine.
//
// Port of simulator/rv32i_soc_vm.py (which stays in the tree as the reference
// implementation).  Semantics must match it exactly: every assert, every
// address decode, every BitBlt byte.  The verification protocol is in
// 仿真优化.md -- 154 key output lines must match the Python baseline byte for
// byte across all 25 scenarios.

#pragma once

#include <cstdint>
#include <cstring>
#include <cstdarg>
#include <string>
#include <vector>
#include <unordered_map>
#include <stdexcept>
#include <algorithm>

#include <pybind11/pybind11.h>
#include <pybind11/stl.h>

namespace py = pybind11;

namespace socvm {

// MSVC has no POSIX ssize_t; pybind11 ships py_ssize_t for exactly this.
using py_ssize_t = py::ssize_t;

// ---------------------------------------------------------------- memory map
constexpr uint32_t RAM_BASE        = 0xF9000000u;
constexpr uint32_t RAM_SIZE        = 64u * 1024u;
constexpr uint32_t RAM_STACK_FLOOR = 0xF900FC00u;

constexpr uint32_t APB_BASE        = 0xF8100000u;

constexpr int SCREEN_W      = 1366;
constexpr int SCREEN_H      = 768;
constexpr int SCREEN_STRIDE = 8192;
constexpr int SCREEN_PITCH  = SCREEN_STRIDE / 4;
constexpr int HALF_PIXELS   = 640;

constexpr uint32_t FRAME_BASE_A = 0x00800000u;
constexpr uint32_t FRAME_BASE_B = 0x00E00000u;
constexpr uint32_t FRAME_BYTES  = static_cast<uint32_t>(SCREEN_H) * SCREEN_STRIDE;
constexpr uint32_t FRAME_WORDS  = FRAME_BYTES / 4u;

constexpr uint32_t SCRATCH_BASE = 0x01600000u;
// 52 MB, not 48: B1 added the bullet bucket table at 0x0480_0000, which the
// workbench has to be able to read back - it is the only record of what the
// firmware told the scanout to draw.
constexpr uint32_t SCRATCH_SIZE = 0x3400000u;

constexpr uint32_t UART_BASE    = 0xF8010000u;

// The scanout's tile store: one byte per pixel, a shape ROLE, 0 transparent.
// 8 KB because the depth has to be a power of two and the firmware's shapes use
// 3,792 bytes of it (rtl/v_dma/video_bullet_overlay.v).  It was 32 KB while a
// tile byte was a palette index and each colour needed its own copy; the colour
// is a hue page now (index = role + hue*32) and the copies are gone.  Sized to
// the real depth on purpose: a firmware write past it is a bug, and this is
// where it should show up rather than silently landing in the buffer.
// 256 palette entries because the index is 8 bits wide; the firmware fills 198
// distinct colours into it across 27 roles x 8 pages.
// 16 KB, up from 8: the colour split shrank the store, and the doubled enemy
// bullet (16 tiles at 26x26, a 32-byte row stride) took most of it back.
constexpr uint32_t TILE_STORE_BYTES = 0x8000u;
constexpr uint32_t PALETTE_ENTRIES  = 256u;

constexpr int64_t TICK_STEPS = 25000;

// --------------------------------------------------------------- error type
// The Python reference raises AssertionError carrying a formatted message, and
// that text is observable (scenario failures quote it), so the C++ side raises
// with the same strings and the binding layer turns it into the same exception
// class the Python code already catches.
struct VMError : std::runtime_error {
    explicit VMError(const std::string& what) : std::runtime_error(what) {}
};

std::string hexs(uint64_t v);
std::string vfmt(const char* f, ...);

// -------------------------------------------------------------------- the VM
class SapphireSoCVM {
public:
    // ---- memory -----------------------------------------------------------
    std::vector<uint8_t>  ram;
    std::vector<uint8_t>  scratch;
    std::vector<uint32_t> fbA, fbB;
    std::vector<uint8_t>  asset_rom;
    uint32_t asset_addr = 0;

    // ---- B1: the scanout's tile store and its palette ----------------------
    // The firmware loads both once at boot through APB 0xF8 (one byte per
    // write, write pointer 0xF4) and 0xFC (one 24-bit palette entry, pointer
    // implied).  Until this existed the native kernel recorded those registers
    // in params and threw the payload away, because the load and row
    // accounting never needed it - but the scanout compositor does: without
    // the store the bullet curtain cannot be drawn at all, so a picture
    // exported through the native kernel (the default one) came out with no
    // bullets in it.  Same 8 KB depth and 256 entries as the Python kernel.
    std::vector<uint8_t>  btile;
    std::vector<uint32_t> bpal;

    uint32_t image_end = RAM_BASE;
    bool     has_bss   = false;
    uint32_t bss_start = 0;
    uint32_t bss_end   = 0;

    // ---- core state -------------------------------------------------------
    uint32_t regs[32];
    uint32_t pc = RAM_BASE;
    uint64_t steps = 0;
    int64_t  tick_left = TICK_STEPS;
    uint32_t min_sp;
    uint32_t stack_floor = RAM_STACK_FLOOR;

    // ---- framebuffer ownership / double buffering -------------------------
    uint32_t active = FRAME_BASE_A, request = FRAME_BASE_A;
    uint32_t right_active = FRAME_BASE_A, right_request = FRAME_BASE_A;
    uint32_t cpu_frames = 0, fpga_frames = 0;

    // ---- peripherals ------------------------------------------------------
    uint64_t busy_until = 0;
    bool     done = false;
    bool     vsync = false;
    int      latency = 10;

    // ---- modelled inputs --------------------------------------------------
    uint32_t joy = 0x00008080u;
    uint32_t btn = 0x00008000u;
    uint32_t board_keys = 0;

    // ---- statistics the scenarios grade -----------------------------------
    uint64_t starts = 0;
    uint64_t blit_fill_calls = 0;
    uint64_t blit_copy_calls = 0, blit_copy_bytes = 0;
    uint64_t blit_alpha_calls = 0, blit_alpha_bytes = 0, blit_alpha_keyed = 0;
    uint64_t blit_add_calls = 0, blit_add_bytes = 0;

    // Python-visible containers.  None of these are on the hot path.
    py::list  published, right_published, uart_out, copy_log, blit_trace;
    py::dict  params, uart_cfg;
    py::object last_alpha, last_alpha_cfg, last_alpha_before, last_alpha_rect;
    py::object last_copy, last_sprite_copy, last_boss_copy;

    // Cached buffer-protocol views.  Building a memoryview costs about 1.5 us,
    // and the workbench indexes vm.scratch element by element in tight loops --
    // 153 million times in one scenario -- so these views are handed out, never
    // rebuilt.  They are built lazily by the binding layer.
    py::object view_ram, view_scratch, view_scratch32, view_fbA, view_fbB, view_fb;

    // Deferred CPU stores into the framebuffer.
    std::unordered_map<uint32_t, uint32_t> pending;

    // ---- construction -----------------------------------------------------
    SapphireSoCVM(const std::vector<uint32_t>& code_words,
                  int lat = 10,
                  uint32_t stack_floor_ = RAM_STACK_FLOOR,
                  py::object bss = py::none());

    // ---- memory helpers ---------------------------------------------------
    uint32_t frame_of(uint32_t addr) const;
    bool     in_scratch(uint32_t addr, uint64_t size = 1) const;
    void     check_owner(uint32_t base, bool has_x, int x, bool hw);
    void     drain();
    uint32_t params_get(uint32_t key, uint32_t dflt) const;

    // ---- memory access ----------------------------------------------------
    uint32_t load(uint32_t addr, int size = 4, bool sgn = false);
    void     store(uint32_t addr, uint32_t val, int size = 4);

    // ---- BitBlt engine model ---------------------------------------------
    void region_write(uint32_t addr, const uint8_t* data, uint32_t n);
    void blit_fill (uint32_t dst, uint32_t w, uint32_t h, uint32_t color, uint32_t dst_stride);
    void blit_copy (uint32_t dst, uint32_t src, uint32_t w, uint32_t h,
                    uint32_t src_stride, uint32_t dst_stride, py::object colorkey);
    void blit_alpha(uint32_t dst, uint32_t src, uint32_t w, uint32_t h,
                    uint32_t src_stride, uint32_t dst_stride,
                    uint32_t global_alpha, py::object colorkey);
    void blit_add  (uint32_t dst, uint32_t src, uint32_t w, uint32_t h,
                    uint32_t src_stride, uint32_t dst_stride, py::object colorkey);
    void apb_store(uint32_t off, uint32_t val);
    void bucket_accel(uint32_t control);
    uint32_t bucket_status = 0x20000000u, bucket_player_xy = 0x020002ABu, bucket_info = 0;
    uint16_t bucket_used[2][96] = {};

    // ---- execution --------------------------------------------------------
    void step();
    void step_n(uint64_t n);

    // ---- misc -------------------------------------------------------------
    void trace_blit(const char* kind, uint32_t dst, uint32_t src,
                    uint32_t w, uint32_t h, uint32_t extra = 0);
    void dump_blit_trace(int n);
    void save_frame_bmp(const std::string& path, py::object base_addr);
    uint32_t scratch_word(uint32_t byte_off) const;

    // Pool scans.  The workbench grades DDR pools by walking them field by
    // field; doing that from Python costs about 1.4 us per element and one
    // scenario spends 91% of its wall clock there.  Same arithmetic, done here.
    uint32_t count_masked(uint32_t start, uint32_t count, uint32_t stride, uint32_t mask);
    uint32_t count_nonzero(uint32_t start, uint32_t count, uint32_t stride);
    uint32_t count_moving(uint32_t start, uint32_t count, uint32_t stride);

    // Wait primitives.  The workbench spends most of its wall clock in
    // "step until a telemetry word reads X" loops; the loop body is just a step
    // plus a compare, so it runs here instead of crossing the language boundary
    // once per instruction.
    uint64_t run_until_word_ne(uint32_t word_index, uint32_t value, uint64_t budget);
    uint64_t run_until_publish(uint32_t was, uint64_t budget);

    // Raw buffer accessors for the binding layer (zero copy).
    uint8_t*  scratch_ptr() { return scratch.data(); }
    uint64_t  scratch_len() const { return scratch.size(); }
    uint8_t*  ram_ptr()     { return ram.data(); }
    uint64_t  ram_len()     const { return ram.size(); }
    uint32_t* fb_ptr(uint32_t base);

private:
    uint32_t*       fb_words(uint32_t base);
    const uint32_t* fb_words_c(uint32_t base) const;
};

}  // namespace socvm
