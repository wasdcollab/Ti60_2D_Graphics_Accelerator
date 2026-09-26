# 1366 vs the two previous widths, in the units the pixel gearbox counts in.
for W in (1024, 1280, 1366):
    print("H_ACT=%-5d  words per line = %-8s  %s"
          % (W, "%.2f" % (W / 4.0), "EXACT" if W % 4 == 0 else "<-- NOT a whole number of 128-bit words"))
print()
print("1366 px * 4 B = 5464 B ;  5464 / 16 = %.1f words  -> a scan line needs 342 words" % (5464/16))
print("but 22 bursts x 16 beats    = 352 words are READ per line   (read  > consume)")
print("and word_fetch fires h_cnt<H_ACT-4 :", end=" ")
H=1366
n = len([h for h in range(H) if h % 4 == 2 and h < H - 4])
print("%d + 1 prefetch = %d words CONSUMED per line" % (n, n + 1))
print()
print("MISMATCH: read %d, consume %d -> %d words leak into the FIFO EVERY LINE" % (352, n+1, 352-(n+1)))
print("          over 768 lines that is %d words into a %d-word FIFO." % ((352-(n+1))*768, 1024))
