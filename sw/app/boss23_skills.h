#include "spell_params.h"
/* 16-bit turns, Q14 sine interpolation, Q4 velocities. No floating point.
 * Emission schedules reproduce skill23.html at 75 Hz and density 1.5. */
static __attribute__((noinline)) int spell_sin(unsigned a)
{
    unsigned k = (a >> 8) & 255u;
    return spell_sine[k] + ((spell_sine[(k + 1u) & 255u] - spell_sine[k]) * (int)(a & 255u) >> 8);
}
static void spell_shot(int x, int y, unsigned a, int speed, unsigned hue)
{
    speed=speed*SPELL_SPEED_NUM/SPELL_SPEED_DEN;
    int vx = spell_sin(a + 16384u) * speed;
    int vy = spell_sin(a) * speed;
    skill1_shot(x,y,(vx + (vx < 0 ? -38400 : 38400)) / 76800,
                   (vy + (vy < 0 ? -38400 : 38400)) / 76800,hue,EF_SUBPIXEL);
}
static void spell_ring(int x,int y,int r0,int rmax,unsigned life,unsigned hue,unsigned slot,unsigned soft)
{
    spell_fx_t *f = &spell->fx[slot];
    f->x=x;f->y=y;f->r0=r0;f->rmax=rmax;f->ttl=f->life=life;f->hue=hue;f->soft=soft;
}
static void spell_radial(int x,int y,unsigned n,int speed,unsigned phase,unsigned hue,int gap)
{
    for (unsigned i=0;i<n;i++) {
        unsigned a=i*65536u/n+phase;
        if (gap) {
            int dx=spell_sin(a+16384u)>>6,dy=spell_sin(a)>>6;
            int dot=dx*spell->aim_x+dy*spell->aim_y;
            int cross=dx*spell->aim_y-dy*spell->aim_x;
            if (dot>0 && cross*5<dot && cross*5>-dot) continue;
        }
        spell_shot(x,y,a,speed,hue);
    }
}
static void spell_laser(unsigned slot,int x,int y,unsigned angle,unsigned warn,unsigned life,unsigned width,unsigned hue)
{
    spell_beam_t *b=&spell->beams[slot];
    b->x=x;b->y=y;b->nx=spell_sin(angle+16384u)>>6;b->ny=spell_sin(angle)>>6;
    b->warn=warn;b->life=life;b->ttl=warn+life;b->width=width;b->hue=hue;
}
static void boss23_clear(void)
{
    for(unsigned i=0;i<6;i++)spell->beams[i].ttl=0;
    for(unsigned i=0;i<4;i++)spell->fx[i].ttl=0;
}
static int spell_due(unsigned t,unsigned start,unsigned gap,unsigned i)
{
    return t==((start+gap*i)*3u+39u)/40u;
}
static void boss23_tick(void)
{
    unsigned t=spell->age;
    if (!t) {
        spell->x=(GAME_LEFT+GAME_RIGHT)/2;spell->y=175;
        spell->aim_x=player_x-spell->x;spell->aim_y=player_y-spell->y;
        if (!(spell->aim_x|spell->aim_y))spell->aim_y=1;
        boss_pattern=spell->kind==0?PAT_SPIRAL:spell->kind==1?PAT_BURST:PAT_BEAM;
        pattern_changes++;
        audio_event(AUDIO_EVENT_BOSS);
    }
    if (t<42u) {
        int dx=spell->x-32-boss_x,dy=spell->y-28-boss_y;
        boss_x+=dx>12?12:dx< -12?-12:dx;boss_y+=dy>12?12:dy< -12?-12:dy;
    }
    for(unsigned i=0;i<4;i++)if(spell->fx[i].ttl)spell->fx[i].ttl--;
    for(unsigned i=0;i<6;i++)if(spell->beams[i].ttl)spell->beams[i].ttl--;
    t=++spell->age;
    int x=spell->x,y=spell->y;
    if(wave==1) {
        if(spell->kind==0) {
            for(unsigned i=0;i<8;i++)if(spell_due(t,650,420,i)) {
                for(int arm=0;arm<6;arm++)for(int k=0;k<(int)SPELL_CORONA_BRANCHES;k++) {
                    unsigned a=arm*65536/6+i*991+(2*k-(int)SPELL_CORONA_BRANCHES+1)*339;
                    spell_shot(x,y,a,130+k*15,i&1?6:0);
                    spell_shot(x,y,a+313,245+k*8,3);
                }
                spell_ring(x,y,25,180,56,i&1?6:0,3,0);
            }
        } else if(spell->kind==1) {
            for(unsigned i=0;i<5;i++)if(spell_due(t,550,580,i))
                for(unsigned j=0;j<SPELL_EMBERS;j++) {
                    if(is_stress_stage && active_ebullets_count>=ORB_FIRST-128)break;
                    bullet_t *b=alloc_ebullet();if(!b)break;
                    b->x=GAME_LEFT+55+(2*j+1)*894/(2*SPELL_EMBERS)+(i&1?10:-10);b->y=-22;
                    b->vx=0;b->vy=(175+(j%3)*18)*16*SPELL_SPEED_NUM/(75*SPELL_SPEED_DEN);b->color=j&1?6:0;
                    b->flags=EF_ACTIVE|EF_SUBPIXEL|EF_EMBER;
                    unsigned slot=b-ebullets;bullet_frac[slot]=0;
                    if(is_stress_stage && eb_lance_count<MM_LANCE_INDEX_MAX)eb_lances[eb_lance_count++]=slot;
                    ember_ages[slot].age=0;ember_ages[slot].freeze=57+(j%4)*6;
                    ember_ages[slot].burst=105+(j%4)*6;
                }
        } else {
            for(unsigned i=0;i<3;i++)for(unsigned k=0;k<3;k++)
                if(spell_due(t,650+650*i,350,k)) {
                    unsigned a=i*65536/3-16384;
                    int nx=x+(spell_sin(a+16384)*170>>14);
                    int ny=y+120+(spell_sin(a)*100>>14);
                    spell_radial(nx,ny,SPELL_CORE_RING,150+k*35,k*834,k&1?6:0,0);
                    if(!k)spell_ring(nx,ny,18,18,225,0,i,1);
                    spell_ring(nx,ny,18,160,75,6,3,0);
                }
            for(unsigned i=0;i<6;i++)if(spell_due(t,1200,160,i))
                spell_laser(i,x,y,(i+1)*65536/12,75,42,7,0);
        }
    } else {
        if(spell->kind==0) {
            for(unsigned i=0;i<44;i++)if(spell_due(t,600,75,i)) {
                for(unsigned j=0;j<3;j++) {
                    unsigned a=i*887+j*65536/3;
                    int nx=x+(spell_sin(a+16384)*125>>14),ny=y+(spell_sin(a)*65>>14);
                    for(int k=0;k<(int)SPELL_ORBIT_FAN;k++)spell_shot(nx,ny,a+16384+(2*k-(int)SPELL_ORBIT_FAN+1)*469,180+(i%3)*18,j&1?4:6);
                    spell_shot(nx,ny,16384-a,250,2);
                }
                if(!(i&7))spell_ring(x,y,30,200,60,4,3,0);
            }
            if(t>=45u && t<308u)for(unsigned j=0;j<3;j++) {
                unsigned a=(t-45)*887*8/45+j*65536/3;
                spell_ring(x+(spell_sin(a+16384)*125>>14),y+(spell_sin(a)*65>>14),14,14,2,j&1?4:6,j,1);
            }
        } else if(spell->kind==1) {
            unsigned n = (is_stress_stage && active_ebullets_count >= 12000) ? 48u : SPELL_FLOWER_RING;
            for(unsigned w=0;w<6;w++)if(spell_due(t,700,550,w)) {
                for(unsigned i=0;i<n;i++) {
                    unsigned a=i*65536/n;int speed=145+(65*spell_sin(a*8+16384)>>14);
                    spell_shot(x,y,a+w*939,speed,4);
                    spell_shot(x,y,a+w*939+261,speed*67/100+28,6);
                }
                spell_ring(x,y,20,210,60,6,3,0);
            }
        } else {
            for(unsigned i=0;i<3;i++)if(spell_due(t,600,950,i)) {
                spell_laser(i*2,player_x,player_y,16384+i*2295,79,38,9,4);
                spell_laser(i*2+1,player_x,player_y,i*2295,79,38,9,6);
                spell_ring(player_x,player_y,12,95,67,4,3,0);
            }
            for(unsigned i=0;i<8;i++)if(spell_due(t,1100,400,i)) {
                spell_radial(x,y,SPELL_GAP_RING,150+(i%3)*30,i*469,i&1?4:6,1);
                spell_ring(x,y,30,180,52,6,3,0);
            }
        }
    }
    if (is_stress_stage && spell->kind != 2u && t < 330u && (t & 63u) == 16u) {
        unsigned m = ((t >> 6) + spell->kind + wave) & 3u;
        for (unsigned i = 0; i < 6u; i++) {
            int lx = x, ly = y;
            unsigned la = 2560u + i * 5461u + (t << 4);
            if (m == 1u) {
                lx = x + (i < 3u ? -260 : 260);
                la = i < 3u ? (6144u + i * 3800u) : (26624u - (i - 3u) * 3800u);
            } else if (m == 2u) {
                lx = GAME_LEFT + 112 + (int)i * 156;
                ly = 56;
                la = 16384u + ((i & 1u) ? 3072u : -3072u);
            } else if (m == 3u) {
                lx = player_x;
                ly = player_y;
                la = i * 5461u + (t << 5);
            }
            spell_laser(i, lx, ly, la, 18u, 26u, 7u + (m & 1u), (wave + i + m) & 7u);
        }
    }
    if(t>=480u){spell->age=0;spell->kind=(spell->kind+1u)%3u;}
}
/* Called after all enemy records have advanced, so burst children never move
 * an extra tick simply because their allocator returned a later pool slot. */
static void spell_embers_release(void)
{
    for(unsigned i=0;i<spell->burst_count;i++) {
        int x=spell->burst_xy[i][0],y=spell->burst_xy[i][1];
        spell_radial(x,y,5,175,(x-GAME_LEFT)*104,6,0);
        spell_ring(x,y,6,35,19,6,3,0);
    }
    spell->burst_count=0;
}
static void spell_beams_upload(void)
{
    if(!spell_packet_ready())return;
    for(unsigned i=0;i<6;i++) {
        spell_beam_t *b=&spell->beams[i];
        unsigned active=b->ttl && wave>0 && boss_state==BOSS_FIGHT;
        int warning=b->ttl>b->life;
        GPU2D_REG_SPELL(i,0)=(active?0x80000000u:0u)|((unsigned)warning<<30)|((unsigned)(b->y&1023)<<11)|(b->x&2047);
        GPU2D_REG_SPELL(i,1)=((uint32_t)(uint16_t)b->ny<<16)|(uint16_t)b->nx;
        GPU2D_REG_SPELL(i,2)=palette[b->hue&7u];
        GPU2D_REG_SPELL(i,3)=(b->width<<8)|(b->ttl<12?b->ttl*21u:255u);
    }
}
static void spell_beams_collision(void)
{
    if(wave==0||boss_state!=BOSS_FIGHT)return;
    for(unsigned i=0;i<6;i++) {
        spell_beam_t *b=&spell->beams[i];
        if(!b->ttl||b->ttl>b->life||invuln)continue;
        int cross=(player_x-b->x)*b->ny-(player_y-b->y)*b->nx;
        int radius=(b->width+5)*128;
        if(cross<radius&&cross> -radius){take_hit();if(!is_stress_stage)boss23_clear();break;}
    }
}
