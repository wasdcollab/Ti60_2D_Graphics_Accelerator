// blit.cpp -- the BitBlt engine model (FILL / COPY / ALPHA / ADD), the APB
// register window and the BMP exporter.  Port of the matching methods in
// rv32i_soc_vm.py; the byte semantics must match rtl/bitblt v2.

#include "socvm.h"

#include <cstdio>

namespace socvm {

// ---------------------------------------------------------------------------
// _region_read: bytes out of whichever region addr belongs to
// ---------------------------------------------------------------------------
static std::vector<uint8_t> region_read(SapphireSoCVM& vm, uint32_t addr, uint32_t n) {
    uint32_t base = vm.frame_of(addr);
    if (base) {
        if (addr % 4 != 0 || n % 4 != 0)
            throw VMError("pixel ops must be word aligned");
        vm.drain();
        const uint32_t* fw = (base == FRAME_BASE_A) ? vm.fbA.data() : vm.fbB.data();
        std::vector<uint8_t> out(n);
        std::memcpy(out.data(), (const uint8_t*)fw + (addr - base), n);
        return out;
    }
    if (vm.in_scratch(addr, n)) {
        std::vector<uint8_t> out(n);
        std::memcpy(out.data(), vm.scratch.data() + (addr - SCRATCH_BASE), n);
        return out;
    }
    throw VMError(vfmt("BitBlt source %#x outside modelled DDR", addr));
}

void SapphireSoCVM::region_write(uint32_t addr, const uint8_t* data, uint32_t n) {
    uint32_t base = frame_of(addr);
    if (base) {
        if (addr % 4 != 0 || n % 4 != 0)
            throw VMError("pixel ops must be word aligned");
        check_owner(base, true, (int)(((addr - base) / 4) % SCREEN_PITCH), true);
        std::memcpy((uint8_t*)fb_words(base) + (addr - base), data, n);
        return;
    }
    if (in_scratch(addr, n)) {
        std::memcpy(scratch.data() + (addr - SCRATCH_BASE), data, n);
        return;
    }
    throw VMError(vfmt("BitBlt destination %#x outside modelled DDR", addr));
}

// ---------------------------------------------------------------------------
// OP_FILL
// ---------------------------------------------------------------------------
void SapphireSoCVM::blit_fill(uint32_t dst, uint32_t w, uint32_t h,
                              uint32_t color, uint32_t dst_stride) {
    trace_blit("fill", dst, 0, w, h, 0);
    drain();
    if (dst_stride % 16 != 0)
        throw VMError("BitBlt strides must be multiples of 16");

    uint32_t base = frame_of(dst);
    if (base) {
        uint32_t off = dst - base;
        if (off % 4 != 0)
            throw VMError("fill destination must be word aligned");
        uint32_t x = (off / 4) % SCREEN_PITCH;
        uint32_t y = (off / 4) / SCREEN_PITCH;
        if (!(x + w <= (uint32_t)SCREEN_W && y + h <= (uint32_t)SCREEN_H))
            throw VMError(vfmt("BitBlt fill out of bounds: (%d,%d,%d,%d)", x, y, w, h));
        check_owner(base, true, (int)x, true);
        uint32_t* fw = fb_words(base);
        for (uint32_t rr = y; rr < y + h; ++rr) {
            uint32_t* p = fw + (size_t)rr * SCREEN_PITCH + x;
            for (uint32_t k = 0; k < w; ++k) p[k] = color;
        }
    } else {
        uint64_t last = (uint64_t)dst + (uint64_t)(h - 1) * dst_stride + 4ull * w;
        if (!(in_scratch(dst) && last <= (uint64_t)SCRATCH_BASE + SCRATCH_SIZE))
            throw VMError(vfmt("BitBlt fill destination %#x outside modelled DDR", dst));
        for (uint32_t rr = 0; rr < h; ++rr) {
            uint32_t a = dst + rr * dst_stride - SCRATCH_BASE;
            uint32_t* p = (uint32_t*)(scratch.data() + a);
            for (uint32_t k = 0; k < w; ++k) p[k] = color;
        }
    }
    starts += 1;
    blit_fill_calls += 1;
    done = true;
    busy_until = steps + (uint64_t)latency;
}

// ---------------------------------------------------------------------------
// OP_COPY
// ---------------------------------------------------------------------------
void SapphireSoCVM::blit_copy(uint32_t dst, uint32_t src, uint32_t w, uint32_t h,
                              uint32_t src_stride, uint32_t dst_stride,
                              py::object colorkey) {
    trace_blit("copy", dst, src, w, h, src_stride);

    copy_log.append(py::make_tuple(py::int_(w), py::int_(h), py::int_(src), py::int_(dst)));
    if (copy_log.size() > 4096) {
        // Python does "del self.copy_log[:2048]" -- drop the oldest half in one
        // go.  Scenarios slice copy_log[c0:] to mean "everything since I
        // looked", so the exact trimming shape is observable behaviour, not an
        // implementation detail.
        copy_log.attr("__delitem__")(py::slice((py_ssize_t)0, (py_ssize_t)2048, (py_ssize_t)1));
    }

    if (w >= 32 && h >= 32)
        last_sprite_copy = py::make_tuple(py::int_(dst), py::int_(src), py::int_(w),
                                          py::int_(h), py::int_(src_stride),
                                          py::int_(dst_stride));
    uint32_t base0 = frame_of(dst);
    if (base0 && h == 48 && ((dst - base0) / 4 / SCREEN_PITCH) > 700)
        std::printf("TALL48 dst=%#x src=%#x w=%d h=%d ss=%#x ds=%#x pc=%#x\n",
                    dst, src, w, h, src_stride, dst_stride, pc);
    if (w == 64 && h == 64)
        last_boss_copy = py::make_tuple(py::int_(dst), py::int_(src), py::int_(w),
                                        py::int_(h), py::int_(src_stride),
                                        py::int_(dst_stride));

    drain();
    if (!(src_stride % 16 == 0 && dst_stride % 16 == 0))
        throw VMError("BitBlt copy strides must be multiples of 16");

    uint32_t base = frame_of(dst);
    if (base) {
        uint32_t off = dst - base;
        uint32_t x = (off / 4) % SCREEN_PITCH;
        uint32_t y = (off / 4) / SCREEN_PITCH;
        if (!(x + w <= (uint32_t)SCREEN_W && y + h <= (uint32_t)SCREEN_H))
            throw VMError(vfmt("BitBlt copy out of bounds: (%d,%d,%d,%d)", x, y, w, h));
        check_owner(base, true, (int)x, true);
    } else {
        uint64_t last = (uint64_t)dst + (uint64_t)(h - 1) * dst_stride + 4ull * w;
        if (!(in_scratch(dst) && last <= (uint64_t)SCRATCH_BASE + SCRATCH_SIZE)) {
            std::printf("BAD COPY dst=%#x src=%#x w=%d h=%d ss=%#x ds=%#x pc=%#x\n",
                        dst, src, w, h, src_stride, dst_stride, pc);
            throw VMError(vfmt("BitBlt copy destination %#x outside modelled DDR", dst));
        }
    }
    drain();

    uint32_t nbytes = w * 4;
    bool has_key = !colorkey.is_none();
    uint32_t key = 0;
    uint8_t key_bytes[4] = {0, 0, 0, 0};
    if (has_key) {
        key = colorkey.cast<uint32_t>();
        std::memcpy(key_bytes, &key, 4);
        if (((src | dst) & 3u) != 0)
            throw VMError("Color Key COPY must be pixel aligned");
    }

    for (uint32_t rr = 0; rr < h; ++rr) {
        std::vector<uint8_t> data = region_read(*this, src + rr * src_stride, nbytes);
        bool skip_key = false;
        if (has_key) {
            // Exact fast path: absence of the key as a byte substring proves no
            // aligned pixel equals it.
            for (uint32_t i = 0; i + 4 <= nbytes; ++i) {
                if (data[i] == key_bytes[0] && data[i + 1] == key_bytes[1] &&
                    data[i + 2] == key_bytes[2] && data[i + 3] == key_bytes[3]) {
                    skip_key = true;
                    break;
                }
            }
        }
        if (!skip_key) {
            region_write(dst + rr * dst_stride, data.data(), nbytes);
        } else {
            if (((src | dst) & 3u) != 0)
                throw VMError("Color Key COPY must be pixel aligned");
            for (uint32_t x = 0; x < w; ++x) {
                uint32_t px;
                std::memcpy(&px, data.data() + x * 4, 4);
                if (px != key)
                    region_write(dst + rr * dst_stride + x * 4, data.data() + x * 4, 4);
            }
        }
    }
    starts += 1;
    blit_copy_calls += 1;
    blit_copy_bytes += (uint64_t)nbytes * h;
    last_copy = py::make_tuple(py::int_(dst), py::int_(src), py::int_(w), py::int_(h),
                               py::int_(src_stride), py::int_(dst_stride));
    done = true;
    busy_until = steps + (uint64_t)latency;
}

// ---------------------------------------------------------------------------
// OP_ALPHA
//   ae  = (a * GLOBAL_ALPHA + 127) / 255
//   out = (src * ae + dst * (255 - ae) + 127) / 255     for R, G, B
// Colour keying has priority over blending; the background alpha passes through.
// ---------------------------------------------------------------------------
void SapphireSoCVM::blit_alpha(uint32_t dst, uint32_t src, uint32_t w, uint32_t h,
                               uint32_t src_stride, uint32_t dst_stride,
                               uint32_t global_alpha, py::object colorkey) {
    drain();
    if (!(src_stride % 16 == 0 && dst_stride % 16 == 0))
        throw VMError("BitBlt alpha strides must be multiples of 16");
    if (((src | dst) & 3u) != 0)
        throw VMError("BitBlt alpha needs 32-bit pixel alignment");
    uint32_t base = frame_of(dst);
    if (!base)
        throw VMError(vfmt("alpha destination %#x is not a framebuffer", dst));
    uint32_t off = dst - base;
    uint32_t x = (off / 4) % SCREEN_PITCH;
    uint32_t y = (off / 4) / SCREEN_PITCH;
    if (!(x + w <= (uint32_t)SCREEN_W && y + h <= (uint32_t)SCREEN_H))
        throw VMError(vfmt("BitBlt alpha out of bounds: (%d,%d,%d,%d)", x, y, w, h));
    check_owner(base, true, (int)x, true);
    drain();

    py::list snapshot;
    uint64_t written = 0, keyed = 0;
    bool has_key = !colorkey.is_none();
    uint32_t key = has_key ? colorkey.cast<uint32_t>() : 0;

    uint32_t* fw = fb_words(base);
    for (uint32_t rr = 0; rr < h; ++rr) {
        std::vector<uint8_t> sdata = region_read(*this, src + rr * src_stride, 4 * w);
        uint32_t* drow = fw + (size_t)(y + rr) * SCREEN_PITCH + x;
        std::vector<uint8_t> dprev(4 * w);
        std::memcpy(dprev.data(), drow, 4 * w);
        snapshot.append(py::bytes((const char*)dprev.data(), 4 * w));

        std::vector<uint8_t> out(4 * w);
        for (uint32_t px = 0; px < w; ++px) {
            const uint8_t* sp = sdata.data() + px * 4;
            const uint8_t* dp = dprev.data() + px * 4;
            uint32_t spx;
            std::memcpy(&spx, sp, 4);
            if (has_key && spx == key) {
                out[px * 4 + 0] = dp[0];
                out[px * 4 + 1] = dp[1];
                out[px * 4 + 2] = dp[2];
                out[px * 4 + 3] = dp[3];
                keyed += 1;
                continue;
            }
            uint32_t a = ((uint32_t)sp[3] * global_alpha + 127u) / 255u;
            for (int k = 0; k < 3; ++k) {
                out[px * 4 + k] = (uint8_t)(((uint32_t)sp[k] * a +
                                             (uint32_t)dp[k] * (255u - a) + 127u) / 255u);
            }
            out[px * 4 + 3] = dp[3];
            written += 4;
        }
        std::memcpy(drow, out.data(), 4 * w);
    }

    starts += 1;
    blit_alpha_calls += 1;
    blit_alpha_bytes += written;
    blit_alpha_keyed += keyed;
    last_alpha = py::make_tuple(py::int_(dst), py::int_(src), py::int_(w), py::int_(h),
                                py::int_(src_stride), py::int_(dst_stride));
    last_alpha_cfg = py::make_tuple(py::int_(global_alpha),
                                    has_key ? py::cast(key) : py::none());
    last_alpha_before = snapshot;
    last_alpha_rect = py::make_tuple(py::int_(x), py::int_(y), py::int_(w), py::int_(h));
    done = true;
    busy_until = steps + (uint64_t)latency;
}

// ---------------------------------------------------------------------------
// OP_ADD
// ---------------------------------------------------------------------------
void SapphireSoCVM::blit_add(uint32_t dst, uint32_t src, uint32_t w, uint32_t h,
                             uint32_t src_stride, uint32_t dst_stride,
                             py::object colorkey) {
    drain();
    if (!(src_stride % 16 == 0 && dst_stride % 16 == 0))
        throw VMError("BitBlt add strides must be multiples of 16");
    if (((src | dst) & 3u) != 0)
        throw VMError("BitBlt add needs 32-bit pixel alignment");
    uint32_t base = frame_of(dst);
    if (!base)
        throw VMError(vfmt("add destination %#x is not a framebuffer", dst));
    uint32_t off = dst - base;
    uint32_t x = (off / 4) % SCREEN_PITCH;
    uint32_t y = (off / 4) / SCREEN_PITCH;
    if (!(x + w <= (uint32_t)SCREEN_W && y + h <= (uint32_t)SCREEN_H))
        throw VMError(vfmt("BitBlt add out of bounds: (%d,%d,%d,%d)", x, y, w, h));
    check_owner(base, true, (int)x, true);
    drain();

    uint64_t written = 0;
    bool has_key = !colorkey.is_none();
    uint32_t key = has_key ? colorkey.cast<uint32_t>() : 0;
    uint32_t* fw = fb_words(base);

    for (uint32_t rr = 0; rr < h; ++rr) {
        std::vector<uint8_t> sdata = region_read(*this, src + rr * src_stride, 4 * w);
        uint32_t* drow = fw + (size_t)(y + rr) * SCREEN_PITCH + x;
        std::vector<uint8_t> dprev(4 * w);
        std::memcpy(dprev.data(), drow, 4 * w);

        std::vector<uint8_t> out(4 * w);
        for (uint32_t px = 0; px < w; ++px) {
            const uint8_t* sp = sdata.data() + px * 4;
            const uint8_t* dp = dprev.data() + px * 4;
            uint32_t spx;
            std::memcpy(&spx, sp, 4);
            if (has_key && spx == key) {
                out[px * 4 + 0] = dp[0];
                out[px * 4 + 1] = dp[1];
                out[px * 4 + 2] = dp[2];
                out[px * 4 + 3] = dp[3];
                continue;
            }
            for (int k = 0; k < 3; ++k) {
                uint32_t val = (uint32_t)sp[k] + (uint32_t)dp[k];
                out[px * 4 + k] = (uint8_t)(val > 255u ? 255u : val);
            }
            out[px * 4 + 3] = dp[3];
            written += 4;
        }
        std::memcpy(drow, out.data(), 4 * w);
    }

    starts += 1;
    blit_add_calls += 1;
    blit_add_bytes += written;
    done = true;
    busy_until = steps + (uint64_t)latency;
}

// ---------------------------------------------------------------------------
// APB register window
// ---------------------------------------------------------------------------
void SapphireSoCVM::apb_store(uint32_t off, uint32_t val) {
    switch (off) {
        case 4: case 8: case 12: case 16: case 24: case 28:
        case 48: case 72: case 0x4C: case 0x60: case 0x64: case 0x68: case 0x6C:
        case 0x100: case 0x104: case 0x130: case 0x13C: case 0x140:
            params[py::int_(off)] = py::int_(val);
            return;
        default: break;
    }
    if (off == 20 && (val & 1u)) {
        if (steps < busy_until)
            throw VMError("BitBlt START issued while busy");
        uint32_t op = params_get(24, 0) & 3u;
        uint32_t dst = params_get(4, 0), w = params_get(8, 0),
                 h = params_get(12, 0), color = params_get(16, 0);
        bool has_key = (params_get(0x64, 0) & 1u) != 0;
        py::object key = has_key ? py::cast(params_get(0x60, 0x00FF00FFu)) : py::none();
        if (op == 0) {
            blit_fill(dst, w, h, color, params_get(72, 4096));
        } else if (op == 2) {
            uint32_t src = params_get(28, 0);
            if (!(params_get(0x68, 0) & 1u))
                throw VMError("OP_ALPHA issued with ALPHA_CTRL disabled (hardware raises CFGERR)");
            blit_alpha(dst, src, w, h, params_get(48, 4096), params_get(72, 4096),
                       params_get(0x6C, 0xFF), key);
        } else if (op == 3) {
            uint32_t src = params_get(28, 0);
            if (!(params_get(0x68, 0) & 1u))
                throw VMError("OP_ADD issued with ALPHA_CTRL disabled (hardware raises CFGERR)");
            blit_add(dst, src, w, h, params_get(48, 4096), params_get(72, 4096), key);
        } else {
            uint32_t src = params_get(28, 0);
            blit_copy(dst, src, w, h, params_get(48, 4096), params_get(72, 4096), key);
        }
        return;
    }
    if (off == 0x40) {
        if (val != FRAME_BASE_A && val != FRAME_BASE_B)
            throw VMError("");
        right_request = val;
        right_published.append(py::int_(val));
        return;
    }
    // 0x78/0x7C/0x88/0x8C/0xAC/0xB0/0xB4/0xB8/0xBC and 0xC0..0xEC are all
    // scanout-side registers: the real hardware synthesises the weather, the
    // bloom, the laser columns and the beam/hairline overlay itself, and the VM
    // has no scanout.  Nothing is painted for them, but the words are stored
    // because where the firmware aimed a column and which colour it chose is
    // exactly what a scenario grades - read back through the generic window.
    // ... plus 0xF0..0xFC, which is B1's bucket base and the scanout tile
    // store's write port.  The native kernel only records them: the Python
    // kernel additionally mirrors the store so a scenario can rebuild the
    // picture the hardware would have drawn, but the native one is for the load
    // and row accounting, and neither of those depends on the store's contents.
    // 0xF8 / 0xFC are the tile store's write port: one byte and one palette
    // entry, each with a pointer that advances itself.  They used to fall into
    // the catch-all below, which recorded the value in params and dropped the
    // payload - so the native kernel had no tile store at all and the scanout
    // compositor could not draw a single bullet.
    if (off == 0xF8) {
        uint32_t p = params_get(0xF4, 0);
        if (p < TILE_STORE_BYTES) btile[p] = (uint8_t)(val & 0xFFu);
        params[py::int_(0xF8)] = py::int_(val & 0xFFu);
        params[py::int_(0xF4)] = py::int_((p + 1u) & 0x7FFFu);
        return;
    }
    if (off == 0xFC) {
        uint32_t p = params_get(0x100, 0);
        // All 32 bits: the top byte is the entry's alpha, which the scanout
        // blends the bullet with.  Masking to 24 here would make every entry
        // opaque and the alpha feature would look broken rather than narrow.
        if (p < PALETTE_ENTRIES) bpal[p] = val;
        params[py::int_(0xFC)] = py::int_(val & 0xFFFFFFu);
        params[py::int_(0x100)] = py::int_((p + 1u) & 0xFFu);
        return;
    }
    if (off == 0x5C || off == 0x78 || off == 0x7C || off == 0x88 ||
        off == 0x8C || off == 0xAC || off == 0xB0 || off == 0xB4 ||
        off == 0xB8 || off == 0xBC || (off >= 0xC0 && off <= 0xEC) ||
        off == 0xF0 || off == 0xF4) {
        params[py::int_(off)] = py::int_(val);
        return;
    }
    if (off == 0x80) { asset_addr = val & 0x3FFFu; return; }
    if (off == 0x20 || off == 0x134) {
        if (!pending.empty())
            throw VMError("Published frame before DDR stores drained");
        if (val != FRAME_BASE_A && val != FRAME_BASE_B)
            throw VMError("published buffer is out of range");
        if (steps < busy_until)
            throw VMError("published before BitBlt finished");
        request = val;
        published.append(py::int_(val));
        if (off == 0x134) {
            right_request = val;
            right_published.append(py::int_(val));
        }
        return;
    }
    throw VMError(vfmt("unknown APB write %#x", off));
}

// ---------------------------------------------------------------------------
// save_frame_bmp
// ---------------------------------------------------------------------------
void SapphireSoCVM::save_frame_bmp(const std::string& path, py::object base_addr) {
    uint32_t base;
    if (base_addr.is_none()) base = right_request;
    else base = base_addr.cast<uint32_t>();

    drain();
    const uint32_t* fw = fb_words(base);
    int w = SCREEN_W, h = SCREEN_H;
    std::vector<uint8_t> rows((size_t)w * h * 4);
    for (int y = 0; y < h; ++y) {
        const uint8_t* srcp = (const uint8_t*)(fw + (size_t)y * SCREEN_PITCH);
        std::memcpy(rows.data() + (size_t)y * w * 4, srcp, (size_t)w * 4);
    }

    uint32_t filesize = 54u + (uint32_t)rows.size();
    uint8_t header[54] = {0};
    header[0] = 'B'; header[1] = 'M';
    auto put32 = [&](int o, uint32_t v) {
        header[o] = (uint8_t)(v & 0xFF); header[o+1] = (uint8_t)((v>>8)&0xFF);
        header[o+2] = (uint8_t)((v>>16)&0xFF); header[o+3] = (uint8_t)((v>>24)&0xFF);
    };
    auto put16 = [&](int o, uint16_t v) {
        header[o] = (uint8_t)(v & 0xFF); header[o+1] = (uint8_t)((v>>8)&0xFF);
    };
    put32(2, filesize);
    put32(10, 54);
    put32(14, 40);
    put32(18, (uint32_t)w);
    put32(22, (uint32_t)(-h));
    put16(26, 1);
    put16(28, 32);
    put32(34, (uint32_t)rows.size());

    std::FILE* fp = std::fopen(path.c_str(), "wb");
    if (!fp) throw VMError("cannot open " + path);
    std::fwrite(header, 1, 54, fp);
    std::fwrite(rows.data(), 1, rows.size(), fp);
    std::fclose(fp);
}

}  // namespace socvm
