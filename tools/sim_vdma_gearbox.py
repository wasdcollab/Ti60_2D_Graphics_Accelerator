H_ACT, H_TOTAL = 1366, 1792
V_ACT, V_TOTAL = 768, 798

def simulate(pop_limit, per_line_read, tag, verbose=True):
    """Cycle-accurate model of the VDMA pixel gearbox + the sync (non-FWFT) read FIFO.
       fifo word index m comes from DDR row m // per_line_read, word m % per_line_read."""
    rbin, rdata, sub, cur = 0, -1, 0, -1
    out = {}
    pop_per_line = []
    vseq = [796, 797] + list(range(0, 6))
    for v in vseq:
        pops = 0
        for h in range(H_TOTAL):
            prefetch_line = (v == V_TOTAL - 1) or (v < V_ACT - 1)
            t_de = (h < H_ACT) and (v < V_ACT)
            line_prefetch = (h == H_TOTAL - 2) and prefetch_line
            word_fetch = (sub == 2) and (h < pop_limit) and t_de
            rinc = bool(line_prefetch or word_fetch)
            if t_de and v < V_ACT:
                out.setdefault(v, {})[h] = (cur, sub)
            if (h == H_TOTAL - 1) and prefetch_line:
                n_cur, n_sub = rdata, 0
            elif t_de:
                n_sub = (sub + 1) % 4
                n_cur = rdata if sub == 3 else cur
            else:
                n_sub, n_cur = 0, cur
            if rinc:
                n_rdata, rbin = rbin, rbin + 1
                pops += 1
            else:
                n_rdata = rdata
            cur, sub, rdata = n_cur, n_sub, n_rdata
        if v < V_ACT:
            pop_per_line.append(pops)
    if verbose:
        print("--- %s" % tag)
        print("    pop_limit=%-5d read/line=%-4d  pops/line=%s"
              % (pop_limit, per_line_read, sorted(set(pop_per_line))))
        bad = 0
        for v in range(6):
            first_bad = None
            for h in range(H_ACT):
                want_word = v * per_line_read + h // 4
                want_lane = h % 4
                got = out.get(v, {}).get(h)
                if got != (want_word, want_lane):
                    first_bad = (h, got, (want_word, want_lane)); break
            if first_bad:
                bad += 1
                print("    row %d: FIRST MISMATCH at x=%-5d got word/lane=%s want %s"
                      % (v, first_bad[0], first_bad[1], first_bad[2]))
            else:
                print("    row %d: OK (all 1366 pixels come from the right word+lane)" % v)
        print("    -> %s" % ("BROKEN" if bad else "CORRECT"))
        print()

simulate(H_ACT - 4, 352, "CURRENT RTL   (word_fetch h_cnt<H_ACT-4, 22x16-beat bursts)")
simulate(H_ACT - 4, 342, "half fix A    (short tail burst only)")
simulate(H_ACT - 2, 352, "half fix B    (pop threshold only)")
simulate(H_ACT - 2, 342, "PROPOSED      (short tail burst + word_fetch h_cnt<H_ACT-2)")
