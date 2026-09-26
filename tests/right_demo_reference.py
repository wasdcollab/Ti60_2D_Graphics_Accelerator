"""Independent half-pixel AABB reference for the autonomous right renderer."""
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from demo_boxes import BOX_TABLE_30   # frozen table, see tests/demo_boxes.py

def commands(frames=4):
    boxes=[[x*2,y*2,vx,vy,w,h,c] for x,y,vx,vy,w,h,c in BOX_TABLE_30]
    result=[]
    for frame in range(frames):
        for i,a in enumerate(boxes[:-1]):
            for b in boxes[i+1:]:
                if a[0]<b[0]+b[4]*2 and b[0]<a[0]+a[4]*2 and a[1]<b[1]+b[5]*2 and b[1]<a[1]+a[5]*2:
                    if ((a[0]-b[0]) ^ (a[2]-b[2]))<0: a[2],b[2]=b[2],a[2]
                    if ((a[1]-b[1]) ^ (a[3]-b[3]))<0: a[3],b[3]=b[3],a[3]
        base=0x00E00000 if frame%2==0 else 0x00800000
        result.append((base+2560,512,768,255))
        for a in boxes:
            for axis,low,high in ((0,0,1366-a[4]*2),(1,72,1536-a[5]*2)):
                a[axis]+=a[axis+2]
                if a[axis]<low: a[axis]=low; a[axis+2]=-a[axis+2]
                elif a[axis]>high: a[axis]=high; a[axis+2]=-a[axis+2]
            result.append((base+2560+(a[1]//2)*8192+(a[0]//2)*4,a[4],a[5],a[6]))
    return result

if __name__=='__main__':
    path=Path(__file__).resolve().parents[1]/'work_sim/step3_rtl/demo_commands.hex'
    path.write_text(''.join(f'{(dst<<54)|(w<<43)|(h<<32)|color:021x}\n' for dst,w,h,color in commands()))
