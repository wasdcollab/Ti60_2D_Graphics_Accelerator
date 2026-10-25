// sim_host_main.cpp -- 由 host 驱动时钟的 Verilator 顶层 main。
// 用法: g++ -include V<top>.h -DTB_TOP=V<top> ...
#include "verilated.h"
#ifndef TB_TOP
#error "define TB_TOP to the Verilator top class"
#endif
int main(int argc, char** argv) {
    VerilatedContext ctx;
    ctx.commandArgs(argc, argv);
    TB_TOP* top = new TB_TOP{&ctx};
    top->clk = 0;
    top->eval();
    while (!ctx.gotFinish()) {
        ctx.timeInc(5);
        top->clk = 1;
        top->eval();
        if (ctx.gotFinish()) break;
        ctx.timeInc(5);
        top->clk = 0;
        top->eval();
    }
    top->final();
    delete top;
    return 0;
}
