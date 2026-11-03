"""Boot LZSS: eight flag bits, literal bytes or 12-bit distances/4-bit lengths.
Distance 1..4096, length 3..18; overlapping copies are intentional.
"""
from collections import defaultdict, deque


def pack(data):
    data=bytes(data);positions=defaultdict(deque);out=bytearray();i=0
    while i<len(data):
        flag_at=len(out);out.append(0)
        for k in range(8):
            if i==len(data):break
            best=0;distance=0
            for old in reversed(positions[data[i:i+3]]):
                if i-old>4096:break
                n=3
                while n<18 and i+n<len(data) and data[old+n]==data[i+n]:n+=1
                if n>best:best=n;distance=i-old
            n=best if best>=3 else 1
            if best>=3:
                out[flag_at]|=1<<k;v=((distance-1)<<4)|(best-3);out.extend([v&255,v>>8])
            else:out.append(data[i])
            for j in range(i,i+n):
                q=positions[data[j:j+3]];q.append(j)
                if len(q)>96:q.popleft()
            i+=n
    assert unpack(out,len(data))==data
    return bytes(out)


def unpack(data,size):
    out=bytearray();i=0
    while len(out)<size:
        flags=data[i];i+=1
        for k in range(8):
            if len(out)==size:break
            if flags&(1<<k):
                v=data[i]|data[i+1]<<8;i+=2;distance=(v>>4)+1
                assert distance<=len(out)
                for _ in range((v&15)+3):out.append(out[-distance])
            else:out.append(data[i]);i+=1
    assert len(out)==size and i==len(data)
    return bytes(out)
