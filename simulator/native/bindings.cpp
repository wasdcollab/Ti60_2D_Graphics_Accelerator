// bindings.cpp -- pybind11 surface for the native VM.
//
// Design rule: the Python workbench (test_runner.py) must not need a single
// edit.  So the shapes exposed here mimic what the Python class had --
// bytearray-like scratch/ram, a dict of framebuffers, plain attributes for the
// 26 names the scenarios touch.
//
// Memory is handed over as buffer-protocol views (zero copy): the workbench
// does slices, single-byte indexing and int.from_bytes on them.

#include "socvm.h"

#include <cstdio>

namespace socvm {

// Cached views, built once per VM.  Creating a memoryview per access would cost
// ~100 ns and tlm() alone is called millions of times per scenario.
static py::object make_byte_view(void* p, uint64_t n, bool readonly) {
    return py::memoryview::from_memory(p, (py_ssize_t)n, readonly);
}
static py::object make_word_view(uint32_t* p, uint64_t nwords, bool readonly) {
    return py::memoryview::from_buffer(p, sizeof(uint32_t), "I",
                                       {(py_ssize_t)nwords}, {(py_ssize_t)sizeof(uint32_t)},
                                       readonly);
}

class VMBinding {
public:
    SapphireSoCVM& vm;
    py::object scratch_view, scratch32_view, ram_view, ram32_view;
    py::object fb_dict;
};

}  // namespace socvm

using namespace socvm;

PYBIND11_MODULE(_socvm, m) {
    m.doc() = "Native (C++) core of the Ti60 2D accelerator simulator. "
              "Behavioural twin of rv32i_soc_vm.SapphireSoCVM.";

    // The Python reference raises AssertionError; scenario failures quote the
    // message, so translate VMError into the same class.
    py::register_exception_translator([](std::exception_ptr p) {
        try {
            if (p) std::rethrow_exception(p);
        } catch (const VMError& e) {
            PyErr_SetString(PyExc_AssertionError, e.what());
        }
    });

    py::class_<SapphireSoCVM>(m, "SapphireSoCVM")
        .def(py::init<const std::vector<uint32_t>&, int, uint32_t, py::object>(),
             py::arg("code_words"), py::arg("latency") = 10,
             py::arg("stack_floor") = RAM_STACK_FLOOR,
             py::arg("bss") = py::none())

        // ---- execution ----------------------------------------------------
        .def("step", &SapphireSoCVM::step)
        .def("step_n", &SapphireSoCVM::step_n, py::arg("n"))
        .def("drain", &SapphireSoCVM::drain)
        .def("load", [](SapphireSoCVM& s, uint32_t addr, int size) {
            return s.load(addr, size, false);
        }, py::arg("addr"), py::arg("size") = 4)
        .def("store", [](SapphireSoCVM& s, uint32_t addr, uint32_t val, int size) {
            s.store(addr, val, size);
        }, py::arg("addr"), py::arg("val"), py::arg("size") = 4)
        .def("in_scratch", [](SapphireSoCVM& s, uint32_t a, uint64_t n) {
            return s.in_scratch(a, n);
        }, py::arg("addr"), py::arg("size") = 1)
        .def("frame_of", [](SapphireSoCVM& s, uint32_t a) -> py::object {
            uint32_t b = s.frame_of(a);
            if (!b) return py::none();
            return py::int_(b);
        }, py::arg("addr"))
        .def("save_frame_bmp", &SapphireSoCVM::save_frame_bmp,
             py::arg("filepath"), py::arg("base_addr") = py::none())
        .def("dump_blit_trace", &SapphireSoCVM::dump_blit_trace, py::arg("n") = 40)

        // ---- scalar state (read/write, exactly the names the scenarios use)
        .def_property("regs",
            [](SapphireSoCVM& s) {
                py::list l;
                for (int i = 0; i < 32; ++i) l.append(py::int_(s.regs[i]));
                return l;
            },
            [](SapphireSoCVM& s, py::sequence seq) {
                int i = 0;
                for (auto o : seq) { if (i >= 32) break; s.regs[i++] = o.cast<uint32_t>(); }
            })
        .def_property("r",
            [](SapphireSoCVM& s) {
                py::list l;
                for (int i = 0; i < 32; ++i) l.append(py::int_(s.regs[i]));
                return l;
            },
            [](SapphireSoCVM& s, py::sequence seq) {
                int i = 0;
                for (auto o : seq) { if (i >= 32) break; s.regs[i++] = o.cast<uint32_t>(); }
            })
        .def_readwrite("tick_left", &SapphireSoCVM::tick_left)
        .def_readwrite("has_bss", &SapphireSoCVM::has_bss)
        .def_readwrite("bss_start", &SapphireSoCVM::bss_start)
        .def_readwrite("bss_end", &SapphireSoCVM::bss_end)
        .def_readwrite("pc", &SapphireSoCVM::pc)
        .def_readwrite("steps", &SapphireSoCVM::steps)
        .def_readwrite("latency", &SapphireSoCVM::latency)
        .def_readwrite("min_sp", &SapphireSoCVM::min_sp)
        .def_readwrite("stack_floor", &SapphireSoCVM::stack_floor)
        .def_readwrite("image_end", &SapphireSoCVM::image_end)
        .def_readwrite("joy", &SapphireSoCVM::joy)
        .def_readwrite("btn", &SapphireSoCVM::btn)
        .def_readwrite("board_keys", &SapphireSoCVM::board_keys)
        .def_readwrite("active", &SapphireSoCVM::active)
        .def_readwrite("request", &SapphireSoCVM::request)
        .def_readwrite("right_active", &SapphireSoCVM::right_active)
        .def_readwrite("right_request", &SapphireSoCVM::right_request)
        .def_readwrite("cpu_frames", &SapphireSoCVM::cpu_frames)
        .def_readwrite("fpga_frames", &SapphireSoCVM::fpga_frames)
        .def_readwrite("busy_until", &SapphireSoCVM::busy_until)
        .def_readwrite("done", &SapphireSoCVM::done)
        .def_readwrite("vsync", &SapphireSoCVM::vsync)
        .def_readwrite("asset_addr", &SapphireSoCVM::asset_addr)
        .def_readwrite("starts", &SapphireSoCVM::starts)
        .def_readwrite("blit_fill_calls", &SapphireSoCVM::blit_fill_calls)
        .def_readwrite("blit_copy_calls", &SapphireSoCVM::blit_copy_calls)
        .def_readwrite("blit_copy_bytes", &SapphireSoCVM::blit_copy_bytes)
        .def_readwrite("blit_alpha_calls", &SapphireSoCVM::blit_alpha_calls)
        .def_readwrite("blit_alpha_bytes", &SapphireSoCVM::blit_alpha_bytes)
        .def_readwrite("blit_alpha_keyed", &SapphireSoCVM::blit_alpha_keyed)
        .def_readwrite("blit_add_calls", &SapphireSoCVM::blit_add_calls)
        .def_readwrite("blit_add_bytes", &SapphireSoCVM::blit_add_bytes)

        // ---- asset ROM (the Python layer loads the hex file) --------------
        .def("set_asset_rom", [](SapphireSoCVM& s, py::bytes b) {
            std::string raw = b;
            s.asset_rom.assign(raw.begin(), raw.end());
        })
        .def("get_asset_rom", [](SapphireSoCVM& s) {
            return py::bytes((const char*)s.asset_rom.data(), s.asset_rom.size());
        })
        .def("fb_bytes_of", [](SapphireSoCVM& s, uint32_t base) {
            uint32_t* p = s.fb_ptr(base);
            return py::memoryview::from_memory((uint8_t*)p, (py_ssize_t)FRAME_BYTES, false);
        }, py::arg("base"))
        .def("count_masked", &SapphireSoCVM::count_masked,
             py::arg("start"), py::arg("count"), py::arg("stride"), py::arg("mask"))
        .def("count_nonzero", &SapphireSoCVM::count_nonzero,
             py::arg("start"), py::arg("count"), py::arg("stride"))
        .def("count_moving", &SapphireSoCVM::count_moving,
             py::arg("start"), py::arg("count"), py::arg("stride"))
        .def("run_until_word_ne", &SapphireSoCVM::run_until_word_ne,
             py::arg("word_index"), py::arg("value"), py::arg("budget"))
        .def("run_until_publish", &SapphireSoCVM::run_until_publish,
             py::arg("was"), py::arg("budget"))
        .def("pending_size", [](SapphireSoCVM& s) { return (py_ssize_t)s.pending.size(); })
        .def("pending_clear", [](SapphireSoCVM& s) { s.pending.clear(); })

        // ---- Python-visible containers ------------------------------------
        .def_readwrite("published", &SapphireSoCVM::published)
        .def_readwrite("right_published", &SapphireSoCVM::right_published)
        .def_readwrite("uart_out", &SapphireSoCVM::uart_out)
        .def_readwrite("uart_cfg", &SapphireSoCVM::uart_cfg)
        .def_readwrite("copy_log", &SapphireSoCVM::copy_log)
        .def_readwrite("params", &SapphireSoCVM::params)
        .def_readwrite("last_alpha", &SapphireSoCVM::last_alpha)
        .def_readwrite("last_alpha_cfg", &SapphireSoCVM::last_alpha_cfg)
        .def_readwrite("last_alpha_before", &SapphireSoCVM::last_alpha_before)
        .def_readwrite("last_alpha_rect", &SapphireSoCVM::last_alpha_rect)
        .def_readwrite("last_copy", &SapphireSoCVM::last_copy)
        .def_readwrite("last_sprite_copy", &SapphireSoCVM::last_sprite_copy)
        .def_readwrite("last_boss_copy", &SapphireSoCVM::last_boss_copy)

        // ---- zero-copy memory views ----------------------------------------
        // Plain read-only attributes, not properties: the workbench touches
        // these millions of times and a pybind11 property call is ~1 us.
        .def_readonly("ram", &SapphireSoCVM::view_ram)
        .def_readonly("scratch", &SapphireSoCVM::view_scratch)
        .def_readonly("scratch32", &SapphireSoCVM::view_scratch32)
        .def_readonly("fb", &SapphireSoCVM::view_fb)        .def("fb_of", [](SapphireSoCVM& s, uint32_t base) {
            uint32_t* p = s.fb_ptr(base);
            return py::memoryview::from_buffer(p, sizeof(uint32_t), "I",
                                               {(py_ssize_t)FRAME_WORDS},
                                               {(py_ssize_t)sizeof(uint32_t)}, false);
        }, py::arg("base"))

        // ---- B1: the scanout's tile store and palette ---------------------
        // Bytes over the store, not a copy: the scanout compositor indexes it
        // once per bullet pixel and the snapshot save does one bytes() pass.
        // The Python kernel hands these out as a bytearray and a list; the two
        // agree on indexing and on len(), which is all the compositor uses.
        .def_readwrite("btile", &SapphireSoCVM::btile)
        .def_readwrite("bpal", &SapphireSoCVM::bpal)

        // ---- constants the Python layer may want ---------------------------
        .def_property_readonly("FRAME_BASES", [](SapphireSoCVM&) {
            return py::make_tuple(py::int_(FRAME_BASE_A), py::int_(FRAME_BASE_B));
        });

    m.attr("RAM_BASE") = py::int_(RAM_BASE);
    m.attr("RAM_SIZE") = py::int_(RAM_SIZE);
    m.attr("RAM_STACK_FLOOR") = py::int_(RAM_STACK_FLOOR);
    m.attr("APB_BASE") = py::int_(APB_BASE);
    m.attr("SCREEN_W") = py::int_(SCREEN_W);
    m.attr("SCREEN_H") = py::int_(SCREEN_H);
    m.attr("SCREEN_STRIDE") = py::int_(SCREEN_STRIDE);
    m.attr("SCREEN_PITCH") = py::int_(SCREEN_PITCH);
    m.attr("FRAME_BASES") = py::make_tuple(py::int_(FRAME_BASE_A), py::int_(FRAME_BASE_B));
    m.attr("FRAME_BYTES") = py::int_(FRAME_BYTES);
    m.attr("SCRATCH_BASE") = py::int_(SCRATCH_BASE);
    m.attr("SCRATCH_SIZE") = py::int_(SCRATCH_SIZE);
    m.attr("UART_BASE") = py::int_(UART_BASE);
    m.attr("TICK_STEPS") = py::int_(TICK_STEPS);
}
