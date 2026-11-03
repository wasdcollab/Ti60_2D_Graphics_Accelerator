"""Translate the six user-exported preview JSON files into compile-time counts."""
import json
from fractions import Fraction
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]


def main():
    macros=[];configs=[]
    names={(2,1):('SPELL_CORONA_BRANCHES',4),(2,2):('SPELL_EMBERS',10),
           (2,3):('SPELL_CORE_RING',26),(3,1):('SPELL_ORBIT_FAN',2),
           (3,2):('SPELL_FLOWER_RING',96),(3,3):('SPELL_GAP_RING',72)}
    for (boss,skill),(name,base) in names.items():
        p=ROOT/f'assets/skills/boss{boss}_skill{skill}.json'
        c=json.loads(p.read_text(encoding='utf-8'))
        assert c['boss']==boss and c['skill']==skill and c['logic_hz']==75
        assert .5<=c['density']<=2.5 and .6<=c['speed']<=1.4 and c['glow'] is True
        count=int(base*c['density']+.5)  # matches positive Math.round
        macros.append(f'#define {name} {count}u');configs.append(c)
    speeds={Fraction(str(c['speed'])) for c in configs}
    if len(speeds)!=1:raise ValueError('this port requires a common projectile speed across the six casts')
    speed=speeds.pop();macros += [f'#define SPELL_SPEED_NUM {speed.numerator}',f'#define SPELL_SPEED_DEN {speed.denominator}']
    (ROOT/'sw/app/spell_params.h').write_text('/* Generated from assets/skills/boss*_skill*.json. */\n'+'\n'.join(macros)+'\n',encoding='ascii')
    print('Spell parameters:', ', '.join(c['name'] for c in configs), '; density',configs[0]['density'],'speed',float(speed))


if __name__=='__main__':main()
