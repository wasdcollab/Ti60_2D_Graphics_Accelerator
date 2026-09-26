def simulate(H_ACT, H_TOTAL, V_ACT, V_TOTAL, pop_limit, per_line_read, rows=4):
    rbin, rdata, sub, cur = 0, -1, 0, -1
    out, pops_list = {}, []
    for v in [V_TOTAL - 2, V_TOTAL - 1] + list(range(rows)):
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
                n_rdata, rbin, pops = rbin, rbin + 1, pops + 1
            else:
                n_rdata = rdata
            cur, sub, rdata = n_cur, n_sub, n_rdata
        if v < V_ACT:
            pops_list.append(pops)
    bad = 0
    for v in range(rows):
        for h in range(H_ACT):
            if out.get(v, {}).get(h) != (v * per_line_read + h // 4, h % 4):
                bad += 1; break
    return sorted(set(pops_list)), per_line_read, bad

print("width |  old threshold (H_ACT-4)           |  new threshold (H_ACT-2)")
print("      |  pops/line read/line result        |  pops/line read/line result")
print("-" * 88)
for H_ACT, H_TOTAL, V_ACT, V_TOTAL in ((1024, 1344, 600, 628), (1280, 1650, 720, 750), (1366, 1792, 768, 798)):
    need = -(-H_ACT // 4)                       # ceil(H_ACT/4) = words the scan line eats
    p_old, r_old, bad_old = simulate(H_ACT, H_TOTAL, V_ACT, V_TOTAL, H_ACT - 4, need)
    p_new, r_new, bad_new = simulate(H_ACT, H_TOTAL, V_ACT, V_TOTAL, H_ACT - 2, need)
    print("%-5d |  %-9s %-9d %-12s |  %-9s %-9d %s"
          % (H_ACT, p_old, r_old, "OK" if not bad_old else "BROKEN(%d rows)" % bad_old,
             p_new, r_new, "OK" if not bad_new else "BROKEN(%d rows)" % bad_new))
print()
print("words a line needs = ceil(H_ACT/4):  1024->256   1280->320   1366->342")
print("So the OLD threshold was right for the two power-of-two-ish widths and")
print("wrong only at 1366 -- the same 'third enlargement' pattern as before.")
