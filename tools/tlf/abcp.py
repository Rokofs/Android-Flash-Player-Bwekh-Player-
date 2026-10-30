import sys,zlib,struct
def swf_abcs(path):
    d=open(path,'rb').read()
    if d[:3]==b'CWS': d=d[:8]+zlib.decompress(d[8:])
    hdrlen=struct.unpack('<I',d[4:8])[0]
    nb=d[8]>>3; p=8+(5+4*nb+7)//8+4; out=[]
    while p<len(d):
        h=struct.unpack_from('<H',d,p)[0];p+=2;c=h>>6;l=h&63
        if l==63: l=struct.unpack_from('<I',d,p)[0];p+=4
        if c==82:
            z=d.index(b'\0',p+4); out.append((d[p+4:z].decode('latin1'), d[z+1:p+l]))
        elif c==72: out.append(('',d[p:p+l]))
        p+=l
        if c==0: break
    return hdrlen,len(d),p,out
class R:
    def __init__(s,b): s.b=b; s.p=0
    def u8(s): v=s.b[s.p]; s.p+=1; return v
    def u30(s):
        r=0;sh=0
        for i in range(5):
            v=s.b[s.p]; s.p+=1; r|=(v&0x7f)<<sh; sh+=7
            if not v&0x80: break
        return r
def parse(b):
    r=R(b); r.p=4
    n=r.u30(); [r.u30() for i in range(1,n)]
    n=r.u30(); [r.u30() for i in range(1,n)]
    n=r.u30(); r.p+=8*max(0,n-1)
    n=r.u30(); strs=[None]
    for i in range(1,n): l=r.u30(); strs.append(b[r.p:r.p+l].decode('utf8','replace')); r.p+=l
    n=r.u30(); ns=[None]+[(r.u8(),r.u30()) for i in range(1,n)]
    n=r.u30()
    for i in range(1,n):
        c=r.u30(); [r.u30() for j in range(c)]
    n=r.u30(); mns=[None]
    for i in range(1,n):
        k=r.u8()
        if k in (7,0xd): mns.append((k,r.u30(),r.u30()))
        elif k in (0xf,0x10): mns.append((k,r.u30()))
        elif k in (0x11,0x12): mns.append((k,))
        elif k in (9,0xe): mns.append((k,r.u30(),r.u30()))
        elif k in (0x1b,0x1c): mns.append((k,r.u30()))
        elif k==0x1d:
            q=r.u30(); c=r.u30(); mns.append((k,q,[r.u30() for j in range(c)]))
        else: raise Exception('mn kind %x'%k)
    mc=r.u30()
    for i in range(mc):
        pc=r.u30(); r.u30(); [r.u30() for j in range(pc)]; r.u30(); f=r.u8()
        if f&8:
            c=r.u30()
            for j in range(c): r.u30(); r.u8()
        if f&0x80: [r.u30() for j in range(pc)]
    md=r.u30()
    for i in range(md):
        r.u30(); c=r.u30(); [r.u30() for j in range(2*c)]
    def traits():
        c=r.u30()
        for i in range(c):
            r.u30(); k=r.u8(); kind=k&0xf
            if kind in (0,6):
                r.u30(); r.u30(); vi=r.u30()
                if vi: r.u8()
            elif kind in (1,2,3,4,5): r.u30(); r.u30()
            else: raise Exception('trait kind %d'%kind)
            if k&0x40:
                c2=r.u30(); [r.u30() for j in range(c2)]
    cc=r.u30(); inst=[]
    for i in range(cc):
        nm=r.u30(); sup=r.u30(); f=r.u8()
        if f&8: r.u30()
        c=r.u30(); [r.u30() for j in range(c)]
        ii=r.u30(); traits(); inst.append((nm,sup,ii))
    for i in range(cc): r.u30(); traits()
    sc=r.u30()
    for i in range(sc): r.u30(); traits()
    bc=r.u30(); bodies=[]
    for i in range(bc):
        m=r.u30(); ms=r.u30(); lc=r.u30(); isd=r.u30(); msd=r.u30(); cl=r.u30(); cs=r.p; r.p+=cl
        ec=r.u30()
        for j in range(ec): [r.u30() for k in range(5)]
        traits(); bodies.append((m,ms,lc,isd,msd,cs,cl))
    return dict(strs=strs,ns=ns,mns=mns,inst=inst,bodies=bodies,end=r.p,len=len(b))
if __name__=='__main__':
    hl,dl,p,abcs=swf_abcs(sys.argv[1])
    print('header len',hl,'actual',dl,'tags end',p)
    for name,a in abcs:
        try:
            x=parse(a); print(repr(name)[:30], 'len',len(a),'end',x['end'], 'OK' if x['end']==len(a) else 'MISMATCH')
        except Exception as e: print(repr(name)[:30],'ERR',e)
